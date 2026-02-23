# test-harness

A zero-dependency bash test library for shell-based E2E and infrastructure tests. Provides continue-on-failure assertions, per-test timing, and three output formats: colored table, TAP v13, and JSON.

Requires bash 4.0+. Bash 5.0+ recommended for millisecond-precision timing.

## Quick Start

```bash
source /path/to/test-harness/test-harness.sh

th_init --name "My Tests" --report table

th_group "Connectivity"
th_start
result=$(my_command)
th_assert_eq "command returns hello" "$result" "hello"

th_group "Content"
th_start
th_assert_contains "output mentions version" "$result" "v1."

th_summary  # prints report, exits 0 if all pass / 1 if any fail
```

## API Reference

### Initialization

**`th_init [--name NAME] [--report table|tap|json] [--no-color]`**

Initializes (or resets) the test suite. Call once before any tests.

- `--name`: Suite name shown in the header. Default: `Test Suite`.
- `--report`: Output format. Default: `table`. Invalid values fall back to `table` with a warning.
- `--no-color`: Force plain-text output. Colors are also suppressed when `NO_COLOR=1` is set or stdout is not a terminal.

### Grouping and Timing

**`th_group "name"`**

Starts a named test group. In table mode, prints a bold section header. In TAP mode, prints a comment line. Has no effect in JSON mode (group names are still recorded per test).

**`th_start`**

Starts the timer for the next assertion. Call immediately before the code under test to get accurate per-test timing. If omitted, the recorded duration is 0.

**`th_info "message"`**

Prints an informational message that is not recorded as a test result. Useful for progress notes and context. Suppressed in JSON mode.

### Assertions

All assertions return exit code 0 and are safe to use with `set -e`. On failure, the test is recorded with a descriptive detail message but execution continues.

**`th_assert_eq "desc" "$actual" "$expected"`**

Passes if `$actual == $expected` (string comparison).

**`th_assert_ne "desc" "$actual" "$unexpected"`**

Passes if `$actual != $unexpected` (string comparison).

**`th_assert_contains "desc" "$haystack" "$needle"`**

Passes if `$haystack` contains `$needle` as a substring.

**`th_assert_not_contains "desc" "$haystack" "$needle"`**

Passes if `$haystack` does not contain `$needle`.

**`th_assert_not_empty "desc" "$value"`**

Passes if `$value` is a non-empty string.

**`th_assert_ge "desc" "$actual" "$minimum"`**

Passes if `$actual >= $minimum` (numeric comparison).

**`th_assert_gt "desc" "$actual" "$minimum"`**

Passes if `$actual > $minimum` (numeric comparison).

**`th_assert_matches "desc" "$value" "$regex"`**

Passes if `$value` matches the bash regex `$regex` (uses `[[ =~ ]]`).

### Manual Results

**`th_pass "desc"`**

Records a pass directly, without an assertion. Useful when the test logic is conditional.

**`th_fail "desc" ["detail"]`**

Records a failure with an optional detail message.

**`th_skip "desc" ["reason"]`**

Records a skip with an optional reason. Skips do not count as failures.

**`th_last_passed`**

Returns exit code 0 if the most recently recorded test passed, 1 otherwise. Use this for conditional flow when a failing test would make subsequent tests meaningless:

```bash
th_assert_eq "container is running" "$status" "running"
th_last_passed || { th_info "Aborting: container not available"; return; }
```

### Summary

**`th_summary`**

Prints the final report for the current reporter and returns exit code 0 if all tests passed, 1 if any failed. Call once at the end of the suite.

## Reporter Modes

### table (default)

Colored terminal output with a header, per-test lines, and a summary footer. Colors and symbols are disabled automatically when stdout is not a terminal or `NO_COLOR=1` is set.

```
  PostgreSQL E2E Tests
  ════════════════════════════════════════════════

  Base Tests
  PASS Connectivity (243ms)
  PASS Basic query works (12ms)
  FAIL Extension pg_stat_statements should be installed but isn't
        expected extension to be present

   Tests   3 passed | 1 failed  (4 total)
   Time    255ms
  ════════════════════════════════════════════════
```

### tap

TAP version 13 output, compatible with any TAP consumer (`prove`, `tap-parser`, CI plugins). The plan line (`1..N`) is printed at the end by `th_summary`. Failure details are emitted as YAML blocks.

```
TAP version 13
# Base Tests
ok 1 - Connectivity # time=243ms
ok 2 - Basic query works # time=12ms
not ok 3 - Extension check
  ---
  message: "expected extension to be present"
  ...
1..3
```

### json

Buffers all results and emits a single JSON object when `th_summary` is called. Real-time output is suppressed; capture `$(th_summary)` to use the JSON programmatically.

```json
{
  "suite": "PostgreSQL E2E Tests",
  "version": "0.1.0",
  "timestamp": "2026-02-23T10:00:00Z",
  "duration_ms": 255,
  "counts": { "total": 3, "pass": 2, "fail": 1, "skip": 0 },
  "tests": [
    { "id": 1, "group": "Base Tests", "name": "Connectivity", "status": "pass", "duration_ms": 243 },
    { "id": 2, "group": "Base Tests", "name": "Basic query works", "status": "pass", "duration_ms": 12 },
    { "id": 3, "group": "Base Tests", "name": "Extension check", "status": "fail", "duration_ms": 8, "detail": "expected extension to be present" }
  ]
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed (or only skips, no failures) |
| 1 | One or more tests failed |

`th_summary` is the only function that returns a non-zero exit code. All assertions always return 0.

## Environment Variables

| Variable | Effect |
|----------|--------|
| `NO_COLOR=1` | Disable colors and symbols in table output (see [no-color.org](https://no-color.org/)) |
