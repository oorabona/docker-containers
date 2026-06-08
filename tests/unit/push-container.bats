#!/usr/bin/env bats

# Unit tests for scripts/push-container.sh

load "../test_helper"

# Source the script functions in a way that handles $(dirname "$0") issue
source_push_script() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1
    source "./push-container.sh"
    popd > /dev/null 2>&1
}

setup() {
    setup_temp_dir

    # Source logging first (dependency)
    source "$HELPERS_DIR/logging.sh"

    # Save original PATH
    export ORIGINAL_PATH="$PATH"

    # Clear environment
    unset BUILD_PLATFORM
    unset MULTIPLATFORM_SUPPORTED
    unset GITHUB_ACTIONS
    unset GITHUB_REPOSITORY_OWNER
    unset SQUASH_IMAGE
}

teardown() {
    teardown_temp_dir
    export PATH="$ORIGINAL_PATH"
    unset BUILD_PLATFORM
    unset MULTIPLATFORM_SUPPORTED
    unset GITHUB_ACTIONS
    unset GITHUB_REPOSITORY_OWNER
    unset SQUASH_IMAGE
    unset NPROC
    unset CUSTOM_BUILD_ARGS
}

# =============================================================================
# retry_with_backoff tests
# Note: These tests use real sleep delays (~2 min total for retry tests)
# Run with --jobs 4 to parallelize across test files
# =============================================================================

@test "retry_with_backoff succeeds on first try" {
    source_push_script

    run retry_with_backoff 3 1 true
    [ "$status" -eq 0 ]
}

@test "retry_with_backoff succeeds after retry" {
    source_push_script

    echo "0" > "$TEST_TEMP_DIR/counter"

    fail_twice() {
        count=$(cat "$TEST_TEMP_DIR/counter")
        echo $((count + 1)) > "$TEST_TEMP_DIR/counter"
        [ "$count" -ge 2 ]
    }

    run retry_with_backoff 5 1 fail_twice
    [ "$status" -eq 0 ]

    count=$(cat "$TEST_TEMP_DIR/counter")
    [ "$count" -eq 3 ]
}

@test "retry_with_backoff fails after max attempts" {
    source_push_script

    echo "0" > "$TEST_TEMP_DIR/counter"

    always_fail() {
        count=$(cat "$TEST_TEMP_DIR/counter")
        echo $((count + 1)) > "$TEST_TEMP_DIR/counter"
        return 1
    }

    run retry_with_backoff 3 1 always_fail
    [ "$status" -eq 1 ]

    count=$(cat "$TEST_TEMP_DIR/counter")
    [ "$count" -eq 3 ]
}

@test "retry_with_backoff passes arguments to command" {
    source_push_script

    check_args() {
        [ "$1" = "arg1" ] && [ "$2" = "arg2" ]
    }

    run retry_with_backoff 3 1 check_args "arg1" "arg2"
    [ "$status" -eq 0 ]
}

# =============================================================================
# get_platform_config tests
# =============================================================================

@test "get_platform_config uses BUILD_PLATFORM when set" {
    source_push_script

    export BUILD_PLATFORM="linux/arm64"

    get_platform_config "v1.0"

    [ "$PLATFORM_CONFIG_PLATFORMS" = "linux/arm64" ]
    [ "$PLATFORM_CONFIG_SUFFIX" = "-arm64" ]
    [ "$PLATFORM_CONFIG_EFFECTIVE_TAG" = "v1.0-arm64" ]
}

@test "get_platform_config uses BUILD_PLATFORM for amd64" {
    source_push_script

    export BUILD_PLATFORM="linux/amd64"

    get_platform_config "v2.0"

    [ "$PLATFORM_CONFIG_PLATFORMS" = "linux/amd64" ]
    [ "$PLATFORM_CONFIG_SUFFIX" = "-amd64" ]
    [ "$PLATFORM_CONFIG_EFFECTIVE_TAG" = "v2.0-amd64" ]
}

@test "get_platform_config detects multiplatform when supported" {
    source_push_script

    # Mock check_multiplatform_support to return true AFTER sourcing
    # (the source would overwrite it if we did it before)
    check_multiplatform_support() { return 0; }

    unset BUILD_PLATFORM
    unset MULTIPLATFORM_SUPPORTED

    get_platform_config "v1.0"

    [ "$PLATFORM_CONFIG_PLATFORMS" = "linux/amd64,linux/arm64" ]
    [ "$PLATFORM_CONFIG_SUFFIX" = "" ]
    [ "$PLATFORM_CONFIG_EFFECTIVE_TAG" = "v1.0" ]
}

@test "get_platform_config falls back to amd64 only" {
    source_push_script

    # Mock check_multiplatform_support to return false AFTER sourcing
    check_multiplatform_support() { return 1; }

    unset BUILD_PLATFORM

    get_platform_config "v1.0"

    [ "$PLATFORM_CONFIG_PLATFORMS" = "linux/amd64" ]
    [ "$PLATFORM_CONFIG_SUFFIX" = "" ]
    [ "$PLATFORM_CONFIG_EFFECTIVE_TAG" = "v1.0" ]
}

# =============================================================================
# get_build_args tests
# =============================================================================

@test "get_build_args includes VERSION when provided" {
    source_push_script

    run get_build_args "1.2.3"

    [[ "$output" == *"--build-arg VERSION=1.2.3"* ]]
}

@test "get_build_args includes NPROC when set" {
    source_push_script

    export NPROC="4"

    run get_build_args "1.0.0"

    [[ "$output" == *"--build-arg NPROC=4"* ]]
}

@test "get_build_args includes CUSTOM_BUILD_ARGS when set" {
    source_push_script

    export CUSTOM_BUILD_ARGS="--no-cache --pull"

    run get_build_args "1.0.0"

    [[ "$output" == *"--no-cache --pull"* ]]
}

@test "get_build_args returns empty for no version and no extras" {
    source_push_script

    unset NPROC
    unset CUSTOM_BUILD_ARGS

    run get_build_args ""

    # Output should be empty or just whitespace
    [ -z "$(echo "$output" | tr -d '[:space:]')" ]
}

@test "get_build_args combines all arguments" {
    source_push_script

    export NPROC="8"
    export CUSTOM_BUILD_ARGS="--squash"

    run get_build_args "2.0.0"

    [[ "$output" == *"VERSION=2.0.0"* ]]
    [[ "$output" == *"NPROC=8"* ]]
    [[ "$output" == *"--squash"* ]]
}

# =============================================================================
# push_ghcr tests (mocked docker)
# =============================================================================

@test "push_ghcr calls docker buildx build with correct registry" {
    # Pin single-arch path via the cache var — re-source-proof (build-container.sh
    # checks MULTIPLATFORM_SUPPORTED before running detection logic).
    export MULTIPLATFORM_SUPPORTED=false
    # Keep function override as belt-and-suspenders before sourcing.
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "ghcr.io/testowner/testcontainer" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "\-\-push" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "push_ghcr includes cache-to for writing cache" {
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "cache-to" "$TEST_TEMP_DIR/docker_calls.log"
}

# =============================================================================
# push_dockerhub tests (mocked docker)
# =============================================================================

@test "push_dockerhub calls docker buildx build with correct registry" {
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"

    # Skopeo stub: exits non-zero immediately so the test reaches the buildx
    # fallback path deterministically on any host (with or without real skopeo).
    # retry_with_backoff is overridden below so the stub failure doesn't cause
    # 150 s of exponential-backoff sleep (5 retries × 10/20/40/80 s).
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # No-sleep retry: skopeo fails fast, guard probe needs no retry; this
    # prevents a 150 s stall from retry_with_backoff 5 10 on the skopeo call.
    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "docker.io/testowner/testcontainer" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "push_dockerhub uses read-only cache (no cache-to)" {
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"

    # Skopeo stub + no-sleep retry (same rationale as push_dockerhub/registry test).
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "cache-from" "$TEST_TEMP_DIR/docker_calls.log"
    # Should NOT have cache-to (read-only for Docker Hub)
    ! grep -q "cache-to" "$TEST_TEMP_DIR/docker_calls.log"
}

# =============================================================================
# push_container tests (integration of both)
# =============================================================================

@test "push_container calls both registries" {
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    # Skopeo stub + no-sleep retry: push_dockerhub uses skopeo when available;
    # stub forces the buildx fallback deterministically without slow retries.
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_container "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "ghcr.io" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "docker.io" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "push_container continues if Docker Hub fails" {
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    # Docker succeeds for GHCR, fails for Docker Hub
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
if [[ "$*" == *"docker.io"* ]]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    # Skopeo stub + no-sleep retry (same rationale as push_container/both-registries test).
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_container "testcontainer" "1.0.0" "1.0.0" "latest"

    # Should still succeed overall (GHCR is primary)
    [ "$status" -eq 0 ]
}

@test "push_container fails if GHCR fails" {
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_REPOSITORY_OWNER="testowner"

    # Docker fails for GHCR
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
if [[ "$*" == *"ghcr.io"* ]]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    # Skopeo stub + no-sleep retry (same rationale as push_container/both-registries test).
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_container "testcontainer" "1.0.0" "1.0.0" "latest"

    # Should fail since GHCR is primary
    [ "$status" -eq 1 ]
}

# =============================================================================
# _guard_local_single_arch_push tests
# Mutation articulated for each case: without the guard the single-arch push
# would silently overwrite a multi-arch OCI image index on the bare tag.
# =============================================================================

# Helper: build a mock docker binary inside TEST_TEMP_DIR/bin that logs calls
# and responds to "buildx imagetools inspect <ref>" with caller-supplied output
# and exit code.  All other docker sub-commands succeed.
_setup_docker_mock_with_inspect() {
    local inspect_output="$1"
    local inspect_rc="${2:-0}"

    mkdir -p "$TEST_TEMP_DIR/bin"
    # Write inspect output and rc to files so the heredoc can reference them
    printf '%s' "$inspect_output" > "$TEST_TEMP_DIR/inspect_output"
    printf '%s' "$inspect_rc"     > "$TEST_TEMP_DIR/inspect_rc"

    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER_CALL: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
    cat "$TEST_TEMP_DIR/inspect_output"
    exit "$(cat "$TEST_TEMP_DIR/inspect_rc")"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

@test "guard: local single-arch push blocked when target is multi-platform" {
    # Mutation: without the guard, push_ghcr would invoke 'docker buildx build
    # --push' and overwrite the multi-arch OCI index with a single-arch image.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # imagetools inspect returns two distinct linux/* platforms → multi-arch
    local multiarch_inspect
    multiarch_inspect="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:abc123

Manifests:
  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:aaa
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/amd64

  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:bbb
  MediaType: application/vnd.oci.image.manifest.v1+json
  Platform:  linux/arm64
INSPECT
)"
    _setup_docker_mock_with_inspect "$multiarch_inspect" 0

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must be refused (non-zero)
    [ "$status" -ne 0 ]
    # The actual buildx build --push must NOT have been invoked
    ! grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log" 2>/dev/null
    # Error message must mention the clobber
    [[ "$output" == *"multi-platform"* ]] || [[ "$output" == *"REFUSED"* ]]
}

@test "guard: local single-arch Docker Hub fallback push blocked when target is multi-platform" {
    # Mutation: without the guard in push_dockerhub's buildx fallback, a local
    # single-arch push (skopeo unavailable) would overwrite a multi-arch Docker Hub
    # tag — the same clobber class as GHCR, on the secondary registry.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    local multiarch_inspect
    multiarch_inspect="$(cat << 'INSPECT'
Name:      docker.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json

Manifests:
  Platform:  linux/amd64
  Platform:  linux/arm64
INSPECT
)"
    _setup_docker_mock_with_inspect "$multiarch_inspect" 0

    # Skopeo stub: exits non-zero immediately so push_dockerhub falls through to
    # the buildx path on any host (with or without real skopeo installed).
    # Choice: fast-failing stub + no-sleep retry override beats stripping PATH
    # (too fragile) and beats a non-executable stub (command -v would fall
    # through to any system skopeo).  retry_with_backoff 5 10 on a failing skopeo
    # would sleep 150 s; the override makes it a single-attempt, no-sleep call.
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # No-sleep retry: one attempt, no sleep — prevents slow retry on skopeo failure.
    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must be refused (non-zero); the buildx build --push must NOT have run
    [ "$status" -ne 0 ]
    ! grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log" 2>/dev/null
    [[ "$output" == *"multi-platform"* ]] || [[ "$output" == *"REFUSED"* ]]
}

@test "guard: local single-arch push allowed when target tag is absent (fail-open)" {
    # Mutation: if the guard incorrectly blocked on a missing tag, a first-time
    # push would always fail — demonstrating the guard fires only on confirmed
    # multi-arch manifests, not on probe failures.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # imagetools inspect exits non-zero (tag does not exist)
    _setup_docker_mock_with_inspect "manifest unknown" 1

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed (fail-open on missing tag)
    [ "$status" -eq 0 ]
    grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "guard: local single-arch push allowed when target tag is single-arch" {
    # Mutation: if the guard over-blocked single-arch targets, it would break
    # legitimate first-arch pushes to containers that never had multi-arch.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # imagetools inspect returns only one linux/* platform
    local singlearch_inspect
    singlearch_inspect="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.manifest.v1+json
Digest:    sha256:abc123
Platform:  linux/amd64
INSPECT
)"
    _setup_docker_mock_with_inspect "$singlearch_inspect" 0

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — no clobber risk
    [ "$status" -eq 0 ]
    grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "guard: ALLOW_MULTIARCH_CLOBBER=1 bypasses guard even when target is multi-platform" {
    # Mutation: if the override were ignored, the operator escape hatch would
    # not work and intentional clobbers (e.g. emergency rollback) would fail.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    export ALLOW_MULTIARCH_CLOBBER=1
    export GITHUB_REPOSITORY_OWNER="testowner"

    local multiarch_inspect
    multiarch_inspect="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:abc123

Manifests:
  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:aaa
  Platform:  linux/amd64

  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:bbb
  Platform:  linux/arm64
INSPECT
)"
    _setup_docker_mock_with_inspect "$multiarch_inspect" 0

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — operator override is active
    [ "$status" -eq 0 ]
    grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "guard: GITHUB_ACTIONS=true bypasses guard even when target is multi-platform" {
    # Mutation: if CI were not excluded, the bake/CI path (which sets
    # GITHUB_ACTIONS=true) would hit the imagetools inspect probe on every
    # push, adding latency and a potential point of failure in CI.
    # The guard must be a strict no-op in CI regardless of the manifest state.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_ACTIONS="true"
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    local multiarch_inspect
    multiarch_inspect="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:abc123

Manifests:
  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:aaa
  Platform:  linux/amd64

  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:bbb
  Platform:  linux/arm64
INSPECT
)"
    _setup_docker_mock_with_inspect "$multiarch_inspect" 0

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — CI is never blocked by the guard
    [ "$status" -eq 0 ]
    grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "guard: local single-arch push refused when :latest tag is multi-platform" {
    # Mutation: without probing the :latest tag, a push with wanted=latest
    # would silently overwrite the multi-arch :latest index even when the
    # versioned tag probe succeeds or is absent.  Both tags that a single
    # buildx call will push must each be probed independently.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    local multiarch_inspect
    multiarch_inspect="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:latest
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:abc123

Manifests:
  Name:      ghcr.io/testowner/testcontainer:latest@sha256:aaa
  Platform:  linux/amd64

  Name:      ghcr.io/testowner/testcontainer:latest@sha256:bbb
  Platform:  linux/arm64
INSPECT
)"
    # The versioned tag is absent (inspect fails), but :latest is multi-arch
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '%s' "$multiarch_inspect" > "$TEST_TEMP_DIR/inspect_output_latest"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER_CALL: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
    ref="$4"
    if [[ "$ref" == *":latest" ]]; then
        cat "$TEST_TEMP_DIR/inspect_output_latest"
        exit 0
    fi
    echo "manifest unknown" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must be refused because :latest is multi-arch
    [ "$status" -ne 0 ]
    ! grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log" 2>/dev/null
}

# Helper: docker mock that returns different inspect output depending on the ref.
# Callers pre-write <TEST_TEMP_DIR>/inspect_output_<safe_ref> files (where
# <safe_ref> replaces ':' and '/' with '_') and set inspect_rc_<safe_ref> files.
# Falls back to inspect_output / inspect_rc files when no per-ref file exists.
_setup_docker_mock_with_per_ref_inspect() {
    mkdir -p "$TEST_TEMP_DIR/bin"

    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "DOCKER_CALL: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
    ref="$4"
    safe_ref="${ref//[:\/]/_}"
    out_file="$TEST_TEMP_DIR/inspect_output_${safe_ref}"
    rc_file="$TEST_TEMP_DIR/inspect_rc_${safe_ref}"
    # Fall back to generic files when no per-ref file exists
    [[ -f "$out_file" ]] || out_file="$TEST_TEMP_DIR/inspect_output"
    [[ -f "$rc_file"  ]] || rc_file="$TEST_TEMP_DIR/inspect_rc"
    [[ -f "$out_file" ]] && cat "$out_file"
    exit "$(cat "$rc_file" 2>/dev/null || echo 1)"
fi
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

@test "guard: QEMU multi-platform path is never refused even when target is multi-platform" {
    # Mutation: if the guard fired on the QEMU path (platforms=linux/amd64,linux/arm64)
    # it would prevent a legitimate multi-arch rebuild of an existing multi-arch
    # index.  The guard must be restricted to the single-arch case
    # (platforms == linux/amd64) and must not trigger on QEMU builds.

    # Pin multi-platform path via the cache var BEFORE sourcing — re-source-proof.
    # build-container.sh checks MULTIPLATFORM_SUPPORTED first; setting it here
    # prevents the post-source function override from being the sole guarantee.
    export MULTIPLATFORM_SUPPORTED=true

    source_push_script

    # Function override kept as belt-and-suspenders (runs after re-source).
    check_multiplatform_support() { return 0; }

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    local multiarch_inspect
    multiarch_inspect="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:abc123

Manifests:
  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:aaa
  Platform:  linux/amd64

  Name:      ghcr.io/testowner/testcontainer:1.0.0@sha256:bbb
  Platform:  linux/arm64
INSPECT
)"
    _setup_docker_mock_with_inspect "$multiarch_inspect" 0

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_ghcr "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — QEMU multi-platform push does not clobber a multi-arch index
    [ "$status" -eq 0 ]
    grep -q "buildx build" "$TEST_TEMP_DIR/docker_calls.log"
}

# =============================================================================
# skopeo copy path — source-aware clobber guard tests
# Mutation articulated for each case: without the source-aware guard, a
# skopeo copy --all of a single-arch GHCR source would silently overwrite
# a multi-arch Docker Hub OCI index.
# =============================================================================

@test "skopeo path: GHCR source single-arch + Docker Hub target multi-arch → refused" {
    # Mutation: without the source-aware guard, skopeo copy --all of the
    # single-arch GHCR source would overwrite the multi-arch Docker Hub index.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # GHCR source: single-arch (only linux/amd64)
    local ghcr_single
    ghcr_single="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.manifest.v1+json
Platform:  linux/amd64
INSPECT
)"
    # Docker Hub target: multi-arch
    local dh_multi
    dh_multi="$(cat << 'INSPECT'
Name:      docker.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json

Manifests:
  Platform:  linux/amd64
  Platform:  linux/arm64
INSPECT
)"

    mkdir -p "$TEST_TEMP_DIR/bin"
    _setup_docker_mock_with_per_ref_inspect

    # Write per-ref inspect files using the same key-encoding as the mock
    # (replace ':' and '/' with '_')
    printf '%s' "$ghcr_single" > "$TEST_TEMP_DIR/inspect_output_ghcr.io_testowner_testcontainer_1.0.0"
    printf '0'                  > "$TEST_TEMP_DIR/inspect_rc_ghcr.io_testowner_testcontainer_1.0.0"
    printf '%s' "$dh_multi"    > "$TEST_TEMP_DIR/inspect_output_docker.io_testowner_testcontainer_1.0.0"
    printf '0'                  > "$TEST_TEMP_DIR/inspect_rc_docker.io_testowner_testcontainer_1.0.0"

    # skopeo stub exits 0 so we reach the copy path and can assert the guard
    # fires BEFORE the copy (i.e. push_dockerhub returns non-zero without
    # executing skopeo copy).
    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
echo "SKOPEO_CALL: $*" >> "$TEST_TEMP_DIR/skopeo_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"

    # No-sleep retry to keep the test fast
    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must be refused
    [ "$status" -ne 0 ]
    # skopeo copy --all must NOT have been executed
    ! grep -q "copy" "$TEST_TEMP_DIR/skopeo_calls.log" 2>/dev/null
    [[ "$output" == *"multi-platform"* ]] || [[ "$output" == *"REFUSED"* ]]
}

@test "skopeo path: GHCR source multi-arch + Docker Hub target multi-arch → allowed (legitimate mirror)" {
    # Mutation: if the guard were source-unaware and blocked on the target
    # being multi-arch regardless of the source, this legitimate multi-arch
    # mirror would be incorrectly refused.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # GHCR source: multi-arch
    local ghcr_multi
    ghcr_multi="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json

Manifests:
  Platform:  linux/amd64
  Platform:  linux/arm64
INSPECT
)"
    # Docker Hub target: also multi-arch
    local dh_multi
    dh_multi="$(cat << 'INSPECT'
Name:      docker.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json

Manifests:
  Platform:  linux/amd64
  Platform:  linux/arm64
INSPECT
)"

    mkdir -p "$TEST_TEMP_DIR/bin"
    _setup_docker_mock_with_per_ref_inspect

    printf '%s' "$ghcr_multi" > "$TEST_TEMP_DIR/inspect_output_ghcr.io_testowner_testcontainer_1.0.0"
    printf '0'                 > "$TEST_TEMP_DIR/inspect_rc_ghcr.io_testowner_testcontainer_1.0.0"
    printf '%s' "$dh_multi"   > "$TEST_TEMP_DIR/inspect_output_docker.io_testowner_testcontainer_1.0.0"
    printf '0'                 > "$TEST_TEMP_DIR/inspect_rc_docker.io_testowner_testcontainer_1.0.0"

    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
echo "SKOPEO_CALL: $*" >> "$TEST_TEMP_DIR/skopeo_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"

    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — multi-arch source faithfully mirrors to Docker Hub
    [ "$status" -eq 0 ]
    grep -q "copy" "$TEST_TEMP_DIR/skopeo_calls.log"
}

@test "skopeo path: Docker Hub target absent → push proceeds (no clobber risk)" {
    # Mutation: if the guard incorrectly blocked on a missing Docker Hub target,
    # a first-time skopeo mirror would always fail.  The fail-open semantics
    # must allow the copy when the target tag is absent.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # GHCR source: single-arch
    local ghcr_single
    ghcr_single="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.manifest.v1+json
Platform:  linux/amd64
INSPECT
)"

    mkdir -p "$TEST_TEMP_DIR/bin"
    _setup_docker_mock_with_per_ref_inspect

    printf '%s' "$ghcr_single"  > "$TEST_TEMP_DIR/inspect_output_ghcr.io_testowner_testcontainer_1.0.0"
    printf '0'                   > "$TEST_TEMP_DIR/inspect_rc_ghcr.io_testowner_testcontainer_1.0.0"
    # Docker Hub inspect fails (tag absent)
    printf 'manifest unknown'   > "$TEST_TEMP_DIR/inspect_output_docker.io_testowner_testcontainer_1.0.0"
    printf '1'                   > "$TEST_TEMP_DIR/inspect_rc_docker.io_testowner_testcontainer_1.0.0"

    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
echo "SKOPEO_CALL: $*" >> "$TEST_TEMP_DIR/skopeo_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"

    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — absent target is fail-open
    [ "$status" -eq 0 ]
    grep -q "copy" "$TEST_TEMP_DIR/skopeo_calls.log"
}

@test "skopeo path: GITHUB_ACTIONS=true bypasses source-aware guard" {
    # Mutation: if the guard fired in CI, the skopeo mirror step in GitHub
    # Actions would be blocked even for legitimate production pushes.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    export GITHUB_ACTIONS="true"
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # GHCR source: single-arch; Docker Hub target: multi-arch
    local ghcr_single
    ghcr_single="$(cat << 'INSPECT'
Name:      ghcr.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.manifest.v1+json
Platform:  linux/amd64
INSPECT
)"
    local dh_multi
    dh_multi="$(cat << 'INSPECT'
Name:      docker.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json

Manifests:
  Platform:  linux/amd64
  Platform:  linux/arm64
INSPECT
)"

    mkdir -p "$TEST_TEMP_DIR/bin"
    _setup_docker_mock_with_per_ref_inspect

    printf '%s' "$ghcr_single" > "$TEST_TEMP_DIR/inspect_output_ghcr.io_testowner_testcontainer_1.0.0"
    printf '0'                  > "$TEST_TEMP_DIR/inspect_rc_ghcr.io_testowner_testcontainer_1.0.0"
    printf '%s' "$dh_multi"    > "$TEST_TEMP_DIR/inspect_output_docker.io_testowner_testcontainer_1.0.0"
    printf '0'                  > "$TEST_TEMP_DIR/inspect_rc_docker.io_testowner_testcontainer_1.0.0"

    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
echo "SKOPEO_CALL: $*" >> "$TEST_TEMP_DIR/skopeo_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"

    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must succeed — CI is never blocked by the guard
    [ "$status" -eq 0 ]
    grep -q "copy" "$TEST_TEMP_DIR/skopeo_calls.log"
}

@test "skopeo path: GHCR source probe fails + Docker Hub target multi-arch → refused (fail-closed)" {
    # Mutation: if a failed GHCR source probe caused the guard to be skipped
    # (fail-open), a single-arch GHCR source that is only temporarily
    # unreachable for inspection could still clobber a multi-arch Docker Hub
    # index when skopeo can still copy.  The guard must apply on uncertainty.
    export MULTIPLATFORM_SUPPORTED=false
    check_multiplatform_support() { return 1; }
    export -f check_multiplatform_support

    source_push_script

    unset GITHUB_ACTIONS
    unset ALLOW_MULTIARCH_CLOBBER
    export GITHUB_REPOSITORY_OWNER="testowner"

    # Docker Hub target: multi-arch
    local dh_multi
    dh_multi="$(cat << 'INSPECT'
Name:      docker.io/testowner/testcontainer:1.0.0
MediaType: application/vnd.oci.image.index.v1+json

Manifests:
  Platform:  linux/amd64
  Platform:  linux/arm64
INSPECT
)"

    mkdir -p "$TEST_TEMP_DIR/bin"
    _setup_docker_mock_with_per_ref_inspect

    # GHCR source probe fails (inspect exits non-zero)
    printf 'manifest unknown' > "$TEST_TEMP_DIR/inspect_output_ghcr.io_testowner_testcontainer_1.0.0"
    printf '1'                 > "$TEST_TEMP_DIR/inspect_rc_ghcr.io_testowner_testcontainer_1.0.0"
    printf '%s' "$dh_multi"   > "$TEST_TEMP_DIR/inspect_output_docker.io_testowner_testcontainer_1.0.0"
    printf '0'                 > "$TEST_TEMP_DIR/inspect_rc_docker.io_testowner_testcontainer_1.0.0"

    cat > "$TEST_TEMP_DIR/bin/skopeo" << 'EOF'
#!/bin/bash
echo "SKOPEO_CALL: $*" >> "$TEST_TEMP_DIR/skopeo_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/skopeo"

    retry_with_backoff() { local _max=$1 _delay=$2; shift 2; "$@"; }

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    # Must be refused — GHCR source probe failure defaults to guarding the target
    [ "$status" -ne 0 ]
    ! grep -q "copy" "$TEST_TEMP_DIR/skopeo_calls.log" 2>/dev/null
    [[ "$output" == *"multi-platform"* ]] || [[ "$output" == *"REFUSED"* ]]
}
