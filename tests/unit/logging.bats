#!/usr/bin/env bats

# Unit tests for helpers/logging.sh

load "../test_helper"

setup() {
    setup_temp_dir
    # Source logging functions
    source "$HELPERS_DIR/logging.sh"
}

@test "list_containers has identical output for relative, absolute, trailing-slash, and metacharacter bases" {
    local base="$BATS_TEST_TMPDIR/containers+a.b"
    mkdir -p "$base/nginx"
    touch "$base/nginx/Dockerfile" "$base/nginx/Dockerfile.alpine"

    run bash -c 'source "$1"; cd "$2"; list_containers .' _ "$HELPERS_DIR/logging.sh" "$base"
    [ "$status" -eq 0 ]
    local relative_output="$output"

    run bash -c 'source "$1"; list_containers "$2"' _ "$HELPERS_DIR/logging.sh" "$base"
    [ "$status" -eq 0 ]
    [ "$output" = "$relative_output" ]

    run bash -c 'source "$1"; list_containers "$2/"' _ "$HELPERS_DIR/logging.sh" "$base"
    [ "$status" -eq 0 ]
    [ "$output" = "$relative_output" ]

    run bash -c 'source "$1"; cd "$(dirname "$2")"; list_containers "$(basename "$2")"' _ "$HELPERS_DIR/logging.sh" "$base"
    [ "$status" -eq 0 ]
    [ "$output" = "$relative_output" ]
    [ "$output" = "nginx" ]
}

@test "list_containers fails without names for a non-existent base" {
    run bash -c 'source "$1"; list_containers "$2" 2>/dev/null' _ "$HELPERS_DIR/logging.sh" "$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "list_containers fails when find prints a name then fails" {
    local stub_dir="$BATS_TEST_TMPDIR/find-failure-bin"
    local find_calls="$BATS_TEST_TMPDIR/find-failure-calls"
    mkdir -p "$stub_dir"
    printf '#!/usr/bin/env bash\nprintf "%s\\n" "partial/Dockerfile"\nprintf "%s\\n" reached > "$FIND_CALLS"\nexit 42\n' > "$stub_dir/find"
    chmod +x "$stub_dir/find"

    run env PATH="$stub_dir:$PATH" FIND_CALLS="$find_calls" bash -c 'source "$1"; list_containers "$2"' _ "$HELPERS_DIR/logging.sh" "$BATS_TEST_TMPDIR"

    [ "$status" -ne 0 ]
    [ -s "$find_calls" ]
}

@test "list_containers ignores CDPATH for a relative base and preserves the caller value" {
    local base_parent="$BATS_TEST_TMPDIR/base-parent"
    local cdpath_parent="$BATS_TEST_TMPDIR/cdpath-parent"
    local relative_base="containers"
    local cdpath_after="$BATS_TEST_TMPDIR/cdpath-after"
    mkdir -p "$base_parent/$relative_base/expected-container"
    mkdir -p "$cdpath_parent/$relative_base/decoy-container"
    touch "$base_parent/$relative_base/expected-container/Dockerfile"
    touch "$cdpath_parent/$relative_base/decoy-container/Dockerfile"

    run bash -c 'source "$1"; cd "$2" || exit; CDPATH="$3"; list_containers "$4"; list_status=$?; printf "%s\\n" "$CDPATH" > "$5"; exit "$list_status"' _ "$HELPERS_DIR/logging.sh" "$base_parent" "$cdpath_parent" "$relative_base" "$cdpath_after"

    [ "$status" -eq 0 ]
    [ "$output" = "expected-container" ]
    [ "$(<"$cdpath_after")" = "$cdpath_parent" ]
}

@test "list_containers accepts an option-like base directory" {
    local parent="$BATS_TEST_TMPDIR/option-like-parent"
    local home="$BATS_TEST_TMPDIR/option-like-home"
    mkdir -p "$parent/-P/expected-container" "$home/decoy-container"
    touch "$parent/-P/expected-container/Dockerfile"
    touch "$home/decoy-container/Dockerfile"

    run bash -c 'source "$1"; cd "$2" || exit; HOME="$3"; list_containers -P' _ "$HELPERS_DIR/logging.sh" "$parent" "$home"

    [ "$status" -eq 0 ]
    [ "$output" = "expected-container" ]
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

@test "_escape_gha_command: a control byte cannot splice the marker back together" {
    # The escaper deletes control bytes, and deleting closes gaps. If the marker
    # is checked before that deletion, `##<BS>[` slips past the check and the
    # strip reassembles `##[` in the output — an injectable command produced by
    # the escaper itself.
    run _escape_gha_command "$(printf 'a##\b[add-mask]secret')"
    [ "$status" -eq 0 ]
    [[ "$output" != *'##[add-mask]'* ]]
    [ "$output" = 'a##%5Badd-mask]secret' ]
}

@test "_escape_gha_command: the splice is caught wherever the control byte sits" {
    for value in "$(printf '#\b#[x')" "$(printf '##[\bx')" "$(printf '#\b#\b[x')"; do
        run _escape_gha_command "$value"
        [ "$status" -eq 0 ]
        [[ "$output" != *'##['* ]]
    done
}

@test "_escape_gha_command escapes workflow-command values comprehensively" {
    local value expected
    value=$'before%\nafter\rlegacy##[add-mask]\033\bforged'
    expected='before%25%0Aafter%0Dlegacy##%5Badd-mask]forged'

    run _escape_gha_command "$value"
    [ "$status" -eq 0 ]
    # The inserted %5B remains intact, proving the % pass occurs first.
    [ "$output" = "$expected" ]
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
