#!/usr/bin/env bash
# ===========================================================================
# test-harness.sh — Lightweight bash test harness
#
# Version: 0.1.0 | License: MIT
# Requires: bash 4.0+ (arrays). Bash 5.0+ recommended (EPOCHREALTIME timing).
#
# A zero-dependency test library for shell-based E2E and infrastructure tests.
# Provides continue-on-failure assertions, per-test timing, and three output
# formats: colored table (terminal), TAP v13, and JSON.
#
# Quick start:
#   source test-harness.sh
#   th_init --name "My Tests" --report table
#   th_group "Basics"
#   th_start
#   th_assert_cmd_contains "command greets" "hello" my_command --flag
#   th_summary  # prints report, returns 0 if all pass
#
# Prefer the command probes over `result=$(my_command)` followed by a text
# assertion: nothing there reads the command's status, so a producer that prints
# the expected value and then fails still passes.
#
# Assertions (all return 0 — safe with set -e):
#   th_assert_eq       "desc" "$actual" "$expected"
#   th_assert_ne       "desc" "$actual" "$unexpected"
#   th_assert_contains     "desc" "$haystack" "$needle"
#   th_assert_not_contains "desc" "$haystack" "$needle"
#   th_assert_not_empty    "desc" "$value"
#   th_assert_ge       "desc" "$actual" "$minimum"     # numeric >=
#   th_assert_gt       "desc" "$actual" "$minimum"     # numeric >
#   th_assert_matches  "desc" "$value" "$regex"
#
# Manual results:
#   th_pass "desc"                # record a pass
#   th_fail "desc" ["detail"]     # record a failure
#   th_skip "desc" ["reason"]     # record a skip
#
# Helpers:
#   th_group "name"    # start a named test group (visual separator)
#   th_start           # start timing for the next assertion
#   th_info "msg"      # informational message (not a test)
#   th_last_passed     # true if last test passed (for conditional flow)
#   th_summary         # print report, return 0 if all pass / 1 if any fail
#
# Environment:
#   NO_COLOR=1    Disable colors and emoji (https://no-color.org/)
# ===========================================================================

# Guard: prevent double-sourcing
[[ -n "${_TH_LOADED:-}" ]] && return 0
readonly _TH_LOADED=1
readonly TH_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
_TH_SUITE_NAME=""
_TH_REPORT=""
_TH_NO_COLOR=0

_TH_NAMES=()
_TH_STATUSES=()    # pass | fail | skip
_TH_TIMES_MS=()
_TH_GROUPS=()
_TH_DETAILS=()

_TH_PASS=0
_TH_FAIL=0
_TH_SKIP=0
_TH_TOTAL=0

_TH_SUITE_START_MS=0
_TH_TEST_START_MS=0
_TH_CURRENT_GROUP=""

# Colors and symbols (set by _th_setup_colors)
_C_RESET="" _C_RED="" _C_GREEN="" _C_YELLOW="" _C_DIM="" _C_BOLD=""
_S_PASS="" _S_FAIL="" _S_SKIP="" _S_INFO=""

# ---------------------------------------------------------------------------
# Internal: colors & symbols
# ---------------------------------------------------------------------------
_th_setup_colors() {
    if [[ "${NO_COLOR:-}" != "" ]] || [[ "$_TH_NO_COLOR" -eq 1 ]] || [[ ! -t 1 ]]; then
        _C_RESET="" _C_RED="" _C_GREEN="" _C_YELLOW="" _C_DIM="" _C_BOLD=""
        _S_PASS="PASS" _S_FAIL="FAIL" _S_SKIP="SKIP" _S_INFO=">"
    else
        _C_RESET=$'\033[0m' _C_RED=$'\033[0;31m' _C_GREEN=$'\033[0;32m'
        _C_YELLOW=$'\033[1;33m' _C_DIM=$'\033[2m' _C_BOLD=$'\033[1m'
        _S_PASS="✅" _S_FAIL="❌" _S_SKIP="⏭ " _S_INFO="→"
    fi
}

# ---------------------------------------------------------------------------
# Internal: timing (millisecond precision with bash 5.0+ EPOCHREALTIME)
# ---------------------------------------------------------------------------
_TH_TIMING_WARNED=0
_th_now_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local e="$EPOCHREALTIME"
        if [[ "$e" == *.* ]]; then
            local sec="${e%%.*}" frac="${e#*.}000"
            printf '%d' "$(( sec * 1000 + 10#${frac:0:3} ))"
        else
            printf '%d' "$(( e * 1000 ))"
        fi
    else
        if [[ "$_TH_TIMING_WARNED" -eq 0 ]]; then
            printf 'test-harness: bash %s detected — per-test timing limited to second precision (bash 5.0+ recommended)\n' "${BASH_VERSION}" >&2
            _TH_TIMING_WARNED=1
        fi
        printf '%d' "$(( $(date +%s) * 1000 ))"
    fi
}

_th_format_duration() {
    local ms="${1:-0}"
    if [[ "$ms" -le 0 ]]; then
        printf -- '-'
    elif [[ "$ms" -lt 1000 ]]; then
        printf '%dms' "$ms"
    elif [[ "$ms" -lt 60000 ]]; then
        printf '%d.%02ds' "$((ms / 1000))" "$(( (ms % 1000) / 10 ))"
    else
        local s=$((ms / 1000))
        printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
    fi
}

# ---------------------------------------------------------------------------
# Internal: JSON string escaping (no external deps)
# ---------------------------------------------------------------------------
_th_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Internal: record a test result
# ---------------------------------------------------------------------------
_th_record() {
    local status="$1" name="$2" detail="${3:-}"
    local elapsed_ms=0

    if [[ "$_TH_TEST_START_MS" -gt 0 ]]; then
        elapsed_ms=$(( $(_th_now_ms) - _TH_TEST_START_MS ))
        _TH_TEST_START_MS=0
    fi

    _TH_TOTAL=$((_TH_TOTAL + 1))
    _TH_NAMES+=("$name")
    _TH_STATUSES+=("$status")
    _TH_TIMES_MS+=("$elapsed_ms")
    _TH_GROUPS+=("${_TH_CURRENT_GROUP}")
    _TH_DETAILS+=("$detail")

    case "$status" in
        pass) _TH_PASS=$((_TH_PASS + 1)) ;;
        fail) _TH_FAIL=$((_TH_FAIL + 1)) ;;
        skip) _TH_SKIP=$((_TH_SKIP + 1)) ;;
    esac

    # Real-time output (table and TAP print immediately; JSON buffers)
    _th_print_result "$_TH_TOTAL" "$status" "$name" "$elapsed_ms" "$detail"
}

# ---------------------------------------------------------------------------
# Internal: real-time per-test output
# ---------------------------------------------------------------------------
_th_print_result() {
    local num="$1" status="$2" name="$3" ms="$4" detail="$5"

    case "$_TH_REPORT" in
        table)
            local icon time_str
            case "$status" in
                pass) icon="${_C_GREEN}${_S_PASS}${_C_RESET}" ;;
                fail) icon="${_C_RED}${_S_FAIL}${_C_RESET}" ;;
                skip) icon="${_C_YELLOW}${_S_SKIP}${_C_RESET}" ;;
            esac
            time_str=$(_th_format_duration "$ms")
            printf '  %s %s %s(%s)%s\n' "$icon" "$name" "$_C_DIM" "$time_str" "$_C_RESET"
            if [[ -n "$detail" ]]; then
                case "$status" in
                    fail) printf '      %s%s%s\n' "$_C_RED" "$detail" "$_C_RESET" ;;
                    skip) printf '      %s(%s)%s\n' "$_C_DIM" "$detail" "$_C_RESET" ;;
                esac
            fi
            ;;

        tap)
            case "$status" in
                pass) printf 'ok %d - %s' "$num" "$name" ;;
                fail) printf 'not ok %d - %s' "$num" "$name" ;;
                skip)
                    printf 'ok %d - %s # SKIP %s\n' "$num" "$name" "${detail:-}"
                    return
                    ;;
            esac
            if [[ "$ms" -gt 0 ]]; then
                printf ' # time=%s' "$(_th_format_duration "$ms")"
            fi
            printf '\n'
            if [[ "$status" == "fail" && -n "$detail" ]]; then
                printf '  ---\n'
                printf '  message: "%s"\n' "$(_th_json_escape "$detail")"
                printf '  ...\n'
            fi
            ;;

        json)
            # JSON: buffered, output in th_summary only
            ;;
    esac
}

# ===========================================================================
# Public API
# ===========================================================================

# Initialize (or reset) the test suite.
# Usage: th_init [--name NAME] [--report table|tap|json] [--no-color]
th_init() {
    _TH_NAMES=() _TH_STATUSES=() _TH_TIMES_MS=() _TH_GROUPS=() _TH_DETAILS=()
    _TH_PASS=0 _TH_FAIL=0 _TH_SKIP=0 _TH_TOTAL=0
    _TH_CURRENT_GROUP="" _TH_TEST_START_MS=0
    _TH_SUITE_NAME="Test Suite" _TH_REPORT="table" _TH_NO_COLOR=0
    # Public, so it survives a re-init unless cleared here — and a stale value
    # would let an assertion in the new suite pass against the old suite's output.
    TH_OUTPUT=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)     _TH_SUITE_NAME="$2"; shift 2 ;;
            --report)   _TH_REPORT="$2"; shift 2 ;;
            --no-color) _TH_NO_COLOR=1; shift ;;
            *)          shift ;;
        esac
    done

    # Validate the reporter — an invalid value used to produce no output at all
    case "$_TH_REPORT" in
        table|tap|json) ;;
        *) printf 'test-harness: unknown reporter "%s", falling back to table\n' "$_TH_REPORT" >&2
           _TH_REPORT="table" ;;
    esac

    _th_setup_colors
    _TH_SUITE_START_MS=$(_th_now_ms)

    case "$_TH_REPORT" in
        table)
            printf '\n  %s%s%s\n' "$_C_BOLD" "$_TH_SUITE_NAME" "$_C_RESET"
            printf '  %s════════════════════════════════════════════════%s\n' \
                "$_C_DIM" "$_C_RESET"
            ;;
        tap)
            printf 'TAP version 13\n'
            ;;
    esac
}

# Start a named test group (visual separator in output).
th_group() {
    _TH_CURRENT_GROUP="$1"
    case "$_TH_REPORT" in
        table) printf '\n  %s%s%s\n' "$_C_BOLD" "$1" "$_C_RESET" ;;
        tap)   printf '# %s\n' "$1" ;;
    esac
}

# Start timing for the next assertion.
th_start() {
    _TH_TEST_START_MS=$(_th_now_ms)
}

# Informational message (not a test result).
th_info() {
    case "$_TH_REPORT" in
        table) printf '  %s%s%s %s\n' "$_C_YELLOW" "$_S_INFO" "$_C_RESET" "$*" ;;
        tap)   printf '# %s\n' "$*" ;;
    esac
}

# ---------------------------------------------------------------------------
# Assertions — all return 0 for set -e compatibility
# ---------------------------------------------------------------------------

# Assert string equality.
th_assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "expected: '$expected', got: '$actual'"
    fi
    return 0
}

# Assert string inequality.
th_assert_ne() {
    local name="$1" actual="$2" unexpected="$3"
    if [[ "$actual" != "$unexpected" ]]; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "expected NOT: '$unexpected', but got it"
    fi
    return 0
}

# Assert haystack contains needle.
th_assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "'$haystack' does not contain '$needle'"
    fi
    return 0
}

# Assert haystack does NOT contain needle.
th_assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "'$haystack' should not contain '$needle'"
    fi
    return 0
}

# Assert value is non-empty.
th_assert_not_empty() {
    local name="$1" value="$2"
    if [[ -n "$value" ]]; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "expected non-empty value, got empty string"
    fi
    return 0
}

# Assert numeric greater-than-or-equal.
th_assert_ge() {
    local name="$1" actual="$2" minimum="$3"
    if [[ "$actual" -ge "$minimum" ]] 2>/dev/null; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "expected >= $minimum, got: '$actual'"
    fi
    return 0
}

# Assert numeric greater-than.
th_assert_gt() {
    local name="$1" actual="$2" minimum="$3"
    if [[ "$actual" -gt "$minimum" ]] 2>/dev/null; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "expected > $minimum, got: '$actual'"
    fi
    return 0
}

# Assert value matches regex pattern.
th_assert_matches() {
    local name="$1" value="$2" pattern="$3"
    if [[ "$value" =~ $pattern ]]; then
        _th_record pass "$name"
    else
        _th_record fail "$name" "'$value' does not match pattern '$pattern'"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Command probes
# ---------------------------------------------------------------------------
#
# Asserting on the text a command printed, without also requiring the command to
# have SUCCEEDED, is a false-green channel: a producer can print plausible output
# and then exit non-zero — a truncated HTTP transfer, a tool that prints a banner
# before failing, a `docker exec` that never reached the binary — and the text
# assertion passes anyway.
#
# `value=$(cmd)` does not hide that status; it lands in `$?`, and under `errexit`
# a plain assignment aborts on it. The suites here run WITHOUT errexit and never
# read `$?`, so nothing acts on it. (The form that genuinely discards it is
# `local value=$(cmd)`: the builtin's own status wins, and errexit does not fire.)
# Either way the omission is invisible at the call site, which is why the probe
# takes the command rather than trusting each caller to check.
#
# On the diagnostics: failure details name the command but never its arguments,
# so an argument list cannot leak a credential into a CI log. They DO carry the
# captured output when a text assertion fails — that is what makes a failure
# diagnosable, and a harness that hid it would not be one. The bound is therefore
# on the caller: do not point a probe at a command whose output is secret. A
# suite that must handle one validates it itself and reports a description
# instead of the value.
#
# These probes take the command instead of its output, so the status cannot be
# dropped on the way. Stderr is discarded, as the direct captures they replace
# did; the exit status is what carries failure now.

# Run a command, and record a failure if it did not succeed. On success its
# stdout is in $TH_OUTPUT and the caller's own validation may run; on failure
# $TH_OUTPUT is empty and this returns non-zero, so a caller chaining with `&&`
# cannot assert against output the command failed to produce.
#
# Usage: th_capture "name" cmd args... && th_assert_contains "name" "$TH_OUTPUT" x
th_capture() {
    local name="$1"; shift
    if (( $# == 0 )); then
        # An empty "$@" is a successful empty command substitution, so without
        # this a caller that dropped its command would silently pass.
        TH_OUTPUT=""
        _th_record fail "$name" "th_capture was given no command to run"
        return 1
    fi
    local status=0
    TH_OUTPUT=$("$@" 2>/dev/null) || status=$?
    if (( status != 0 )); then
        TH_OUTPUT=""
        # The command's ARGUMENTS are never recorded. Results reach the table,
        # the TAP stream and the JSON report, all of which land in CI logs, and
        # an argument list can carry a credential, a token or a signed URL. The
        # test name already says what was being probed.
        _th_record fail "$name" "command '$1' exited $status"
        return 1
    fi
    return 0
}

# Assert a command succeeds AND its output contains needle. Both are part of the
# assertion; either one failing fails the test.
#
# Usage: th_assert_cmd_contains "name" "needle" cmd args...
th_assert_cmd_contains() {
    local name="$1" needle="$2"; shift 2
    if th_capture "$name" "$@"; then
        th_assert_contains "$name" "$TH_OUTPUT" "$needle"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Manual results
# ---------------------------------------------------------------------------

# Record a pass.
th_pass() { _th_record pass "$1"; return 0; }

# Record a failure with optional detail.
th_fail() { _th_record fail "$1" "${2:-}"; return 0; }

# Record a skip with optional reason.
th_skip() { _th_record skip "$1" "${2:-}"; return 0; }

# Check if the last recorded test passed (for conditional flow).
# Usage: th_assert_eq "check" "$a" "$b"; th_last_passed || return
th_last_passed() {
    local n=${#_TH_STATUSES[@]}
    [[ "$n" -gt 0 && "${_TH_STATUSES[$((n - 1))]}" == "pass" ]]
}

# ===========================================================================
# Summary reporters
# ===========================================================================

_th_summary_table() {
    local total_ms=$(( $(_th_now_ms) - _TH_SUITE_START_MS ))
    local duration
    duration=$(_th_format_duration "$total_ms")

    printf '\n  %s════════════════════════════════════════════════%s\n' \
        "$_C_DIM" "$_C_RESET"

    local parts=""
    if [[ "$_TH_PASS" -gt 0 ]]; then
        parts+="${_C_GREEN}${_TH_PASS} passed${_C_RESET}"
    fi
    if [[ "$_TH_FAIL" -gt 0 ]]; then
        [[ -n "$parts" ]] && parts+=" │ "
        parts+="${_C_RED}${_TH_FAIL} failed${_C_RESET}"
    fi
    if [[ "$_TH_SKIP" -gt 0 ]]; then
        [[ -n "$parts" ]] && parts+=" │ "
        parts+="${_C_YELLOW}${_TH_SKIP} skipped${_C_RESET}"
    fi

    printf '   Tests   %s  (%d total)\n' "$parts" "$_TH_TOTAL"
    printf '   Time    %s\n' "$duration"
    printf '  %s════════════════════════════════════════════════%s\n' \
        "$_C_DIM" "$_C_RESET"
}

_th_summary_tap() {
    printf '1..%d\n' "$_TH_TOTAL"
}

_th_summary_json() {
    local total_ms=$(( $(_th_now_ms) - _TH_SUITE_START_MS ))

    printf '{\n'
    printf '  "suite": "%s",\n' "$(_th_json_escape "$_TH_SUITE_NAME")"
    printf '  "version": "%s",\n' "$TH_VERSION"
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
    printf '  "duration_ms": %d,\n' "$total_ms"
    printf '  "counts": { "total": %d, "pass": %d, "fail": %d, "skip": %d },\n' \
        "$_TH_TOTAL" "$_TH_PASS" "$_TH_FAIL" "$_TH_SKIP"
    printf '  "tests": [\n'

    if [[ "$_TH_TOTAL" -gt 0 ]]; then
        local i last=$((_TH_TOTAL - 1))
        for ((i = 0; i < _TH_TOTAL; i++)); do
            printf '    { "id": %d' "$((i + 1))"
            printf ', "group": "%s"' "$(_th_json_escape "${_TH_GROUPS[$i]}")"
            printf ', "name": "%s"' "$(_th_json_escape "${_TH_NAMES[$i]}")"
            printf ', "status": "%s"' "${_TH_STATUSES[$i]}"
            printf ', "duration_ms": %d' "${_TH_TIMES_MS[$i]}"
            if [[ -n "${_TH_DETAILS[$i]}" ]]; then
                printf ', "detail": "%s"' "$(_th_json_escape "${_TH_DETAILS[$i]}")"
            fi
            if [[ "$i" -lt "$last" ]]; then
                printf ' },\n'
            else
                printf ' }\n'
            fi
        done
    fi

    printf '  ]\n'
    printf '}\n'
}

# Print summary report and return exit code.
# Returns 0 if all tests passed, 1 if any failed.
th_summary() {
    case "$_TH_REPORT" in
        table) _th_summary_table ;;
        tap)   _th_summary_tap ;;
        json)  _th_summary_json ;;
    esac

    [[ "$_TH_FAIL" -eq 0 ]]
}
