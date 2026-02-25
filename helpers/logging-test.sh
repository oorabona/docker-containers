#!/usr/bin/env bash
# Tests for helpers/logging.sh using test-harness
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../test-harness/test-harness.sh"
source "$SCRIPT_DIR/logging.sh"

th_init --name "helpers/logging.sh" --report table

# ---------------------------------------------------------------------------
th_group "Color constants"
# ---------------------------------------------------------------------------

th_start
th_assert_not_empty "RED is defined" "$RED"

th_start
th_assert_not_empty "GREEN is defined" "$GREEN"

th_start
th_assert_not_empty "YELLOW is defined" "$YELLOW"

th_start
th_assert_not_empty "BLUE is defined" "$BLUE"

th_start
th_assert_eq "NC resets color" "$NC" '\033[0m'

# ---------------------------------------------------------------------------
th_group "Log functions write to stderr"
# ---------------------------------------------------------------------------

th_start
output=$(log_success "test message" 2>&1 1>/dev/null)
th_assert_not_empty "log_success writes to stderr" "$output"

th_start
output=$(log_error "test message" 2>&1 1>/dev/null)
th_assert_not_empty "log_error writes to stderr" "$output"

th_start
output=$(log_warning "test message" 2>&1 1>/dev/null)
th_assert_not_empty "log_warning writes to stderr" "$output"

th_start
output=$(log_info "test message" 2>&1 1>/dev/null)
th_assert_not_empty "log_info writes to stderr" "$output"

th_start
output=$(log_step "test message" 2>&1 1>/dev/null)
th_assert_not_empty "log_step writes to stderr" "$output"

# ---------------------------------------------------------------------------
th_group "Log functions do not write to stdout"
# ---------------------------------------------------------------------------

th_start
output=$(log_success "test" 2>/dev/null)
th_assert_eq "log_success stdout is empty" "$output" ""

th_start
output=$(log_error "test" 2>/dev/null)
th_assert_eq "log_error stdout is empty" "$output" ""

th_start
output=$(log_warning "test" 2>/dev/null)
th_assert_eq "log_warning stdout is empty" "$output" ""

th_start
output=$(log_info "test" 2>/dev/null)
th_assert_eq "log_info stdout is empty" "$output" ""

th_start
output=$(log_step "test" 2>/dev/null)
th_assert_eq "log_step stdout is empty" "$output" ""

# ---------------------------------------------------------------------------
th_group "Log message content"
# ---------------------------------------------------------------------------

th_start
output=$(log_success "hello world" 2>&1 1>/dev/null)
th_assert_contains "log_success contains message" "$output" "hello world"

th_start
output=$(log_error "failure reason" 2>&1 1>/dev/null)
th_assert_contains "log_error contains message" "$output" "failure reason"

th_start
output=$(log_warning "watch out" 2>&1 1>/dev/null)
th_assert_contains "log_warning contains message" "$output" "watch out"

th_start
output=$(log_info "details here" 2>&1 1>/dev/null)
th_assert_contains "log_info contains message" "$output" "details here"

th_start
output=$(log_step "step 1" 2>&1 1>/dev/null)
th_assert_contains "log_step contains message" "$output" "step 1"

# ---------------------------------------------------------------------------
th_group "Log functions include color codes"
# ---------------------------------------------------------------------------

# Color vars use \033 literal; echo -e interprets to real ESC char (\x1b)
ESC=$'\033'

th_start
output=$(log_success "msg" 2>&1 1>/dev/null)
th_assert_contains "log_success uses color escape" "$output" "${ESC}[0;32m"

th_start
output=$(log_error "msg" 2>&1 1>/dev/null)
th_assert_contains "log_error uses color escape" "$output" "${ESC}[0;31m"

th_start
output=$(log_warning "msg" 2>&1 1>/dev/null)
th_assert_contains "log_warning uses color escape" "$output" "${ESC}[1;33m"

th_start
output=$(log_info "msg" 2>&1 1>/dev/null)
th_assert_contains "log_info uses color escape" "$output" "${ESC}[0;34m"

th_start
output=$(log_step "msg" 2>&1 1>/dev/null)
th_assert_contains "log_step uses color escape" "$output" "${ESC}[0;34m"

# ---------------------------------------------------------------------------
# log_help writes to stdout (printf, no >&2), so capture stdout directly
th_group "log_help formatting"
# ---------------------------------------------------------------------------

th_start
output=$(log_help "command" "description")
th_assert_contains "log_help contains label" "$output" "command"

th_start
output=$(log_help "build" "Build a container")
th_assert_contains "log_help contains description" "$output" "Build a container"

# ---------------------------------------------------------------------------
th_group "Multiple arguments"
# ---------------------------------------------------------------------------

th_start
output=$(log_success "arg1" "arg2" "arg3" 2>&1 1>/dev/null)
th_assert_contains "log_success joins multiple args" "$output" "arg1 arg2 arg3"

th_start
output=$(log_error "multi" "word" "error" 2>&1 1>/dev/null)
th_assert_contains "log_error joins multiple args" "$output" "multi word error"

# ---------------------------------------------------------------------------
th_group "Color constants are readonly"
# ---------------------------------------------------------------------------

th_start
if (RED="changed" 2>/dev/null); then
    th_fail "RED should be readonly"
else
    th_pass "RED is readonly"
fi

th_summary
