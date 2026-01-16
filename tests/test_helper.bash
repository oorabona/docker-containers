#!/usr/bin/env bash

# Shared test helper utilities for bats tests

# Get project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
HELPERS_DIR="$PROJECT_ROOT/helpers"
TESTS_DIR="$PROJECT_ROOT/tests"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Load bats helper libraries if available
load_bats_helpers() {
    if [[ -d "$TESTS_DIR/test_helper/bats-support" ]]; then
        load "$TESTS_DIR/test_helper/bats-support/load"
    fi
    if [[ -d "$TESTS_DIR/test_helper/bats-assert" ]]; then
        load "$TESTS_DIR/test_helper/bats-assert/load"
    fi
}

# Create a temporary directory for test isolation
setup_temp_dir() {
    export TEST_TEMP_DIR="$(mktemp -d)"
}

# Clean up temporary directory
teardown_temp_dir() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Mock a command by creating a function or script
# Usage: mock_command "docker" "echo mocked"
mock_command() {
    local cmd_name="$1"
    local mock_output="$2"

    # Create mock script in temp dir
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/$cmd_name" << EOF
#!/bin/bash
$mock_output
EOF
    chmod +x "$TEST_TEMP_DIR/bin/$cmd_name"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Mock a file existence check
# Usage: mock_file "/proc/sys/fs/binfmt_misc/qemu-aarch64"
mock_file() {
    local file_path="$1"
    local content="${2:-}"

    local dir_path="$(dirname "$file_path")"
    mkdir -p "$TEST_TEMP_DIR$dir_path"

    if [[ -n "$content" ]]; then
        echo "$content" > "$TEST_TEMP_DIR$file_path"
    else
        touch "$TEST_TEMP_DIR$file_path"
    fi
}

# Create a mock container directory with version.sh
# Usage: create_mock_container "mycontainer" "1.2.3"
create_mock_container() {
    local name="$1"
    local version="${2:-1.0.0}"

    mkdir -p "$TEST_TEMP_DIR/$name"

    # Create mock Dockerfile
    cat > "$TEST_TEMP_DIR/$name/Dockerfile" << EOF
FROM debian:latest
LABEL version="$version"
EOF

    # Create mock version.sh
    cat > "$TEST_TEMP_DIR/$name/version.sh" << EOF
#!/bin/bash
if [[ "\$1" == "--registry-pattern" ]]; then
    echo "^[0-9]+\.[0-9]+(\.[0-9]+)?$"
else
    echo "$version"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/$name/version.sh"
}

# Assert that output contains a string
# Usage: assert_output_contains "expected"
assert_output_contains() {
    local expected="$1"
    if [[ "$output" != *"$expected"* ]]; then
        echo "Expected output to contain: $expected"
        echo "Actual output: $output"
        return 1
    fi
}

# Assert that output does not contain a string
# Usage: assert_output_not_contains "unexpected"
assert_output_not_contains() {
    local unexpected="$1"
    if [[ "$output" == *"$unexpected"* ]]; then
        echo "Expected output NOT to contain: $unexpected"
        echo "Actual output: $output"
        return 1
    fi
}

# Assert variable equals expected value
# Usage: assert_equals "expected" "$actual" "description"
assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="${3:-}"

    if [[ "$expected" != "$actual" ]]; then
        echo "Assertion failed${description:+: $description}"
        echo "Expected: $expected"
        echo "Actual: $actual"
        return 1
    fi
}

# Source a script with functions only (no execution)
# This sources the file but prevents any top-level execution
source_functions_only() {
    local script="$1"

    # Source with BASH_SOURCE check to prevent main execution
    # Most scripts check this at the end
    (
        source "$script"
    ) 2>/dev/null || true

    # Now source for real in current shell
    source "$script" 2>/dev/null || true
}

# Source a script that has dependencies on other scripts
# This handles the $(dirname "$0") issue in scripts
source_script_with_deps() {
    local script="$1"
    local script_dir="$(dirname "$script")"

    # Temporarily change to script directory to make relative paths work
    pushd "$script_dir" > /dev/null 2>&1

    # Source the script from its own directory
    source "$(basename "$script")" 2>/dev/null || {
        popd > /dev/null 2>&1
        return 1
    }

    popd > /dev/null 2>&1
}

# Counter for tracking mock command calls
declare -g MOCK_CALL_COUNT=0

# Create a mock that tracks call count
# Usage: mock_command_with_counter "cmd" "output"
mock_command_with_counter() {
    local cmd_name="$1"
    local mock_output="$2"
    local counter_file="$TEST_TEMP_DIR/.mock_count_$cmd_name"

    echo "0" > "$counter_file"

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/$cmd_name" << EOF
#!/bin/bash
count=\$(cat "$counter_file")
echo \$((count + 1)) > "$counter_file"
$mock_output
EOF
    chmod +x "$TEST_TEMP_DIR/bin/$cmd_name"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Get mock call count
# Usage: get_mock_call_count "cmd"
get_mock_call_count() {
    local cmd_name="$1"
    local counter_file="$TEST_TEMP_DIR/.mock_count_$cmd_name"

    if [[ -f "$counter_file" ]]; then
        cat "$counter_file"
    else
        echo "0"
    fi
}

# Export variables
export PROJECT_ROOT SCRIPTS_DIR HELPERS_DIR TESTS_DIR FIXTURES_DIR
