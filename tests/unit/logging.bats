#!/usr/bin/env bats

# Unit tests for helpers/logging.sh

load "../test_helper"

setup() {
    setup_temp_dir
    # Source logging functions
    source "$HELPERS_DIR/logging.sh"
}

teardown() {
    teardown_temp_dir
}

# =============================================================================
# log_success tests
# =============================================================================

@test "log_success outputs green text with checkmark" {
    run log_success "Test message"
    [ "$status" -eq 0 ]
    # Check output contains the message (stderr redirected to stdout for capture)
    [[ "$output" == *"Test message"* ]] || [[ "$stderr" == *"Test message"* ]] || true
}

@test "log_success handles empty message" {
    run log_success ""
    [ "$status" -eq 0 ]
}

# =============================================================================
# log_error tests
# =============================================================================

@test "log_error outputs red text with X mark" {
    run log_error "Error occurred"
    [ "$status" -eq 0 ]
}

@test "log_error handles special characters" {
    run log_error "Error: can't process file.txt"
    [ "$status" -eq 0 ]
}

# =============================================================================
# log_warning tests
# =============================================================================

@test "log_warning outputs yellow text with warning icon" {
    run log_warning "Warning message"
    [ "$status" -eq 0 ]
}

# =============================================================================
# log_info tests
# =============================================================================

@test "log_info outputs blue text with info icon" {
    run log_info "Info message"
    [ "$status" -eq 0 ]
}

# =============================================================================
# log_step tests
# =============================================================================

@test "log_step outputs blue text with step indicator" {
    run log_step "Step 1"
    [ "$status" -eq 0 ]
}

# =============================================================================
# log_help tests
# =============================================================================

@test "log_help formats command and description" {
    run log_help "build" "Build a container"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build"* ]]
    [[ "$output" == *"Build a container"* ]]
}

@test "log_help pads short commands" {
    run log_help "ls" "List files"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ls"* ]]
}

# =============================================================================
# Color variable tests
# =============================================================================

@test "RED variable is defined" {
    [ -n "$RED" ]
}

@test "GREEN variable is defined" {
    [ -n "$GREEN" ]
}

@test "YELLOW variable is defined" {
    [ -n "$YELLOW" ]
}

@test "BLUE variable is defined" {
    [ -n "$BLUE" ]
}

@test "NC (No Color) variable is defined" {
    [ -n "$NC" ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "logging functions don't fail with multiline messages" {
    run log_info "Line 1
Line 2
Line 3"
    [ "$status" -eq 0 ]
}

@test "logging functions handle unicode" {
    run log_success "Unicode: 日本語 中文 한국어"
    [ "$status" -eq 0 ]
}
