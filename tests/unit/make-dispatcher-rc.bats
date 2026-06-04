#!/usr/bin/env bats

# Unit tests for make() dispatcher rc-propagation fix (issue #595 slice 4)
#
# Problem: the make() dispatcher called `do_it $op "$registry"` without
# capturing its exit code. After the loop, `popd` returned 0, so the function
# returned 0 even when do_it failed. This masked docker build failures and made
# retry_with_backoff in action.yaml ineffective.
#
# Fix: `do_it ... || _op_rc=$?` accumulates failures; `return $_op_rc` after
# popd propagates the non-zero rc to the caller.
#
# Tests 1-4: isolate the dispatcher loop logic using inline stubs.
# Sourcing `make` directly is impractical: it has top-level execution code
# (docker-compose check + case statement) requiring a live docker environment.
# The inline approach tests the exact behaviour of the fixed loop body without
# environment dependencies.
#
# Tests 5-7: structural grep gates confirming the fix is present in ./make.

load "../test_helper"

setup() {
    setup_temp_dir
    # Create a minimal fake container directory so pushd/popd work
    mkdir -p "$TEST_TEMP_DIR/fakecontainer"
    export _FAKE_CONTAINER="$TEST_TEMP_DIR/fakecontainer"
    export NPROC=1
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Export all stubs needed by the dispatcher running in a bats subshell.
# DO_IT_RC is an exported env var so do_it() can read it across the subshell
# boundary (bash exported functions cannot close over local variables).
_export_stubs() {
    local do_it_rc="${1:-0}"
    export DO_IT_RC="$do_it_rc"

    log_success() { :; };  export -f log_success
    log_error()   { :; };  export -f log_error

    # pushd/popd: redirect to the fake container dir (no pwd-change side-effects)
    pushd() { builtin pushd "$_FAKE_CONTAINER" > /dev/null; }; export -f pushd
    popd()  { builtin popd  > /dev/null; };                    export -f popd

    validate_target()   { return 0; };            export -f validate_target
    get_build_version() { echo "1.0.0"; return 0; }; export -f get_build_version
    do_it()             { return "$DO_IT_RC"; };  export -f do_it

    # The dispatcher under test — mirrors make() in ./make verbatim (fixed body).
    # Re-defined here rather than sourced so the test doesn't depend on the
    # top-level execution code in ./make (docker-compose check, case statement).
    dispatcher() {
        local op=$1; shift
        local registry=""

        local positional_args=()
        while [[ $# -gt 0 ]]; do
            positional_args+=("$1"); shift
        done
        [[ ${#positional_args[@]} -gt 0 ]] && set -- "${positional_args[@]}" || set --

        validate_target "$1" || return 1
        local target=$1
        local wantedVersion=${2:-latest}
        local wantedTag=${3:-""}

        local versions
        versions=$(get_build_version "$target" "$wantedVersion")
        [ $? -ne 0 ] && return 1

        pushd "$target"

        local _op_rc=0
        for version in $versions; do
            local effective_tag="${wantedTag:-$version}"
            export WANTED=$wantedVersion VERSION=$version TAG=$effective_tag
            log_success "$op ${target} $WANTED (version: ${VERSION} tag: $TAG) | nproc: ${NPROC}"
            do_it "$op" "$registry" || _op_rc=$?
        done
        popd
        return $_op_rc
    }
    export -f dispatcher
}

# ---------------------------------------------------------------------------
# 1. When do_it succeeds, dispatcher returns 0
# ---------------------------------------------------------------------------

@test "make dispatcher: returns 0 when do_it succeeds" {
    _export_stubs 0
    run dispatcher build fakecontainer latest
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. When do_it fails, dispatcher returns non-zero
# ---------------------------------------------------------------------------

@test "make dispatcher: returns non-zero when do_it fails" {
    _export_stubs 1
    run dispatcher build fakecontainer latest
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 3. Multi-version: ALL versions are attempted even when the first fails
#    (no early-return; _op_rc accumulates the last failing rc)
# ---------------------------------------------------------------------------

@test "make dispatcher: iterates ALL versions even when first do_it fails" {
    local counter_file="$TEST_TEMP_DIR/do_it_calls"
    echo "0" > "$counter_file"
    export _DO_IT_COUNTER="$counter_file"

    log_success() { :; };  export -f log_success
    log_error()   { :; };  export -f log_error

    pushd() { builtin pushd "$_FAKE_CONTAINER" > /dev/null; }; export -f pushd
    popd()  { builtin popd  > /dev/null; };                    export -f popd

    validate_target()    { return 0; };                      export -f validate_target
    # Return two versions so the loop runs twice
    get_build_version()  { printf "1.0.0\n2.0.0"; return 0; }; export -f get_build_version

    do_it() {
        local count; count=$(cat "$_DO_IT_COUNTER")
        echo $((count + 1)) > "$_DO_IT_COUNTER"
        return 1   # always fail
    }
    export -f do_it

    dispatcher() {
        local op=$1; shift
        local registry=""
        local positional_args=()
        while [[ $# -gt 0 ]]; do positional_args+=("$1"); shift; done
        [[ ${#positional_args[@]} -gt 0 ]] && set -- "${positional_args[@]}" || set --
        validate_target "$1" || return 1
        local target=$1; local wantedVersion=${2:-latest}; local wantedTag=${3:-""}
        local versions; versions=$(get_build_version "$target" "$wantedVersion")
        [ $? -ne 0 ] && return 1
        pushd "$target"
        local _op_rc=0
        for version in $versions; do
            local effective_tag="${wantedTag:-$version}"
            export WANTED=$wantedVersion VERSION=$version TAG=$effective_tag
            do_it "$op" "$registry" || _op_rc=$?
        done
        popd
        return $_op_rc
    }
    export -f dispatcher

    run dispatcher build fakecontainer latest
    # Function must fail (both do_it calls failed)
    [ "$status" -ne 0 ]

    # Both versions must have been attempted
    local calls; calls=$(cat "$counter_file")
    [ "$calls" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 4. Multi-version: second version fails; dispatcher still returns non-zero
# ---------------------------------------------------------------------------

@test "make dispatcher: returns non-zero when second of two versions fails" {
    local counter_file="$TEST_TEMP_DIR/do_it_calls"
    echo "0" > "$counter_file"
    export _DO_IT_COUNTER="$counter_file"

    log_success() { :; };  export -f log_success
    log_error()   { :; };  export -f log_error

    pushd() { builtin pushd "$_FAKE_CONTAINER" > /dev/null; }; export -f pushd
    popd()  { builtin popd  > /dev/null; };                    export -f popd

    validate_target()   { return 0; };                       export -f validate_target
    get_build_version() { printf "1.0.0\n2.0.0"; return 0; }; export -f get_build_version

    do_it() {
        local count; count=$(cat "$_DO_IT_COUNTER")
        echo $((count + 1)) > "$_DO_IT_COUNTER"
        # Succeed on first call, fail on second
        [ "$count" -ge 1 ] && return 1
        return 0
    }
    export -f do_it

    dispatcher() {
        local op=$1; shift
        local registry=""
        local positional_args=()
        while [[ $# -gt 0 ]]; do positional_args+=("$1"); shift; done
        [[ ${#positional_args[@]} -gt 0 ]] && set -- "${positional_args[@]}" || set --
        validate_target "$1" || return 1
        local target=$1; local wantedVersion=${2:-latest}; local wantedTag=${3:-""}
        local versions; versions=$(get_build_version "$target" "$wantedVersion")
        [ $? -ne 0 ] && return 1
        pushd "$target"
        local _op_rc=0
        for version in $versions; do
            local effective_tag="${wantedTag:-$version}"
            export WANTED=$wantedVersion VERSION=$version TAG=$effective_tag
            do_it "$op" "$registry" || _op_rc=$?
        done
        popd
        return $_op_rc
    }
    export -f dispatcher

    run dispatcher build fakecontainer latest
    [ "$status" -ne 0 ]

    local calls; calls=$(cat "$counter_file")
    [ "$calls" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 5-7. Structural grep gates: confirm the fix is present in ./make
# ---------------------------------------------------------------------------

@test "make script: _op_rc variable is declared before the version loop" {
    grep -q 'local _op_rc=0' "$PROJECT_ROOT/make"
}

@test "make script: do_it call captures rc with || _op_rc=\$?" {
    grep -q 'do_it.*|| _op_rc=\$?' "$PROJECT_ROOT/make"
}

@test "make script: dispatcher returns _op_rc after popd" {
    # Extract make() function body and verify 'return $_op_rc' comes after 'popd'
    local make_fn
    make_fn=$(awk '/^make\(\)/{found=1} found{print} found && /^}$/{exit}' "$PROJECT_ROOT/make")
    local popd_line
    popd_line=$(echo "$make_fn" | grep -n 'popd' | tail -1 | cut -d: -f1)
    local return_line
    return_line=$(echo "$make_fn" | grep -n 'return \$_op_rc' | head -1 | cut -d: -f1)
    [ -n "$popd_line" ]
    [ -n "$return_line" ]
    [ "$return_line" -gt "$popd_line" ]
}
