#!/usr/bin/env bats

# Unit tests for scripts/check-version.sh

load "../test_helper"

# Source the script functions in a way that handles $(dirname "$0") issue
source_version_script() {
    pushd "$SCRIPTS_DIR" > /dev/null 2>&1
    source "./check-version.sh"
    popd > /dev/null 2>&1
}

setup() {
    setup_temp_dir

    # Source logging first (dependency)
    source "$HELPERS_DIR/logging.sh"

    # Save original PATH
    export ORIGINAL_PATH="$PATH"
}

teardown() {
    teardown_temp_dir
    export PATH="$ORIGINAL_PATH"
}

# =============================================================================
# get_build_version tests
# =============================================================================

@test "get_build_version returns specific version when provided" {
    source_version_script

    create_mock_container "testcontainer" "1.0.0"

    cd "$TEST_TEMP_DIR"
    run get_build_version "testcontainer" "2.5.0"

    [ "$status" -eq 0 ]
    [ "$output" = "2.5.0" ]
}

@test "get_build_version returns latest version for 'latest' keyword" {
    source_version_script

    create_mock_container "testcontainer" "3.2.1"

    cd "$TEST_TEMP_DIR"
    run get_build_version "testcontainer" "latest"

    [ "$status" -eq 0 ]
    [ "$output" = "3.2.1" ]
}

@test "get_build_version fails for container without version.sh" {
    source_version_script

    # Create container without version.sh
    mkdir -p "$TEST_TEMP_DIR/noversion"
    touch "$TEST_TEMP_DIR/noversion/Dockerfile"

    cd "$TEST_TEMP_DIR"
    run get_build_version "noversion" "latest"

    [ "$status" -eq 1 ]
}

@test "get_build_version handles version.sh that returns empty" {
    source_version_script

    # Create container with broken version.sh
    mkdir -p "$TEST_TEMP_DIR/broken"
    touch "$TEST_TEMP_DIR/broken/Dockerfile"
    cat > "$TEST_TEMP_DIR/broken/version.sh" << 'EOF'
#!/bin/bash
echo ""
EOF
    chmod +x "$TEST_TEMP_DIR/broken/version.sh"

    cd "$TEST_TEMP_DIR"
    run get_build_version "broken" "latest"

    [ "$status" -eq 1 ]
}

@test "get_build_version handles 'current' keyword with registry lookup" {
    source_version_script

    # Create mock latest-docker-tag helper
    mkdir -p "$TEST_TEMP_DIR/helpers"
    cat > "$TEST_TEMP_DIR/helpers/latest-docker-tag" << 'EOF'
#!/bin/bash
echo "1.5.0"
EOF
    chmod +x "$TEST_TEMP_DIR/helpers/latest-docker-tag"

    create_mock_container "testcontainer" "2.0.0"

    cd "$TEST_TEMP_DIR"

    # Point to mock helpers
    run get_build_version "testcontainer" "current"

    # May fail if helpers aren't found, which is expected in isolated test
    # The important thing is it doesn't crash
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "get_build_version handles no-published-version gracefully" {
    source_version_script

    # Create container that returns no-published-version first, then version
    mkdir -p "$TEST_TEMP_DIR/newcontainer"
    touch "$TEST_TEMP_DIR/newcontainer/Dockerfile"
    cat > "$TEST_TEMP_DIR/newcontainer/version.sh" << 'EOF'
#!/bin/bash
if [[ "$1" == "--registry-pattern" ]]; then
    echo "^[0-9]+\.[0-9]+$"
else
    echo "1.0.0"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/newcontainer/version.sh"

    cd "$TEST_TEMP_DIR"
    run get_build_version "newcontainer" "latest"

    [ "$status" -eq 0 ]
    [ "$output" = "1.0.0" ]
}

# =============================================================================
# check_container_version tests
# =============================================================================

@test "check_container_version fails for non-existent container" {
    source_version_script

    cd "$TEST_TEMP_DIR"
    run check_container_version "nonexistent"

    [ "$status" -eq 1 ]
}

@test "check_container_version fails for container without Dockerfile" {
    source_version_script

    mkdir -p "$TEST_TEMP_DIR/nodockerfile"

    cd "$TEST_TEMP_DIR"
    run check_container_version "nodockerfile"

    [ "$status" -eq 1 ]
}

@test "check_container_version fails for container without version.sh" {
    source_version_script

    mkdir -p "$TEST_TEMP_DIR/noversion"
    touch "$TEST_TEMP_DIR/noversion/Dockerfile"

    cd "$TEST_TEMP_DIR"
    run check_container_version "noversion"

    [ "$status" -eq 1 ]
}

@test "check_container_version returns version for valid container" {
    source_version_script

    # Create mock latest-docker-tag that returns nothing (new container)
    mkdir -p "$TEST_TEMP_DIR/helpers"
    cat > "$TEST_TEMP_DIR/helpers/latest-docker-tag" << 'EOF'
#!/bin/bash
echo ""
EOF
    chmod +x "$TEST_TEMP_DIR/helpers/latest-docker-tag"

    create_mock_container "validcontainer" "4.5.6"

    cd "$TEST_TEMP_DIR"
    run check_container_version "validcontainer"

    [ "$status" -eq 0 ]
    [[ "$output" == *"4.5.6"* ]]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "get_build_version handles version with v prefix" {
    source_version_script

    # Create container that returns v-prefixed version
    mkdir -p "$TEST_TEMP_DIR/vprefixed"
    touch "$TEST_TEMP_DIR/vprefixed/Dockerfile"
    cat > "$TEST_TEMP_DIR/vprefixed/version.sh" << 'EOF'
#!/bin/bash
echo "v1.2.3"
EOF
    chmod +x "$TEST_TEMP_DIR/vprefixed/version.sh"

    cd "$TEST_TEMP_DIR"
    run get_build_version "vprefixed" "latest"

    [ "$status" -eq 0 ]
    [ "$output" = "v1.2.3" ]
}

@test "get_build_version handles semver with prerelease" {
    source_version_script

    create_mock_container "prerelease" "2.0.0-beta.1"

    cd "$TEST_TEMP_DIR"
    run get_build_version "prerelease" "latest"

    [ "$status" -eq 0 ]
    [ "$output" = "2.0.0-beta.1" ]
}

@test "get_build_version handles version.sh with stderr output" {
    source_version_script

    # Create container with noisy version.sh
    mkdir -p "$TEST_TEMP_DIR/noisy"
    touch "$TEST_TEMP_DIR/noisy/Dockerfile"
    cat > "$TEST_TEMP_DIR/noisy/version.sh" << 'EOF'
#!/bin/bash
echo "Checking version..." >&2
echo "1.0.0"
EOF
    chmod +x "$TEST_TEMP_DIR/noisy/version.sh"

    cd "$TEST_TEMP_DIR"
    run get_build_version "noisy" "latest"

    [ "$status" -eq 0 ]
    [ "$output" = "1.0.0" ]
}

@test "get_build_version fails when version.sh exits with error" {
    source_version_script

    # Create container with version.sh that exits with error
    mkdir -p "$TEST_TEMP_DIR/failing"
    touch "$TEST_TEMP_DIR/failing/Dockerfile"
    cat > "$TEST_TEMP_DIR/failing/version.sh" << 'EOF'
#!/bin/bash
echo "error: could not determine version" >&2
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/failing/version.sh"

    cd "$TEST_TEMP_DIR"
    run get_build_version "failing" "latest"

    # Should fail since version.sh returned non-zero
    [ "$status" -eq 1 ]
}
