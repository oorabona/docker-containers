#!/usr/bin/env bats

# Hermetic contract tests for the OpenResty smoke suite's image resolution.

load "../test_helper"

bats_require_minimum_version 1.5.0

setup() {
    setup_temp_dir
    unset OPENRESTY_IMAGE
    RUNNER="$PROJECT_ROOT/openresty/tests/test-runner-linux.bats"
    # Source only _find_image: the runner has Bats test declarations after its helpers.
    # shellcheck disable=SC1090 # The generated source is intentionally the runner helper only.
    source <(awk '/^_find_image\(\) \{/ { inside = 1 } inside { print } inside && /^}$/ { exit }' "$RUNNER")
}

teardown() {
    teardown_temp_dir
}

stub_docker() {
    local docker_body="$1"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
if [[ "\$#" -ne 4 || "\$1" != images || "\$2" != --no-trunc || "\$3" != --format || "\$4" != '{{.ID}} {{.Repository}}:{{.Tag}}' ]]; then
    printf 'unexpected docker invocation:' >&2
    printf ' %q' "\$@" >&2
    printf '\\n' >&2
    exit 64
fi
$docker_body
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

@test "openresty setup resolver: an empty reachable store returns the skip status" {
    stub_docker 'exit 0'

    run _find_image

    [ "$status" -eq 3 ]
    [[ "$output" == *"ERROR: no built openresty image found"* ]]
}

@test "openresty setup resolver: an unreadable store remains a failure" {
    stub_docker "printf '%s\\n' 'container store unavailable' >&2; exit 42"

    run _find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"container runtime did not answer while listing images (exit 42): container store unavailable"* ]]
}

@test "openresty setup resolver: distinct images remain a failure" {
    stub_docker "printf '%s\\n' \\
        'sha256:one ghcr.io/oorabona/openresty:latest' \\
        'sha256:two openresty:dev'"

    run _find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: ambiguous — 2 distinct openresty images present"* ]]
}

@test "openresty setup resolver: OPENRESTY_IMAGE bypasses image-store lookup" {
    stub_docker "printf '%s\\n' 'docker must not be called' >&2; exit 64"

    export OPENRESTY_IMAGE=x
    run _find_image

    [ "$status" -eq 0 ]
    [ "$output" = "x" ]
}

@test "openresty setup: an empty reachable store skips all smoke tests" {
    stub_docker 'exit 0'

    run env -u OPENRESTY_IMAGE PATH="$TEST_TEMP_DIR/bin:$PATH" bats "$RUNNER"

    [ "$status" -eq 0 ]
    [[ "$output" == *"# skip no built openresty image found; set OPENRESTY_IMAGE or run ./make build openresty"* ]]
}
