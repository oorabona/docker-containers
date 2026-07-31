#!/usr/bin/env bats
#
# The command probes exist because a suite that captures output and asserts only
# on its text passes when the producer printed something plausible and then
# failed. The status is not hidden by `value=$(cmd)` — it is in `$?` — but these
# suites run without `errexit` and never read it. These tests pin that the probes
# close that gap, and that they do not reopen it elsewhere.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/test-harness/test-harness.sh"
    th_init --name "probe tests" --report table --no-color >/dev/null
}

# A producer that prints exactly what the assertion looks for, then fails.
plausible_but_failing() {
    echo "ruby 3.3.0"
    return 42
}

succeeding() {
    echo "ruby 3.3.0"
}

stderr_banner() {
    # Shaped like a real banner: a reviewer reading this stub should not come away
    # with a false picture of what the binary prints.
    echo "sslh-ev 2.3.1" >&2
}

secret_bearing() {
    return 7
}

@test "th_assert_cmd_contains fails when the command prints the needle and then fails" {
    run th_assert_cmd_contains "ruby reports its version" "ruby" plausible_but_failing
    [ "$status" -eq 0 ]                       # assertions never abort the script
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"exited 42"* ]]
}

@test "th_assert_cmd_contains passes when the command succeeds and matches" {
    run th_assert_cmd_contains "ruby reports its version" "ruby" succeeding
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" != *"FAIL"* ]]
}

@test "th_assert_cmd_contains fails when the command succeeds but does not match" {
    run th_assert_cmd_contains "ruby reports its version" "python" succeeding
    # Still returns 0: an assertion must never abort a suite under `set -e`.
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAIL"* ]]
}

@test "th_init clears TH_OUTPUT so a new suite cannot assert on the old one's output" {
    th_capture "first suite" succeeding
    [ -n "$TH_OUTPUT" ]
    th_init --name "second suite" --report table --no-color >/dev/null
    [ -z "$TH_OUTPUT" ]
}

@test "th_capture returns non-zero on failure so a chained assertion cannot run" {
    run bash -c "
        source '$PROJECT_ROOT/test-harness/test-harness.sh'
        th_init --report table --no-color >/dev/null
        $(declare -f plausible_but_failing)
        th_capture 'version is readable' plausible_but_failing &&
            th_assert_contains 'version is readable' \"\$TH_OUTPUT\" 'ruby'
        th_summary
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"exited 42"* ]]
    # exactly one result: the chained assertion must not have run
    [ "$(grep -c -E 'PASS|FAIL' <<< "$output")" -eq 1 ]
}

@test "th_capture empties TH_OUTPUT on failure" {
    TH_OUTPUT="stale"
    th_capture "version is readable" plausible_but_failing || true
    [ -z "$TH_OUTPUT" ]
}

@test "th_capture discards stderr, so a diagnostic cannot satisfy an assertion" {
    # An error message that happens to carry the needle must not be able to pass
    # a `contains` assertion, so no probe merges the two streams.
    #
    # Asserting only that $TH_OUTPUT excludes stderr would prove nothing: command
    # substitution captures stdout alone whether or not the harness redirects
    # stderr. What the redirect actually does is swallow the command's stderr, so
    # that is what this pins — the probe itself must emit none.
    local probe_stderr="$BATS_TEST_TMPDIR/probe-stderr"
    th_capture "a banner written to stderr" stderr_banner 2>"$probe_stderr"
    [ -z "$TH_OUTPUT" ]
    [ ! -s "$probe_stderr" ]
}

@test "th_capture with no command fails instead of passing on an empty substitution" {
    # An empty "$@" is a successful empty command substitution, so without an
    # explicit check a caller that dropped its command would silently pass.
    run th_capture "a command that was never given"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"no command"* ]]
}

@test "failure details name the command but never its arguments" {
    # Results reach the table, the TAP stream and the JSON report, all of which
    # land in CI logs; an argument list can carry a credential or a token.
    run th_assert_cmd_contains "probe" "x" secret_bearing --user hunter2 --token s3cr3t
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"secret_bearing"* ]]
    [[ "$output" != *"hunter2"* ]]
    [[ "$output" != *"s3cr3t"* ]]
}

@test "the JSON report does not carry command arguments either" {
    run bash -c "
        source '$PROJECT_ROOT/test-harness/test-harness.sh'
        th_init --report json --no-color >/dev/null
        $(declare -f secret_bearing)
        th_assert_cmd_contains 'probe' 'x' secret_bearing --token s3cr3t
        th_summary
    "
    # Assert the report is real before asserting what it lacks — an empty or
    # malformed report would satisfy the absence check vacuously.
    echo "$output" | jq -e '.tests | length == 1' >/dev/null
    echo "$output" | jq -e '.tests[0].status == "fail"' >/dev/null
    [[ "$output" != *"s3cr3t"* ]]
}

@test "numeric assertions accept plain integers" {
    run th_assert_ge "four is at least three" "4" "3"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]

    run th_assert_gt "four is greater than three" "4" "3"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "numeric assertions preserve negative and zero comparisons" {
    run th_assert_ge "negative equality" "-2" "-2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]

    run th_assert_gt "zero is greater than negative one" "0" "-1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "numeric assertions trim surrounding whitespace" {
    run th_assert_ge "whitespace is ignored" $' \t 4 \n' $' 3 '
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "numeric assertions fail for non-decimal operands" {
    run th_assert_ge "invalid actual" "not-a-number" "3"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"received actual: 'not-a-number'"* ]]
    [[ "$output" != *"PASS"* ]]
    [[ "$output" != *"SKIP"* ]]

    run th_assert_gt "invalid minimum" "3" "not-a-number"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"minimum: 'not-a-number'"* ]]
}

@test "numeric assertions do not evaluate arithmetic-looking operands" {
    local pwned_file="/tmp/pwned"
    local malicious='x[$(touch /tmp/pwned)0]'

    if [[ -e "$pwned_file" ]]; then
        skip "$pwned_file already exists"
    fi

    run th_assert_ge "malicious operand" "$malicious" "0"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAIL"* ]]
    [ ! -e "$pwned_file" ]

    run th_assert_gt "malicious operand" "$malicious" "0"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAIL"* ]]
    [ ! -e "$pwned_file" ]
}
