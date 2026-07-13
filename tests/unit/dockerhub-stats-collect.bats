#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    TEST_REPO="$TEST_TEMP_DIR/repo"
    FAKE_STATE="$TEST_TEMP_DIR/state"
    mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/stats" "$TEST_REPO/bin" "$FAKE_STATE"

    ln -s "$SCRIPTS_DIR/collect-stats-snapshot.sh" "$TEST_REPO/scripts/collect-stats-snapshot.sh"

    cat > "$TEST_REPO/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${FAKE_STATE:?}/sleep.log"
EOF
    chmod +x "$TEST_REPO/bin/sleep"

    export FAKE_STATE
    export PATH="$TEST_REPO/bin:$PATH"
    export GITHUB_ACTIONS="true"
    export GITHUB_OUTPUT="$FAKE_STATE/github_output"
    : > "$GITHUB_OUTPUT"
}

teardown() {
    teardown_temp_dir
}

get_output() {
    local key="$1"
    grep "^${key}=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "collect-stats-snapshot refuses to run outside GitHub Actions" {
    unset GITHUB_ACTIONS

    run bash -c 'cd "$1" && ./scripts/collect-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::scripts/collect-stats-snapshot.sh is CI-only"* ]]
}

@test "collect-stats-snapshot stops early on a fully successful first attempt" {
    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "call" >> "${FAKE_STATE:?}/calls.log"
exit 0
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    run bash -c 'cd "$1" && ./scripts/collect-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    calls=$(wc -l < "$FAKE_STATE/calls.log")
    [ "$calls" -eq 1 ]

    [ "$(get_output still_missing)" = "false" ]
    [[ "$output" != *"still missing"* ]]
}

@test "collect-stats-snapshot recovers on a later attempt and stops early" {
    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "call" >> "${FAKE_STATE:?}/calls.log"
calls=$(wc -l < "${FAKE_STATE:?}/calls.log")
if [[ "$calls" -eq 1 ]]; then
  exit 1
fi
exit 0
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    run bash -c 'cd "$1" && ./scripts/collect-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 1"* ]]

    calls=$(wc -l < "$FAKE_STATE/calls.log")
    [ "$calls" -eq 2 ]

    [ "$(get_output still_missing)" = "false" ]
}

@test "collect-stats-snapshot exhausts all 3 attempts and reports still_missing when nothing ever fully succeeds" {
    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "call" >> "${FAKE_STATE:?}/calls.log"
exit 1
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    run bash -c 'cd "$1" && ./scripts/collect-stats-snapshot.sh' _ "$TEST_REPO"
    # Non-blocking by design — the calling workflow's own final check step
    # decides pass/fail from still_missing, not this script's own exit code.
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 1"* ]]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 2"* ]]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 3"* ]]
    [[ "$output" == *"::warning::Stats snapshot collection ended with some containers still missing after 3 attempts"* ]]

    calls=$(wc -l < "$FAKE_STATE/calls.log")
    [ "$calls" -eq 3 ]

    [ "$(get_output still_missing)" = "true" ]
}

@test "collect-stats-snapshot pins SNAPSHOT_DATE_OVERRIDE once and holds it across all retry attempts" {
    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "${SNAPSHOT_DATE_OVERRIDE:-UNSET}" >> "${FAKE_STATE:?}/date-override.log"
exit 1
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    run bash -c 'cd "$1" && ./scripts/collect-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    seen_dates=$(sort -u "$FAKE_STATE/date-override.log")
    line_count=$(wc -l < "$FAKE_STATE/date-override.log")
    [ "$line_count" -eq 3 ]
    [ "$(printf '%s\n' "$seen_dates" | wc -l)" -eq 1 ]
    [ "$seen_dates" != "UNSET" ]
    [[ "$seen_dates" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "collect-stats-snapshot contains no git or token logic at all" {
    # Regression lock: the real guarantee that collection can't misuse push
    # credentials isn't anything this script does at runtime — it's that
    # this script structurally has no git/token code path to misuse, AND
    # (verified separately in dockerhub-stats-workflow.bats) the calling
    # workflow doesn't mint the App token or import the GPG key until AFTER
    # this step has already run. Comment lines are excluded — they're
    # explanatory prose about the absence of git/token logic, not code.
    non_comment_lines="$(grep -v '^\s*#' "$SCRIPTS_DIR/collect-stats-snapshot.sh")"
    [[ "$non_comment_lines" != *'git '* ]]
    [[ "$non_comment_lines" != *'TOKEN'* ]]
}
