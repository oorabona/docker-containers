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

# The resolver cases exercise _find_image directly. Spawn Bats for the runner
# suite as well, so these cases cover setup's status-to-skip mapping.
run_runner_suite() {
    local nested_bin="$TEST_TEMP_DIR/nested-runner-bin"

    run env -u OPENRESTY_IMAGE PATH="$nested_bin:$PATH" bats "$RUNNER"
}

stub_runner_docker() {
    local docker_body="$1"
    local nested_bin="$TEST_TEMP_DIR/nested-runner-bin"

    mkdir -p "$nested_bin"
    cat > "$nested_bin/docker" <<EOF
#!/usr/bin/env bash
$docker_body
EOF
    chmod +x "$nested_bin/docker"
}

@test "openresty image resolver: explicitly unreachable runtime is a precondition, not a missing build" {
    mock_command docker "printf '%s\\n' 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1"

    run_find_image

    [ "$status" -eq 2 ]
    [[ "$output" == *"image store is unreachable"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: an answered listing error fails with its diagnostic" {
    mock_command docker "printf '%s\\n' 'image store metadata is corrupt' >&2; exit 42"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: container runtime failed to list images (exit 42): image store metadata is corrupt"* ]]
    [[ "$output" != *"SKIP:"* ]]
}

@test "openresty image resolver: an unexplained listing error fails, not skips" {
    mock_command docker 'exit 42'

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: container runtime failed to list images (exit 42): (no diagnostic)"* ]]
    [[ "$output" != *"SKIP:"* ]]
}

@test "openresty image resolver: an empty reachable store reports the missing build" {
    mock_command docker 'exit 0'

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: no built openresty image found (run ./make build openresty, or set OPENRESTY_IMAGE)"* ]]
}

@test "openresty image resolver: distinct full IDs sharing a short prefix remain ambiguous" {
    mock_command docker "if [[ \" \$* \" == *' --no-trunc '* ]]; then
        printf '%s\\n' \\
            'sha256:123456789abc000000000000000000000000000000000000000000000000 ghcr.io/oorabona/openresty:latest' \\
            'sha256:123456789abc111111111111111111111111111111111111111111111111 openresty:dev'
    else
        printf '%s\\n' \\
            'sha256:123456789abc ghcr.io/oorabona/openresty:latest' \\
            'sha256:123456789abc openresty:dev'
    fi"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: ambiguous — 2 distinct openresty images present; set OPENRESTY_IMAGE to the one under test"* ]]
}

@test "openresty image resolver: aliases for one image resolve to one image" {
    mock_command docker "printf '%s\\n' \\
        'sha256:one ghcr.io/oorabona/openresty:latest' \\
        'sha256:one docker.io/oorabona/openresty:latest' \\
        'sha256:one openresty:dev'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
}

@test "openresty image resolver: one matching image returns its tag" {
    mock_command docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
}

@test "openresty runner: unreachable runtime skips all runner tests" {
    stub_runner_docker "printf '%s\\n' 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1"

    run_runner_suite

    [ "$status" -eq 0 ]
    [ "$(printf '%s\\n' "$output" | grep -cE '^ok [0-9]+ .*# skip ' )" -eq 3 ]
}

@test "openresty runner: empty reachable store fails the runner suite" {
    stub_runner_docker 'exit 0'

    run_runner_suite

    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: no built openresty image found"* ]]
}
