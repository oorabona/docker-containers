#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    RUNNER="$PROJECT_ROOT/openresty/tests/test-runner-linux.bats"
}

teardown() {
    teardown_temp_dir
}

run_find_image() {
    run bash -c '
        source <(awk "/^_find_image\\(\\) \\{/ { inside = 1 } inside { print } inside && /^}\$/ { exit }" "$1")
        _find_image
    ' _ "$RUNNER"
}

@test "openresty image resolver: unreachable runtime is a precondition, not a missing build" {
    mock_command docker 'exit 42'

    run_find_image

    [ "$status" -eq 2 ]
    [[ "$output" == *"image store is unreachable"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: an empty reachable store reports the missing build" {
    mock_command docker 'exit 0'

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: no built openresty image found (run ./make build openresty, or set OPENRESTY_IMAGE)"* ]]
}

@test "openresty image resolver: distinct image IDs remain ambiguous" {
    mock_command docker "printf '%s\\n' \\
        'sha256:one ghcr.io/oorabona/openresty:latest' \\
        'sha256:two openresty:dev'"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: ambiguous — 2 distinct openresty images present; set OPENRESTY_IMAGE to the one under test"* ]]
}

@test "openresty image resolver: one matching image returns its tag" {
    mock_command docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
}
