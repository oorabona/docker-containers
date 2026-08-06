#!/usr/bin/env bats
#
# Execute the install_ext transport shell used by postgres/Dockerfile. These
# tests exercise the guards that decide whether a staged payload is copied or a
# build stops. CI needs BusyBox installed: the shipped PostgreSQL image uses
# BusyBox ash and applets.

load "../test_helper"

_run_install_ext() {
    run env "PATH=$BUSYBOX_APPLET_DIR" /bin/busybox sh -eux -c '
        . "$1"
        shift
        install_ext "$@"
        if [ "${ASSERT_NO_BASH:-0}" = 1 ] && command -v bash >/dev/null; then
            exit 1
        fi
    ' sh "$PROJECT_ROOT/postgres/install-ext.sh" "$@"
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
    export ASSERT_NO_BASH=1
    _run_install_ext busybox-only
    unset ASSERT_NO_BASH

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
    [[ "$output" != *"parameter not set"* ]]
    [[ "$output" == *"matches no supported layout"* ]]
}

# The Dockerfile sources this file into the shell that then runs the generated
# install calls, so anything it does at the top level runs during the build, with
# `set -eux` already active and before any of those calls. It must define the two
# functions and do nothing else.
#
# The old sed extraction had a weaker version of this — it asserted the cut body
# contained no `rm -rf`, guarding against the range swallowing the staging
# cleanup. There is no range now, and the property it was protecting is the one
# below: sourcing has no effect.
#
# What this cannot see is a top-level statement guarded by a variable that is
# unset here and set during the build. Nothing sets one today.
@test "sourcing the helper defines the two functions and does nothing else" {
    local canary="$TEST_TEMP_DIR/untouched"
    local witness="$TEST_TEMP_DIR/reached-the-end"

    mkdir -p "$canary"
    printf 'original\n' > "$canary/file"

    # The witness is written AFTER the source and the function checks, on a
    # channel the test does not require to be silent. A top-level `exit 0` or
    # `exec true` in the helper ends this shell with status 0, no output and an
    # untouched canary — satisfying every other assertion here — and in the build
    # it would end the RUN successfully before a single extension was installed.
    # Only something that has to happen after the source can tell the difference.
    #
    # `$-` is checked for `e` because a top-level `set +e` also passes silently,
    # and in the build it would disarm the errexit the whole RUN depends on: a
    # failed install_ext would be followed by a successful cleanup and a layer
    # that committed.
    #
    # The build ARGs in scope where the Dockerfile sources this file are set here
    # too. A top-level statement guarded on one of them — `if [ -n "$FLAVOR" ];
    # then LIB_DEST=/tmp/elsewhere; fi` — is invisible to a witness shell that
    # leaves them unset, and in the build it would put the libraries outside
    # PostgreSQL's directory while every later check still passed. An earlier
    # version of this comment asserted nothing set such a variable, which was
    # simply untrue: `postgres/Dockerfile` declares FLAVOR, MAJOR_VERSION,
    # VERSION, LOCALES and SHARED_PRELOAD_LIBRARIES before line 77.
    #
    # A guard on an inherited base-image variable this list does not name stays
    # invisible. That bound is real and is what this test cannot close.
    # -u on the three roots: setup() exports them for the other tests here, and
    # this one has to see the environment the build sees, where they are absent
    # and the functions take their production defaults.
    run env -u STAGING_ROOT -u EXTENSION_DEST -u LIB_DEST \
        "PATH=$BUSYBOX_APPLET_DIR" \
        FLAVOR=full MAJOR_VERSION=18 VERSION=18-alpine \
        LOCALES=en_US.UTF-8 SHARED_PRELOAD_LIBRARIES=pg_stat_statements \
        /bin/busybox sh -eu -c '
        cd "$2"
        . "$1"
        case "$-" in *e*) ;; *) echo "errexit was disarmed by sourcing" >&2; exit 1 ;; esac
        command -v install_ext >/dev/null || { echo "install_ext undefined" >&2; exit 1; }
        command -v copy_payload >/dev/null || { echo "copy_payload undefined" >&2; exit 1; }
        # The three roots must still be unset, so the functions take their
        # production defaults. A top-level assignment produces no output and
        # touches nothing, so every other assertion here passes while the build
        # copies libraries somewhere PostgreSQL does not look — and the later
        # control-file check still succeeds, because that checks the extension
        # directory, not the library one.
        for v in STAGING_ROOT EXTENSION_DEST LIB_DEST; do
            eval "value=\${$v-__unset__}"
            [ "$value" = "__unset__" ] || { echo "sourcing set $v to $value" >&2; exit 1; }
        done
        : > "$3"
    ' sh "$PROJECT_ROOT/postgres/install-ext.sh" "$canary" "$witness"

    [ "$status" -eq 0 ]
    # Execution reached past the source rather than ending inside it.
    [ -f "$witness" ]
    # Sourcing printed nothing: no progress line, no warning, no trace.
    [ -z "$output" ]
    # And touched nothing: same entries, and the one file's content unchanged.
    [ "$(find "$canary" -mindepth 1 | wc -l)" -eq 1 ]
    [ "$(cat "$canary/file")" = "original" ]
}
