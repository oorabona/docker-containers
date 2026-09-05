#!/usr/bin/env bats

load "../test_helper"

bats_require_minimum_version 1.5.0

# Bats's run --separate-stderr overwrites this capture variable in the tests below.
stderr=""

setup() {
    setup_temp_dir
    RUNNER="$PROJECT_ROOT/openresty/tests/test-runner-linux.bats"
}

teardown() {
    teardown_temp_dir
}

run_find_image() {
    # Permit Bats run options such as --separate-stderr for channel assertions.
    run "$@" bash -c '
        source <(awk "/^_find_image\\(\\) \\{/ { inside = 1 } inside { print } inside && /^}\$/ { exit }" "$1")
        _find_image
    ' _ "$RUNNER"
}

# The resolver cases exercise _find_image directly. Spawn Bats for the runner
# suite as well, so these cases cover setup's failure propagation.
run_runner_suite() {
    local nested_bin="$TEST_TEMP_DIR/nested-runner-bin"

    run env -u OPENRESTY_IMAGE PATH="$nested_bin:$PATH" bats "$RUNNER"
}

stub_docker() {
    local docker_body="$1"
    local docker_bin="${2:-$TEST_TEMP_DIR/bin}"

    mkdir -p "$docker_bin"
    cat > "$docker_bin/docker" <<EOF
#!/usr/bin/env bash
if [[ "\$#" -ne 4 || "\$1" != images || "\$2" != --no-trunc || "\$3" != --format || "\$4" != '{{.ID}} {{.Repository}}:{{.Tag}}' ]]; then
    printf 'unexpected docker invocation:' >&2
    printf ' %q' "\$@" >&2
    printf '\\n' >&2
    exit 64
fi
$docker_body
EOF
    chmod +x "$docker_bin/docker"
    export PATH="$docker_bin:$PATH"
}

@test "openresty image resolver: Docker's unreachable runtime diagnostic fails, not missing build" {
    stub_docker "printf '%s\\n' 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: Podman's unreachable runtime diagnostic fails, not missing build" {
    stub_docker "printf '%s\\n' 'Error: unable to connect to Podman socket: Get \\\"http://d/v4.0.0/libpod/images/json\\\": dial unix /run/user/1000/podman/podman.sock: connect: no such file or directory' >&2; exit 42"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: unable to connect to Podman socket"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: an unexplained listing error fails, not skips" {
    stub_docker 'exit 42'

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: container runtime did not answer while listing images (exit 42): (no diagnostic)"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"SKIP:"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: an empty reachable store reports the missing build" {
    stub_docker 'exit 0'

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: no built openresty image found (run ./make build openresty, or set OPENRESTY_IMAGE)"* ]]
}

@test "openresty image resolver: distinct full IDs sharing a short prefix remain ambiguous" {
    stub_docker "printf '%s\\n' \\
        'sha256:123456789abc000000000000000000000000000000000000000000000000 ghcr.io/oorabona/openresty:latest' \\
        'sha256:123456789abc111111111111111111111111111111111111111111111111 openresty:dev'"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: ambiguous — 2 distinct openresty images present; set OPENRESTY_IMAGE to the one under test"* ]]
}

@test "openresty image resolver: aliases for one image resolve to one image" {
    stub_docker "printf '%s\\n' \\
        'sha256:one ghcr.io/oorabona/openresty:latest' \\
        'sha256:one docker.io/oorabona/openresty:latest' \\
        'sha256:one openresty:dev'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
}

@test "openresty image resolver: one matching image returns its tag" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
}

@test "openresty image resolver: successful listing replays its warning to stderr" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'; printf '%s\\n' 'WARNING: image store is in degraded mode' >&2"

    run_find_image --separate-stderr

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
    [[ "$stderr" == *"WARNING: image store is in degraded mode"* ]]
}

@test "openresty image resolver: successful listing with empty stderr emits nothing extra" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run_find_image --separate-stderr

    [ "$status" -eq 0 ]
    [ "$output" = "ghcr.io/oorabona/openresty:latest" ]
    [ "$stderr" = "" ]
}

@test "openresty runner: unreachable runtime fails the runner suite" {
    stub_docker "printf '%s\\n' 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1" "$TEST_TEMP_DIR/nested-runner-bin"

    run_runner_suite

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty runner: empty reachable store fails the runner suite" {
    stub_docker 'exit 0' "$TEST_TEMP_DIR/nested-runner-bin"

    run_runner_suite

    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: no built openresty image found"* ]]
}

@test "openresty image resolver stub: exact resolver invocation returns fixture rows" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run docker images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:one ghcr.io/oorabona/openresty:latest" ]
}

@test "openresty image resolver stub: invocation without --format fails" {
    stub_docker 'exit 0'

    run docker images --no-trunc

    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected docker invocation"* ]]
}

@test "openresty image resolver stub: invocation with another subcommand fails" {
    stub_docker 'exit 0'

    run docker ps --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'

    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected docker invocation"* ]]
}

@test "openresty image resolver stub: invocation with another format fails" {
    stub_docker 'exit 0'

    run docker images --no-trunc --format '{{.Repository}}:{{.Tag}}'

    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected docker invocation"* ]]
}
