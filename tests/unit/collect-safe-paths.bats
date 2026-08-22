#!/usr/bin/env bats

load "../test_helper"

setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d)
    COLLECTOR="$SCRIPTS_DIR/collect-safe-paths.sh"
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
    [[ -z ${COLLECTED_OUTPUT:-} ]] || rm -f "$COLLECTED_OUTPUT"
}

assert_constant_refusal() {
    if [[ "$(grep '^::error::' <<<"$output")" != '::error::refusing to lint a path outside [A-Za-z0-9._/-]' ]]; then
        echo "FAIL: rejected pathname entered a workflow-command line" >&3
        return 1
    fi
}

@test "accepts an ordinary pathname and emits it NUL-delimited" {
    mkdir -p "$TEST_TEMP_DIR/ordinary"
    touch "$TEST_TEMP_DIR/ordinary/config.yaml"

    run bash -c 'set -o pipefail; "$1" "$2" -type f | tr "\\0" "\\n"' _ "$COLLECTOR" "$TEST_TEMP_DIR"

    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TEMP_DIR/ordinary/config.yaml" ]
}

@test "emits two accepted pathnames with a NUL after each pathname" {
    local collected expected
    touch "$TEST_TEMP_DIR/alpha.yaml" "$TEST_TEMP_DIR/zeta.yaml"
    collected=$(mktemp)
    COLLECTED_OUTPUT=$collected
    expected=$(printf '%s\0%s\0' "$TEST_TEMP_DIR/alpha.yaml" "$TEST_TEMP_DIR/zeta.yaml" | od -An -t x1 -v)

    run bash -c '"$1" "$2" -maxdepth 1 -type f > "$3"; od -An -t x1 -v "$3"' _ \
        "$COLLECTOR" "$TEST_TEMP_DIR" "$collected"

    [ "$status" -eq 0 ]
    if [[ "$output" != "$expected" ]]; then
        echo "FAIL: collector output was not exactly two NUL-delimited pathnames" >&3
        return 1
    fi
}

@test "rejects a pathname containing a space before emitting paths" {
    local collected
    mkdir -p "$TEST_TEMP_DIR/bad path"
    touch "$TEST_TEMP_DIR/bad path/config.yaml"
    collected="$TEST_TEMP_DIR/collected"

    run bash -c '"$1" "$2" -type f > "$3"' _ "$COLLECTOR" "$TEST_TEMP_DIR" "$collected"

    if [[ $status -eq 0 ]]; then
        echo "FAIL: unsafe pathname was accepted"
        return 1
    fi
    [[ "$output" == *"::error::refusing to lint a path outside [A-Za-z0-9._/-]"* ]]
    [[ "$output" == *"rejected pathname: "* ]]
    [[ "$output" == *'bad\ path'* ]]
    assert_constant_refusal
    [ ! -s "$collected" ]
}

@test "rejects a pathname containing a newline before emitting paths" {
    local collected newline_path
    newline_path="${TEST_TEMP_DIR}/"$'bad\npath'
    mkdir -p "$newline_path"
    touch "$newline_path/config.yaml"
    collected="$TEST_TEMP_DIR/collected"

    run bash -c '"$1" "$2" -type f > "$3"' _ "$COLLECTOR" "$TEST_TEMP_DIR" "$collected"

    if [[ $status -eq 0 ]]; then
        echo "FAIL: unsafe pathname was accepted"
        return 1
    fi
    [[ "$output" == *"::error::refusing to lint a path outside [A-Za-z0-9._/-]"* ]]
    [[ "$output" == *"rejected pathname: "* ]]
    [[ "$output" == *"\$'"* ]]
    [[ "$output" == *"bad\\npath"* ]]
    assert_constant_refusal
    [ ! -s "$collected" ]
}

@test "rejects a pathname containing workflow-command colons" {
    local collected
    mkdir -p "$TEST_TEMP_DIR/bad::command"
    touch "$TEST_TEMP_DIR/bad::command/config.yaml"
    collected="$TEST_TEMP_DIR/collected"

    run bash -c '"$1" "$2" -type f > "$3"' _ "$COLLECTOR" "$TEST_TEMP_DIR" "$collected"

    if [[ $status -eq 0 ]]; then
        echo "FAIL: unsafe pathname was accepted"
        return 1
    fi
    [[ "$output" == *"::error::refusing to lint a path outside [A-Za-z0-9._/-]"* ]]
    [[ "$output" == *"rejected pathname: "* ]]
    [[ "$output" == *bad::command* ]]
    assert_constant_refusal
    [ ! -s "$collected" ]
}

@test "fails when find cannot search its target" {
    local collected
    collected="$TEST_TEMP_DIR/collected"

    run bash -c '"$1" "$2" -type f > "$3"' _ "$COLLECTOR" "$TEST_TEMP_DIR/missing" "$collected"

    if [[ $status -eq 0 ]]; then
        echo "FAIL: failed find was accepted"
        return 1
    fi
    [[ "$output" == *"::error::safe path discovery failed"* ]]
    [ ! -s "$collected" ]
}

@test "does not start a downstream command for a rejected pathname" {
    local marker
    mkdir -p "$TEST_TEMP_DIR/bad::command"
    touch "$TEST_TEMP_DIR/bad::command/config.yaml"
    marker="$TEST_TEMP_DIR/downstream-started"

    run bash -c 'set -o pipefail; "$1" "$2" -type f | xargs -r -0 touch "$3"' _ \
        "$COLLECTOR" "$TEST_TEMP_DIR" "$marker"

    if [[ -e $marker ]]; then
        echo "FAIL: rejected pathname started downstream command"
        return 1
    fi
    [ "$status" -ne 0 ]
}

@test "withholds a safe pathname sorted before a rejected pathname" {
    local collected marker
    mkdir -p "$TEST_TEMP_DIR/a-safe" "$TEST_TEMP_DIR/z-bad%0Aforged"
    touch "$TEST_TEMP_DIR/a-safe/config.yaml" "$TEST_TEMP_DIR/z-bad%0Aforged/config.yaml"
    collected="$TEST_TEMP_DIR/collected"
    marker="$TEST_TEMP_DIR/downstream-started"

    run bash -c 'set -o pipefail; "$1" "$2" -type f | tee "$3" | xargs -r -0 touch "$4"' _ \
        "$COLLECTOR" "$TEST_TEMP_DIR" "$collected" "$marker"

    [ "$status" -ne 0 ]
    if [[ -s $collected ]]; then
        echo "FAIL: collector emitted a validated path before all paths were accepted" >&3
        return 1
    fi
    if [[ -e $marker ]]; then
        echo "FAIL: collector started downstream before all paths were accepted"
        return 1
    fi
}

@test "withholds paths when a valid root precedes a missing root" {
    local collected marker
    mkdir -p "$TEST_TEMP_DIR/valid"
    touch "$TEST_TEMP_DIR/valid/config.yaml"
    collected="$TEST_TEMP_DIR/collected"
    marker="$TEST_TEMP_DIR/downstream-started"

    run bash -c 'set -o pipefail; "$1" "$2" "$3" -type f | tee "$4" | xargs -r -0 touch "$5"' _ \
        "$COLLECTOR" "$TEST_TEMP_DIR/valid" "$TEST_TEMP_DIR/missing" "$collected" "$marker"

    [ "$status" -ne 0 ]
    if [[ -s $collected ]]; then
        echo "FAIL: collector emitted a path before find completed successfully"
        return 1
    fi
    if [[ -e $marker ]]; then
        echo "FAIL: collector started downstream before find completed successfully"
        return 1
    fi
}
