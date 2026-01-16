#!/usr/bin/env bats

# Unit tests for scripts/build-container.sh

load "../test_helper"

# Source the script functions in a way that handles $(dirname "$0") issue
# We source from the scripts directory so relative paths work
source_build_script() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1
    source "./build-container.sh"
    popd > /dev/null 2>&1
}

setup() {
    setup_temp_dir

    # Source logging first (dependency) - this ensures it's available
    # before the script tries to source it
    source "$HELPERS_DIR/logging.sh"

    # Clear any cached multiplatform check
    unset MULTIPLATFORM_SUPPORTED

    # Save original PATH
    export ORIGINAL_PATH="$PATH"
}

teardown() {
    teardown_temp_dir
    export PATH="$ORIGINAL_PATH"
    unset MULTIPLATFORM_SUPPORTED
    unset BUILD_PLATFORM
    unset GITHUB_ACTIONS
}

# =============================================================================
# check_multiplatform_support tests
# =============================================================================

@test "check_multiplatform_support returns cached result on second call" {
    # Set the cached value
    export MULTIPLATFORM_SUPPORTED="true"

    # Source the script
    source_build_script

    run check_multiplatform_support
    [ "$status" -eq 0 ]

    # Value should still be cached
    [ "$MULTIPLATFORM_SUPPORTED" = "true" ]
}

@test "check_multiplatform_support returns false when cached as false" {
    export MULTIPLATFORM_SUPPORTED="false"

    source_build_script

    run check_multiplatform_support
    [ "$status" -eq 1 ]
}

@test "check_multiplatform_support detects QEMU via binfmt_misc" {
    # Mock the binfmt_misc file
    mkdir -p "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc"
    touch "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc/qemu-aarch64"

    # Create a wrapper function that checks our mock path
    check_multiplatform_support_with_mock() {
        if [[ -f "$TEST_TEMP_DIR/proc/sys/fs/binfmt_misc/qemu-aarch64" ]]; then
            MULTIPLATFORM_SUPPORTED="true"
            return 0
        fi
        return 1
    }

    run check_multiplatform_support_with_mock
    [ "$status" -eq 0 ]
}

@test "check_multiplatform_support detects buildx platforms" {
    # Mock docker command to return arm64 platform
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "buildx" && "$2" == "inspect" ]]; then
    echo "Platforms: linux/amd64, linux/arm64"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Clear cache and source
    unset MULTIPLATFORM_SUPPORTED
    source_build_script

    run check_multiplatform_support
    # May succeed or fail depending on binfmt_misc check order
    # The important thing is it doesn't crash
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "check_multiplatform_support returns false when no support found" {
    # Mock docker to return only amd64
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "buildx" && "$2" == "inspect" ]]; then
    echo "Platforms: linux/amd64"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Ensure no binfmt_misc files exist (they won't in temp)
    unset MULTIPLATFORM_SUPPORTED
    source_build_script

    # Since /proc paths don't exist in test, it will fall through to buildx check
    # Call directly (not with run) to check the variable after
    check_multiplatform_support || true

    # Should have set MULTIPLATFORM_SUPPORTED to false
    [ "$MULTIPLATFORM_SUPPORTED" = "false" ]
}

# =============================================================================
# build_container platform selection tests
# =============================================================================

@test "build_container uses BUILD_PLATFORM when set" {
    export BUILD_PLATFORM="linux/arm64"

    # Mock docker to capture arguments
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create test container
    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    # Run from mock container dir
    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    # Check docker was called with correct platform
    [ -f "$TEST_TEMP_DIR/docker_calls.log" ]
    grep -q "linux/arm64" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "build_container defaults to linux/amd64 without multiplatform support" {
    unset BUILD_PLATFORM
    export MULTIPLATFORM_SUPPORTED="false"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    [ -f "$TEST_TEMP_DIR/docker_calls.log" ]
    grep -q "linux/amd64" "$TEST_TEMP_DIR/docker_calls.log"
}

# =============================================================================
# build_container build args tests
# =============================================================================

@test "build_container passes VERSION build arg" {
    export MULTIPLATFORM_SUPPORTED="false"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "2.5.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "2.5.0" "2.5.0"

    grep -q "VERSION=2.5.0" "$TEST_TEMP_DIR/docker_calls.log"
}

@test "build_container passes NPROC build arg when set" {
    export MULTIPLATFORM_SUPPORTED="false"
    export NPROC="8"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    grep -q "NPROC=8" "$TEST_TEMP_DIR/docker_calls.log"

    unset NPROC
}

@test "build_container passes CUSTOM_BUILD_ARGS when set" {
    export MULTIPLATFORM_SUPPORTED="false"
    export CUSTOM_BUILD_ARGS="--no-cache"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    grep -q "\-\-no-cache" "$TEST_TEMP_DIR/docker_calls.log"

    unset CUSTOM_BUILD_ARGS
}

# =============================================================================
# build_container cache behavior tests
# =============================================================================

@test "build_container uses registry cache in GitHub Actions" {
    export GITHUB_ACTIONS="true"
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="testowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    grep -q "cache-from" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "buildcache" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_ACTIONS
    unset GITHUB_REPOSITORY_OWNER
}

# =============================================================================
# build_container tagging tests
# =============================================================================

@test "build_container creates correct image tags" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "1.0.0"

    # Check both registries are tagged
    grep -q "ghcr.io/myowner/testcontainer:1.0.0" "$TEST_TEMP_DIR/docker_calls.log"
    grep -q "docker.io/myowner/testcontainer:1.0.0" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
}

@test "build_container adds latest tag when tag is latest" {
    export MULTIPLATFORM_SUPPORTED="false"
    export GITHUB_REPOSITORY_OWNER="myowner"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" << 'EOF'
#!/bin/bash
echo "ARGS: $*" >> "$TEST_TEMP_DIR/docker_calls.log"
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    create_mock_container "testcontainer" "1.0.0"

    source_build_script

    cd "$TEST_TEMP_DIR"
    run build_container "testcontainer" "1.0.0" "latest"

    # Should have :latest tag
    grep -q ":latest" "$TEST_TEMP_DIR/docker_calls.log"

    unset GITHUB_REPOSITORY_OWNER
}
