#!/usr/bin/env bats
#
# Execute the install_ext transport shell from postgres/Dockerfile. These tests
# deliberately do not inspect a generated Dockerfile: they exercise the guards
# that decide whether a staged payload is copied or a build stops. CI needs
# BusyBox installed: the shipped PostgreSQL image uses BusyBox ash and applets.

load "../test_helper"

_extract_install_ext() {
    printf '%s\n' '# shellcheck shell=sh' > "$TEST_TEMP_DIR/install-ext.sh"
    sed -n '/^RUN set -eux; \\/,/^    # Install extensions based on flavor/{p; /^    # Install extensions based on flavor/q;}' \
        "$PROJECT_ROOT/postgres/Dockerfile" \
        | sed -e '1s/^RUN //' -e 's/; \\$//' \
            -e "s|/tmp/ext|$STAGING_ROOT|g" \
            -e "s|/usr/local/share/postgresql/extension|$EXTENSION_DEST|g" \
            -e "s|/usr/local/lib/postgresql|$LIB_DEST|g" \
        >> "$TEST_TEMP_DIR/install-ext.sh"
    printf '%s\n' 'install_ext "$@"' >> "$TEST_TEMP_DIR/install-ext.sh"

    # A total extraction failure announces itself — install_ext would be
    # undefined and every test would die. A PARTIAL one does not: the sed range
    # still yields a callable function while silently dropping whichever guard
    # the Dockerfile's continuation style moved out of range. Pin the landmarks
    # that must survive, so drift fails here rather than passing a suite that
    # tests less than it names.
    local body="$TEST_TEMP_DIR/install-ext.sh"
    grep -q 'install_ext() {' "$body"
    grep -q 'copy_payload' "$body"
    grep -q 'set -eux' "$body"
    grep -q 'has no staging root at' "$body"
    grep -q 'ceiling control' "$body"
    [ "$(wc -l < "$body")" -gt 60 ]
}

_run_install_ext() {
    run env "PATH=$BUSYBOX_APPLET_DIR" /bin/busybox sh \
        "$TEST_TEMP_DIR/install-ext.sh" "$@"
}

_write_file() {
    local path=$1
    local content=${2:-payload}
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
}

setup() {
    setup_temp_dir
    if [[ ! -x /bin/busybox ]]; then
        echo "BusyBox is required for this test; CI must install /bin/busybox" >&2
        return 1
    fi
    export STAGING_ROOT="$TEST_TEMP_DIR/ext"
    export EXTENSION_DEST="$TEST_TEMP_DIR/destination/extension"
    export LIB_DEST="$TEST_TEMP_DIR/destination/lib"
    export BUSYBOX_APPLET_DIR="$TEST_TEMP_DIR/busybox-bin"
    mkdir -p "$STAGING_ROOT" "$EXTENSION_DEST" "$LIB_DEST" "$BUSYBOX_APPLET_DIR"
    for utility in $(/bin/busybox --list); do
        ln -s /bin/busybox "$BUSYBOX_APPLET_DIR/$utility"
    done
    _extract_install_ext
}

teardown() {
    teardown_temp_dir
}

@test "install_ext fails when the declared staging root is absent" {
    _run_install_ext absent

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension absent has no staging root"* ]]
}

@test "install_ext fails when the staging root matches neither supported layout" {
    mkdir -p "$STAGING_ROOT/malformed/unexpected"

    _run_install_ext malformed

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension malformed staging root"* ]]
    [[ "$output" == *"matches no supported layout"* ]]
}

@test "install_ext fails when the staging root matches multiple layouts" {
    _write_file "$STAGING_ROOT/ambiguous/extension/ambiguous.control"
    _write_file "$STAGING_ROOT/ambiguous/2.9.0/extension/ambiguous--2.9.0.sql"

    _run_install_ext ambiguous

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension ambiguous staging root"* ]]
    [[ "$output" == *"matches multiple supported layouts"* ]]
    [[ "$output" == *"found:"*"extension"* ]]
    [[ "$output" == *"found:"*"2.9.0"* ]]
    [ ! -e "$EXTENSION_DEST/ambiguous.control" ]
}

@test "install_ext fails when a single-version staging root contains an unknown sibling" {
    _write_file "$STAGING_ROOT/misspelled/extension/misspelled.control"
    mkdir -p "$STAGING_ROOT/misspelled/liib"

    _run_install_ext misspelled

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension misspelled staging root"* ]]
    [[ "$output" == *"matches no supported layout"* ]]
    [[ "$output" == *"found:"*"extension"* ]]
    [[ "$output" == *"found:"*"liib"* ]]
    [ ! -e "$EXTENSION_DEST/misspelled.control" ]
}

@test "install_ext fails when a retained version contains an unknown sibling" {
    _write_file "$STAGING_ROOT/version-misspelled/2.10.0/extension/version-misspelled.control"
    mkdir -p "$STAGING_ROOT/version-misspelled/2.10.0/liib"

    _run_install_ext version-misspelled

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension version-misspelled version 2.10.0 staging directory"* ]]
    [[ "$output" == *"unsupported layout"* ]]
    [[ "$output" == *"found:"*"extension"* ]]
    [[ "$output" == *"found:"*"liib"* ]]
    [ ! -e "$EXTENSION_DEST/version-misspelled.control" ]
}

@test "BusyBox harness does not resolve utilities outside its applet directory" {
    mkdir -p "$STAGING_ROOT/busybox-only/extension"
    printf '%s\n' 'if command -v bash >/dev/null; then exit 1; fi' \
        >> "$TEST_TEMP_DIR/install-ext.sh"

    _run_install_ext busybox-only

    [ "$status" -eq 0 ]
}

@test "install_ext fails when a payload copy fails" {
    _write_file "$STAGING_ROOT/broken/extension/broken--1.0.sql"
    rmdir "$EXTENSION_DEST"
    touch "$EXTENSION_DEST"

    _run_install_ext broken

    [ "$status" -ne 0 ]
    [[ "$output" == *"could not copy extension broken payload from $STAGING_ROOT/broken/extension"* ]]
}

@test "install_ext accepts an extension payload with no lib directory" {
    _write_file "$STAGING_ROOT/sqlonly/extension/sqlonly.control"
    _write_file "$STAGING_ROOT/sqlonly/extension/sqlonly--1.0.sql"

    _run_install_ext sqlonly

    [ "$status" -eq 0 ]
    [ -f "$EXTENSION_DEST/sqlonly.control" ]
    [ -f "$EXTENSION_DEST/sqlonly--1.0.sql" ]
}

@test "install_ext accepts an empty lib directory" {
    _write_file "$STAGING_ROOT/emptylib/extension/emptylib.control"
    mkdir -p "$STAGING_ROOT/emptylib/lib"

    _run_install_ext emptylib

    [ "$status" -eq 0 ]
    [ -f "$EXTENSION_DEST/emptylib.control" ]
}

# Every one of the ten recipes under postgres/extensions/build/ writes
# /output/metadata.txt beside extension/ and lib/, and that whole directory is
# what `COPY --from=ext-<name>` stages. A layout rule that recognises only the
# two directories rejects every artifact this repository actually produces.
@test "install_ext accepts the metadata.txt every build recipe stages" {
    _write_file "$STAGING_ROOT/withmeta/extension/withmeta.control"
    _write_file "$STAGING_ROOT/withmeta/lib/withmeta.so"
    _write_file "$STAGING_ROOT/withmeta/metadata.txt" "extension=withmeta"

    _run_install_ext withmeta

    [ "$status" -eq 0 ]
    [ -f "$EXTENSION_DEST/withmeta.control" ]
    [ -f "$LIB_DEST/withmeta.so" ]
}

@test "install_ext accepts metadata.txt inside a retained version directory" {
    _write_file "$STAGING_ROOT/metaver/2.9.0/extension/metaver.control"
    _write_file "$STAGING_ROOT/metaver/2.9.0/lib/metaver.so"
    _write_file "$STAGING_ROOT/metaver/2.9.0/metadata.txt" "version=2.9.0"
    _write_file "$STAGING_ROOT/metaver/2.10.0/extension/metaver.control"
    _write_file "$STAGING_ROOT/metaver/2.10.0/lib/metaver.so"
    _write_file "$STAGING_ROOT/metaver/2.10.0/metadata.txt" "version=2.10.0"

    _run_install_ext metaver

    [ "$status" -eq 0 ]
    [ -f "$EXTENSION_DEST/metaver.control" ]
    [ -f "$LIB_DEST/metaver.so" ]
}

@test "install_ext copies a dotfile-only payload" {
    _write_file "$STAGING_ROOT/dotfile/extension/dotfile.control"
    _write_file "$STAGING_ROOT/dotfile/lib/.hidden.so"

    _run_install_ext dotfile

    [ "$status" -eq 0 ]
    [ -f "$LIB_DEST/.hidden.so" ]
}

@test "install_ext completes multi-version enumeration with BusyBox find" {
    _write_file "$STAGING_ROOT/enumeration/2.9.0/extension/enumeration--2.9.0.sql"

    _run_install_ext enumeration

    [ "$status" -eq 0 ]
    [ -f "$EXTENSION_DEST/enumeration--2.9.0.sql" ]
}

@test "install_ext preserves numeric multi-version order under BusyBox ash" {
    _write_file "$STAGING_ROOT/multi/2.9.0/extension/multi--2.9.0.sql" "one"
    _write_file "$STAGING_ROOT/multi/2.9.0/extension/multi.control" "default_version = '2.9.0'"
    _write_file "$STAGING_ROOT/multi/2.9.0/lib/multi-2.9.0.so" "one"
    _write_file "$STAGING_ROOT/multi/2.10.0/extension/multi--2.10.0.sql" "two"
    _write_file "$STAGING_ROOT/multi/2.10.0/extension/multi.control" "default_version = '2.10.0'"
    _write_file "$STAGING_ROOT/multi/2.10.0/lib/multi-2.10.0.so" "two"

    _run_install_ext multi

    [ "$status" -eq 0 ]
    [ -f "$EXTENSION_DEST/multi--2.9.0.sql" ]
    [ -f "$EXTENSION_DEST/multi--2.10.0.sql" ]
    [ -f "$LIB_DEST/multi-2.9.0.so" ]
    [ -f "$LIB_DEST/multi-2.10.0.so" ]
    [ "$(cat "$EXTENSION_DEST/multi.control")" = "default_version = '2.10.0'" ]
    [[ "$output" == *"version: $STAGING_ROOT/multi/2.9.0/"*"version: $STAGING_ROOT/multi/2.10.0/"* ]]
}

@test "install_ext reports an invalid layout under the image set -u mode" {
    mkdir -p "$STAGING_ROOT/unset-layout/unexpected"

    _run_install_ext unset-layout

    [ "$status" -ne 0 ]
    [[ "$output" == *"extension unset-layout staging root"* ]]
    [[ "$output" == *"matches no supported layout"* ]]
    [[ "$output" != *"parameter not set"* ]]
}
