#!/usr/bin/env bats

# Unit tests for helpers/logging.sh :: log_latency
#
# Each test names the mutation it catches so the Test Validity Gate is
# satisfied: a test that cannot name what mutation it catches is invalid.
#
# Network instrumentation (the callers in registry-utils.sh, etc.) cannot be
# unit-tested without live network mocks — those are out of scope here.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    source "$PROJECT_ROOT/helpers/logging.sh"
}

# ---------------------------------------------------------------------------
# Helper: portable sleep with sub-second support (bash 4+ / GNU coreutils).
# Falls back to 1s on environments where `sleep 0.X` is unavailable.
# ---------------------------------------------------------------------------
_sleep_half() {
    sleep 0.5 2>/dev/null || sleep 1
}

# ---------------------------------------------------------------------------
# Test 1: always emits exactly one [latency] line to stderr, nothing to stdout
#
# Mutation caught: removing the `printf '[latency] ...' >&2` line would make
# stderr empty — the test would fail on the stderr content check.
# ---------------------------------------------------------------------------
@test "log_latency emits [latency] line to stderr and nothing to stdout" {
    local t0=${EPOCHREALTIME:-0}
    _sleep_half
    # `run` captures stdout in $output; stderr goes to $stderr when bats >= 1.5.
    # For compatibility we redirect stderr to a temp file.
    local tmp_stderr
    tmp_stderr=$(mktemp)
    local stdout_capture
    stdout_capture=$(log_latency "test-label" "$t0" 2>"$tmp_stderr")
    local rc=$?

    # stdout must be empty
    [ -z "$stdout_capture" ]
    # stderr must contain the label and the [latency] marker
    grep -qF '[latency] test-label' "$tmp_stderr"
    rm -f "$tmp_stderr"
    [ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test 2: threshold ABOVE duration → no ::warning:: line
#
# Mutation caught: if the threshold comparison were inverted (< instead of >),
# a fast call with a high threshold would emit a spurious ::warning::.
# ---------------------------------------------------------------------------
@test "log_latency emits no warning when threshold is above duration" {
    local t0=${EPOCHREALTIME:-0}
    # Do NOT sleep — duration will be tiny (< 1ms).
    local tmp_stderr
    tmp_stderr=$(mktemp)
    log_latency "fast-call" "$t0" 9999 2>"$tmp_stderr"
    # Must not contain the warning annotation
    ! grep -qF '::warning::' "$tmp_stderr"
    rm -f "$tmp_stderr"
}

# ---------------------------------------------------------------------------
# Test 3: threshold BELOW duration → ::warning:: line appears on stderr
#
# Mutation caught: removing the warning printf block would make grep fail to
# find '::warning::' and the test would fail.
# ---------------------------------------------------------------------------
@test "log_latency emits ::warning:: when duration exceeds threshold" {
    local t0=${EPOCHREALTIME:-0}
    _sleep_half
    local tmp_stderr
    tmp_stderr=$(mktemp)
    log_latency "slow-call" "$t0" 0 2>"$tmp_stderr"
    # Must contain the warning annotation (threshold=0 always exceeded after any sleep)
    grep -qF '::warning::' "$tmp_stderr"
    grep -qF '[latency] slow-call' "$tmp_stderr"
    rm -f "$tmp_stderr"
}

# ---------------------------------------------------------------------------
# Test 4: EPOCHREALTIME empty/unset → emits explicit unavailability marker,
#         returns 0, and does NOT emit a ::warning:: or a misleading number.
#
# Mutation caught:
# - removing the early-return would let the function fall through and emit
#   `n/as` (or a shell-uptime integer via SECONDS), both untrustworthy —
#   the test asserts the exact "(timing unavailable…)" phrase.
# - if the threshold/::warning:: branch were not guarded by the early-return,
#   the `dur` variable would be unset and awk would produce a spurious warning.
# ---------------------------------------------------------------------------
@test "log_latency with EPOCHREALTIME unset emits unavailability marker, no warning" {
    local tmp_stderr
    tmp_stderr=$(mktemp)
    # Run in a subshell so unsetting EPOCHREALTIME does not affect the parent.
    # Pass empty start to simulate bash <5 caller.
    (
        unset EPOCHREALTIME 2>/dev/null || true
        log_latency "no-epochrealtime" "" 30 2>"$tmp_stderr"
    )
    local rc=$?
    # Must return 0
    [ "$rc" -eq 0 ]
    # Must emit the explicit unavailability phrase — NOT "n/as" or a number
    grep -qF '(timing unavailable: bash<5 lacks EPOCHREALTIME)' "$tmp_stderr"
    # Must NOT emit ::warning:: (threshold logic must be skipped)
    ! grep -qF '::warning::' "$tmp_stderr"
    # Must NOT emit the normal "%ss" latency line (early-return fires first)
    ! grep -qE '\[latency\] no-epochrealtime [0-9]' "$tmp_stderr"
    rm -f "$tmp_stderr"
}

# ---------------------------------------------------------------------------
# Test 5: stdout from log_latency is empty (cannot corrupt a captured payload)
#
# Mutation caught: if log_latency accidentally wrote to stdout (e.g. missing
# >&2 on a printf), command substitution callers would capture the timing noise
# as part of their JSON/string payload — this test catches that regression.
# ---------------------------------------------------------------------------
@test "log_latency produces no stdout output" {
    local t0=${EPOCHREALTIME:-0}
    local captured
    captured=$(log_latency "stdout-check" "$t0" 2>/dev/null)
    [ -z "$captured" ]
}
