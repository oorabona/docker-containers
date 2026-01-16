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
    # Mock check_multiplatform_support
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
    run push_dockerhub "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "docker.io/testowner/testcontainer" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "push_dockerhub uses read-only cache (no cache-to)" {
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
    run push_container "testcontainer" "1.0.0" "1.0.0" "latest"

    [ "$status" -eq 0 ]
    grep -q "ghcr.io" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "docker.io" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "push_container continues if Docker Hub fails" {
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
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_container "testcontainer" "1.0.0" "1.0.0" "latest"

    # Should still succeed overall (GHCR is primary)
    [ "$status" -eq 0 ]
}

@test "push_container fails if GHCR fails" {
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
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run push_container "testcontainer" "1.0.0" "1.0.0" "latest"

    # Should fail since GHCR is primary
    [ "$status" -eq 1 ]
}
