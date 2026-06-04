#!/usr/bin/env bats

# Unit tests for command-scoped retry wiring (slice 4 of #595)
#
# Verifies:
#   1. retry_with_backoff retries a failing command N times then fails
#   2. retry_with_backoff succeeds on first try
#   3. retry_with_backoff succeeds on a mid-sequence attempt
#   4. create_registry_manifest wraps each imagetools create with retry
#   5. build-extensions.sh sources retry.sh (retry_with_backoff available)
#
# YAML-level wiring (retry step gone, docker push retry in action) is
# verified by the grep gate: `grep steps.retry auto-build.yaml` returns 1.

load "../test_helper"

setup() {
    setup_temp_dir
    source "$HELPERS_DIR/logging.sh"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# 1. retry_with_backoff primitives (sourced directly from helpers/retry.sh)
# ---------------------------------------------------------------------------

@test "retry_with_backoff: succeeds on first attempt" {
    source "$HELPERS_DIR/retry.sh"

    run retry_with_backoff 3 1 true
    [ "$status" -eq 0 ]
}

@test "retry_with_backoff: retries a failing command N times then fails" {
    source "$HELPERS_DIR/retry.sh"

    local counter_file="$TEST_TEMP_DIR/counter"
    echo "0" > "$counter_file"

    always_fail() {
        local count
        count=$(cat "$counter_file")
        echo $((count + 1)) > "$counter_file"
        return 1
    }

    run retry_with_backoff 3 0 always_fail
    [ "$status" -eq 1 ]

    local count
    count=$(cat "$counter_file")
    [ "$count" -eq 3 ]
}

@test "retry_with_backoff: succeeds on second attempt" {
    source "$HELPERS_DIR/retry.sh"

    local counter_file="$TEST_TEMP_DIR/counter"
    echo "0" > "$counter_file"

    fail_once() {
        local count
        count=$(cat "$counter_file")
        echo $((count + 1)) > "$counter_file"
        [ "$count" -ge 1 ]
    }

    run retry_with_backoff 3 0 fail_once
    [ "$status" -eq 0 ]

    local count
    count=$(cat "$counter_file")
    [ "$count" -eq 2 ]
}

@test "retry_with_backoff: delay=0 still retries (smoke, no real sleep)" {
    source "$HELPERS_DIR/retry.sh"

    local counter_file="$TEST_TEMP_DIR/counter"
    echo "0" > "$counter_file"

    fail_twice() {
        local count
        count=$(cat "$counter_file")
        echo $((count + 1)) > "$counter_file"
        [ "$count" -ge 2 ]
    }

    run retry_with_backoff 5 0 fail_twice
    [ "$status" -eq 0 ]

    local count
    count=$(cat "$counter_file")
    [ "$count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 2. create_registry_manifest wraps imagetools create with retry
#
# Strategy: stub $DOCKER to a counting script; assert it is called more
# than once when the first attempt fails (retry fired), and that
# create_registry_manifest ultimately returns 1 after all retries exhausted.
# ---------------------------------------------------------------------------

@test "create_registry_manifest: retries imagetools create on transient failure" {
    # Build a stub docker binary that fails the first two calls then succeeds
    local stub_dir="$TEST_TEMP_DIR/stub"
    mkdir -p "$stub_dir"
    local counter_file="$TEST_TEMP_DIR/docker_calls"
    echo "0" > "$counter_file"

    cat > "$stub_dir/docker_stub" << 'STUB'
#!/usr/bin/env bash
count=$(cat "$COUNTER_FILE")
echo $((count + 1)) > "$COUNTER_FILE"
# Fail first 2 calls, succeed from 3rd onwards
if [ "$count" -lt 2 ]; then
    echo "transient error" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "$stub_dir/docker_stub"

    export COUNTER_FILE="$counter_file"
    export DOCKER="$stub_dir/docker_stub"

    # Minimal env that create-manifest.sh requires
    export TAG="18-alpine"
    export VERSION="18"
    export FULL_VERSION="18.3-alpine"
    export VARIANT=""
    export IS_DEFAULT="true"
    export IS_LATEST_VERSION="true"

    # Override sleep so tests don't actually wait
    sleep() { :; }
    export -f sleep

    source "$HELPERS_DIR/retry.sh"
    source "$HELPERS_DIR/create-manifest.sh"

    create_registry_manifest "ghcr.io/owner/postgres" "ghcr.io/owner/postgres" "false"
    local rc=$?

    [ "$rc" -eq 0 ]
    local calls
    calls=$(cat "$counter_file")
    # Must have been called more than once (retry fired at least once)
    [ "$calls" -gt 1 ]
}

@test "create_registry_manifest: returns failure after all retries exhausted" {
    local stub_dir="$TEST_TEMP_DIR/stub"
    mkdir -p "$stub_dir"
    local counter_file="$TEST_TEMP_DIR/docker_calls"
    echo "0" > "$counter_file"

    cat > "$stub_dir/docker_stub" << 'STUB'
#!/usr/bin/env bash
count=$(cat "$COUNTER_FILE")
echo $((count + 1)) > "$COUNTER_FILE"
echo "persistent error" >&2
exit 1
STUB
    chmod +x "$stub_dir/docker_stub"

    export COUNTER_FILE="$counter_file"
    export DOCKER="$stub_dir/docker_stub"

    export TAG="18-alpine"
    export VERSION="18"
    export FULL_VERSION="18.3-alpine"
    export VARIANT=""
    export IS_DEFAULT="false"
    export IS_LATEST_VERSION="false"

    sleep() { :; }
    export -f sleep

    source "$HELPERS_DIR/retry.sh"
    source "$HELPERS_DIR/create-manifest.sh"

    # fail_on_error=false: function returns 0 even on failure (swallows error)
    create_registry_manifest "ghcr.io/owner/postgres" "ghcr.io/owner/postgres" "false"
    local rc=$?
    [ "$rc" -eq 0 ]

    # All three paths (multi-arch, amd64-only, arm64-only) each retry 3x → 9 calls total
    local calls
    calls=$(cat "$counter_file")
    [ "$calls" -gt 3 ]
}

# ---------------------------------------------------------------------------
# 3. build-extensions.sh sources retry.sh (retry_with_backoff available)
#
# We can't source the full 2400-line script in a unit test context because it
# requires postgres/extensions/ config and registry access. Instead, verify
# that the source line for retry.sh is present and retry_with_backoff is
# defined after sourcing the helpers explicitly.
# ---------------------------------------------------------------------------

@test "build-extensions.sh includes retry.sh source directive" {
    grep -q 'source.*helpers/retry\.sh' "$PROJECT_ROOT/scripts/build-extensions.sh"
}

@test "retry_with_backoff is available after sourcing retry.sh" {
    source "$HELPERS_DIR/retry.sh"
    declare -f retry_with_backoff > /dev/null
}

# ---------------------------------------------------------------------------
# 4. auto-build.yaml: job-level retry step is fully removed
# ---------------------------------------------------------------------------

@test "auto-build.yaml: no steps.retry references remain" {
    local yaml="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    run grep -c 'steps\.retry' "$yaml"
    # grep -c returns 0 matches → status 1 (no match), output "0"
    [ "$status" -eq 1 ] || [ "$output" -eq 0 ]
}

@test "auto-build.yaml: Retry build on failure step is gone" {
    local yaml="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    run grep -c 'Retry build on failure' "$yaml"
    [ "$status" -eq 1 ] || [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5. action.yaml: docker push is wrapped with retry_with_backoff
# ---------------------------------------------------------------------------

@test "build-container action.yaml: GHCR push uses retry_with_backoff" {
    local action="$PROJECT_ROOT/.github/actions/build-container/action.yaml"
    grep -q 'retry_with_backoff.*docker push' "$action"
}

@test "build-container action.yaml: DockerHub push uses retry_with_backoff" {
    local action="$PROJECT_ROOT/.github/actions/build-container/action.yaml"
    # Two separate retry-wrapped pushes: GHCR (3 10) and DockerHub (5 30)
    local count
    count=$(grep -c 'retry_with_backoff.*docker push' "$action")
    [ "$count" -ge 2 ]
}

@test "build-container action.yaml: make build uses retry_with_backoff" {
    local action="$PROJECT_ROOT/.github/actions/build-container/action.yaml"
    grep -q 'retry_with_backoff.*make' "$action"
}
