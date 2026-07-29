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
    [[ "$output" == *"PASS"* ]]
    [[ "$output" != *"FAIL"* ]]
}

@test "th_assert_cmd_contains fails when the command succeeds but does not match" {
    run th_assert_cmd_contains "ruby reports its version" "python" succeeding
    [[ "$output" == *"FAIL"* ]]
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
    [[ "$output" != *"s3cr3t"* ]]
}
