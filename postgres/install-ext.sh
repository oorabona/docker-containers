#!/bin/sh
copy_payload() {
    source_dir=$1;
    destination_dir=$2;
    ext=$3;
    if [ ! -d "$source_dir" ]; then
        return 0;
    fi;
    # A directory whose permissions forbid listing is not an empty one.
    # Catch that case before the globs below read it as "nothing to copy".
    # Bound: a glob has no exit status, so an I/O failure that begins after
    # this probe passes is still indistinguishable from an empty match.
    # POSIX shell offers no way to tell those apart; the permission case is
    # the one that is detectable and the one that has occurred.
    if [ ! -r "$source_dir" ] || [ ! -x "$source_dir" ]; then
        echo "ERROR: could not inspect extension ${ext} payload at ${source_dir}" >&2;
        return 1;
    fi;
    # Entry by entry, so each keeps its own mode and ownership and the
    # destination directory keeps its. `cp -a "$source_dir/."` would copy
    # the staging directory's metadata onto a PostgreSQL system directory.
    # The three globs are the same idiom the layout scan below uses; a
    # source with no entries matches none of them and copies nothing.
    for entry in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue;
        fi;
        if ! cp -av "$entry" "$destination_dir/"; then
            echo "ERROR: could not copy extension ${ext} payload from ${source_dir}" >&2;
            return 1;
        fi;
    done;
};
install_ext() {
    ext=$1;
    root="${STAGING_ROOT:-/tmp/ext}/${ext}";
    entry_name='';
    entry='';
    version_entry='';
    version_entry_name='';
    found_entries='';
    version_found_entries='';
    version_invalid_entries=0;
    has_single_extension=0;
    has_single_lib=0;
    multi_versions=0;
    invalid_entries=0;
    layout='';
    layout_error='';
    ver='';
    ver_dir='';
    ceiling_ver='';
    ceiling_dir='';
    versions_file='';
    sorted_versions_file='';
    if [ ! -d "$root" ]; then
        echo "ERROR: extension ${ext} has no staging root at ${root}" >&2;
        return 1;
    fi;
    if [ ! -r "$root" ] || [ ! -x "$root" ]; then
        echo "ERROR: extension ${ext} could not enumerate staging root ${root}" >&2;
        return 1;
    fi;
    set --;
    for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue;
        entry_name=${entry##*/};
        if [ -n "$found_entries" ]; then
            found_entries="$found_entries, $entry_name";
        else
            found_entries=$entry_name;
        fi;
        if [ "$entry_name" = metadata.txt ]; then
            : ;
        elif [ "$entry_name" = extension ]; then
            if [ -d "$entry" ]; then has_single_extension=1; else invalid_entries=1; fi;
        elif [ "$entry_name" = lib ]; then
            if [ -d "$entry" ]; then has_single_lib=1; else invalid_entries=1; fi;
        elif [ -d "$entry" ] && { [ -d "$entry/extension" ] || [ -d "$entry/lib" ]; }; then
            version_found_entries='';
            version_invalid_entries=0;
            # Same probe as the two enumerations above: a version directory
            # whose permissions forbid listing must not read as one holding
            # nothing, which is how its contents would be dropped silently.
            if [ ! -r "$entry" ] || [ ! -x "$entry" ]; then
                echo "ERROR: extension ${ext} could not inspect version directory ${entry}" >&2;
                return 1;
            fi;
            for version_entry in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
                [ -e "$version_entry" ] || [ -L "$version_entry" ] || continue;
                version_entry_name=${version_entry##*/};
                if [ -n "$version_found_entries" ]; then
                    version_found_entries="$version_found_entries, $version_entry_name";
                else
                    version_found_entries=$version_entry_name;
                fi;
                if [ "$version_entry_name" = metadata.txt ]; then
                    :;
                elif { [ "$version_entry_name" = extension ] || [ "$version_entry_name" = lib ]; } && [ -d "$version_entry" ]; then
                    :;
                else
                    version_invalid_entries=1;
                fi;
            done;
            if [ "$version_invalid_entries" -ne 0 ]; then
                echo "ERROR: extension ${ext} version ${entry_name} staging directory has unsupported layout; found: $version_found_entries" >&2;
                return 1;
            fi;
            multi_versions=$((multi_versions + 1));
            set -- "$@" "$entry_name";
        else
            invalid_entries=1;
        fi;
    done;
    if [ "$has_single_extension" -eq 1 ] && [ "$multi_versions" -eq 0 ] && [ "$invalid_entries" -eq 0 ]; then
        layout=single;
    elif [ "$has_single_extension" -eq 0 ] && [ "$has_single_lib" -eq 0 ] && [ "$multi_versions" -gt 0 ] && [ "$invalid_entries" -eq 0 ]; then
        layout=multi;
    fi;
    if [ -z "$layout" ]; then
        if [ -z "$found_entries" ]; then found_entries='(empty)'; fi;
        layout_error='matches no supported layout';
        if [ "$has_single_extension" -eq 1 ] && [ "$multi_versions" -gt 0 ]; then
            layout_error='matches multiple supported layouts';
        fi;
        echo "ERROR: extension ${ext} staging root ${root} ${layout_error}; found: $found_entries" >&2;
        return 1;
    fi;
    if [ "$layout" = single ]; then
        echo "Installing extension (single-version): ${ext}";
        copy_payload "${root}/extension" "${EXTENSION_DEST:-/usr/local/share/postgresql/extension}" "$ext" || return 1;
        copy_payload "${root}/lib" "${LIB_DEST:-/usr/local/lib/postgresql}" "$ext" || return 1;
    fi;
    if [ "$layout" = multi ]; then
        if ! versions_file=$(mktemp); then
            echo "ERROR: extension ${ext} could not enumerate staging root ${root}" >&2;
            return 1;
        fi;
        if ! sorted_versions_file=$(mktemp); then
            rm -f "$versions_file";
            echo "ERROR: extension ${ext} could not enumerate staging root ${root}" >&2;
            return 1;
        fi;
        if ! printf '%s\n' "$@" > "$versions_file" ||
            ! sort -t. -k1,1n -k2,2n -k3,3n "$versions_file" > "$sorted_versions_file"; then
            rm -f "$versions_file" "$sorted_versions_file";
            echo "ERROR: extension ${ext} could not enumerate staging root ${root}" >&2;
            return 1;
        fi;
        echo "Installing extension (multi-version): ${ext}";
        ceiling_ver='';
        while IFS= read -r ver || [ -n "$ver" ]; do
            ver_dir="${root}/$ver/";
            if [ ! -d "$ver_dir" ] || { [ ! -d "${ver_dir}extension" ] && [ ! -d "${ver_dir}lib" ]; }; then
                rm -f "$versions_file" "$sorted_versions_file";
                echo "ERROR: extension ${ext} has unsupported staging layout at ${ver_dir}" >&2;
                return 1;
            fi;
            echo "  version: ${ver_dir}";
            if ! copy_payload "${ver_dir}lib" "${LIB_DEST:-/usr/local/lib/postgresql}" "$ext" ||
                ! copy_payload "${ver_dir}extension" "${EXTENSION_DEST:-/usr/local/share/postgresql/extension}" "$ext"; then
                rm -f "$versions_file" "$sorted_versions_file";
                return 1;
            fi;
            ceiling_ver=$ver;
        done < "$sorted_versions_file";
        rm -f "$versions_file" "$sorted_versions_file";
        ceiling_dir="${root}/$ceiling_ver/";
        if [ -f "${ceiling_dir}extension/${ext}.control" ]; then
            cp -v "${ceiling_dir}extension/${ext}.control" \
                "${EXTENSION_DEST:-/usr/local/share/postgresql/extension}/${ext}.control";
            echo "  ceiling control: $(grep '^default_version' "${ceiling_dir}extension/${ext}.control" || true)";
        fi;
    fi;
};
