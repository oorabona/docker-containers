#!/usr/bin/env bats

# Unit tests for scripts/open-dep-failure-issue.sh

load "../test_helper"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir

    export ORIG_PATH="$PATH"
    export ORIG_DIR="$PWD"

    # Minimal required env vars for the script to not abort on the : "${VAR:?}" checks
    export GH_TOKEN="fake-token"
    export GITHUB_REPOSITORY="oorabona/docker-containers"
    export GITHUB_RUN_ID="123456789"
    export GITHUB_SERVER_URL="https://github.com"
    export GITHUB_SHA="abc123def456"
    export GITHUB_EVENT_NAME="push"
    export GITHUB_REF_NAME="master"
    export COMMIT_SUBJECT="chore: update readme"

    # Optional vars — cleared so each test can set what it needs
    unset PR_NUMBER PR_TITLE PR_BODY PR_LABELS FAILED_JOBS_JSON
    export DRY_RUN="true"

    # Provide a mock gh that does nothing (prevents any real network call)
    mock_command "gh" 'echo "[]"'

    # Source helpers that the script needs
    source "$HELPERS_DIR/logging.sh"
    source "$HELPERS_DIR/retry.sh"

    # Source the script in function-only mode by setting BASH_SOURCE guard
    # We source it directly; top-level code is guarded by [[ "${BASH_SOURCE[0]}" == "${0}" ]]
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/open-dep-failure-issue.sh"
}

teardown() {
    teardown_temp_dir
    export PATH="$ORIG_PATH"
    cd "$ORIG_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# detect_dep_bump — commit subject patterns
# Note: detect_dep_bump sets globals DETECTED_CONTAINER / DETECTED_KIND.
# We call it directly (no `run`) so the globals propagate to the test shell.
# ---------------------------------------------------------------------------

@test "detect: deps(php) commit subject → container=php kind=deps" {
    export COMMIT_SUBJECT="deps(php): update 4 dependencies"
    export GITHUB_REF_NAME="master"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "php" ]
    [ "$DETECTED_KIND" = "deps" ]
}

@test "detect: build(postgres) commit subject → container=postgres kind=version-bump" {
    export COMMIT_SUBJECT="build(postgres): update to 18.2"
    export GITHUB_REF_NAME="master"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "postgres" ]
    [ "$DETECTED_KIND" = "version-bump" ]
}

@test "detect: irrelevant commit fix(ci) → exit 1 (no detection)" {
    export COMMIT_SUBJECT="fix(ci): something unrelated"
    export GITHUB_REF_NAME="master"

    # Must not detect — call via run so we can capture exit status
    run detect_dep_bump
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# detect_dep_bump — PR title patterns
# ---------------------------------------------------------------------------

@test "detect: 📦 deps(terraform) PR title, no commit match → container=terraform kind=deps" {
    export COMMIT_SUBJECT="chore: something else"
    export PR_TITLE="📦 deps(terraform): update 1 dependencies"
    export GITHUB_REF_NAME="master"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "terraform" ]
    [ "$DETECTED_KIND" = "deps" ]
}

@test "detect: 🚀 Minor: openresty to 1.29.2.5-alpine → container=openresty kind=version-bump" {
    export COMMIT_SUBJECT="chore: something else"
    export PR_TITLE="🚀 Minor: openresty to 1.29.2.5-alpine"
    export GITHUB_REF_NAME="master"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "openresty" ]
    [ "$DETECTED_KIND" = "version-bump" ]
}

@test "detect: ⚠️ deps(ansible) PR title → container=ansible kind=deps" {
    export COMMIT_SUBJECT="chore: something else"
    export PR_TITLE="⚠️ deps(ansible): update 2 dependencies"
    export GITHUB_REF_NAME="master"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "ansible" ]
    [ "$DETECTED_KIND" = "deps" ]
}

@test "detect: 🔄 Major: vector to 2.0.0 PR title → container=vector kind=version-bump" {
    export COMMIT_SUBJECT="chore: something else"
    export PR_TITLE="🔄 Major: vector to 2.0.0"
    export GITHUB_REF_NAME="master"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "vector" ]
    [ "$DETECTED_KIND" = "version-bump" ]
}

# ---------------------------------------------------------------------------
# detect_dep_bump — branch ref fallback
# ---------------------------------------------------------------------------

@test "detect: branch update/wordpress-deps only → container=wordpress kind=deps" {
    export COMMIT_SUBJECT="chore: unrelated"
    export GITHUB_REF_NAME="update/wordpress-deps"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "wordpress" ]
    [ "$DETECTED_KIND" = "deps" ]
}

@test "detect: branch update/jekyll-4.3.4 only → container=jekyll kind=version-bump" {
    export COMMIT_SUBJECT="chore: unrelated"
    export GITHUB_REF_NAME="update/jekyll-4.3.4"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "jekyll" ]
    [ "$DETECTED_KIND" = "version-bump" ]
}

# ---------------------------------------------------------------------------
# detect_dep_bump — priority: commit/title wins over branch
# ---------------------------------------------------------------------------

@test "detect: commit says php, branch says postgres → commit wins (php)" {
    export COMMIT_SUBJECT="deps(php): update 3 dependencies"
    export GITHUB_REF_NAME="update/postgres-deps"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "php" ]
}

@test "detect: PR title says openresty, branch says ansible → title wins (openresty)" {
    export COMMIT_SUBJECT="chore: unrelated"
    export PR_TITLE="📦 deps(openresty): update 1 dependencies"
    export GITHUB_REF_NAME="update/ansible-deps"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "openresty" ]
}

# ---------------------------------------------------------------------------
# detect_dep_bump — PR labels fallback
# ---------------------------------------------------------------------------

@test "detect: automation+dependencies labels → kind=deps" {
    export COMMIT_SUBJECT="chore: unrelated"
    export GITHUB_REF_NAME="master"
    export PR_LABELS="automation,dependencies,sslh,minor-update"

    detect_dep_bump
    [ "$DETECTED_CONTAINER" = "sslh" ]
    [ "$DETECTED_KIND" = "deps" ]
}

# ---------------------------------------------------------------------------
# extract_dep_details — version-bump kind
# ---------------------------------------------------------------------------

@test "extract: version-bump with PR title containing version → new version captured" {
    export PR_TITLE="🚀 Minor: openresty to 1.29.2.5-alpine"
    export COMMIT_SUBJECT="build(openresty): update to 1.29.2.5-alpine"

    run extract_dep_details "openresty" "version-bump"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"new":"1.29.2.5-alpine"'* ]]
    [[ "$output" == *'"name":"openresty"'* ]]
}

@test "extract: version-bump without version in title → new=?" {
    export PR_TITLE=""
    export COMMIT_SUBJECT="build(postgres): update things"

    run extract_dep_details "postgres" "version-bump"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"new":"?"'* ]]
}

# ---------------------------------------------------------------------------
# extract_dep_details — deps kind with PR body table
# ---------------------------------------------------------------------------

@test "extract: deps kind parses 3-row pr_table from PR_BODY" {
    export PR_BODY="| Dependency | Old | New |
|---|---|---|
| FOO | 1.0 | 1.1 |
| BAR | 2.3.0 | 2.4.0 |
| BAZ | 0.9 | 1.0 |"

    run extract_dep_details "php" "deps"
    [ "$status" -eq 0 ]

    # Should have 3 entries
    local count
    count=$(echo "$output" | grep -o '"name"' | wc -l)
    [ "$count" -eq 3 ]

    [[ "$output" == *'"name":"FOO"'* ]]
    [[ "$output" == *'"old":"1.0"'* ]]
    [[ "$output" == *'"new":"1.1"'* ]]
    [[ "$output" == *'"name":"BAR"'* ]]
    [[ "$output" == *'"name":"BAZ"'* ]]
}

@test "extract: deps kind with 4-column table (Severity) — parses 3 deps" {
    export PR_BODY="| Dependency | Old | New | Severity |
|---|---|---|---|
| ALPHA | 3.0 | 3.1 | minor |
| BETA | 1.0 | 2.0 | major |
| GAMMA | 5.5 | 5.6 | patch |"

    run extract_dep_details "terraform" "deps"
    [ "$status" -eq 0 ]

    local count
    count=$(echo "$output" | grep -o '"name"' | wc -l)
    [ "$count" -eq 3 ]
}

@test "extract: fallback when PR_BODY empty → (unknown) placeholder" {
    export PR_BODY=""

    run extract_dep_details "php" "deps"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"(unknown)"'* ]]
    [[ "$output" == *'"note":"PR body not available"'* ]]
}

@test "extract: fallback when PR_BODY has no parseable table" {
    export PR_BODY="Just a description with no table here."

    run extract_dep_details "php" "deps"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"name":"(unknown)"'* ]]
}

# ---------------------------------------------------------------------------
# build_deps_table
# ---------------------------------------------------------------------------

@test "build_deps_table: renders markdown table from single-dep JSON" {
    run build_deps_table '[{"name":"FOO","old":"1.0","new":"1.1"}]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"| FOO | 1.0 | 1.1 |"* ]]
    [[ "$output" == *"| Dependency | Old | New |"* ]]
}

@test "build_deps_table: renders note column when present" {
    run build_deps_table '[{"name":"(unknown)","old":"?","new":"?","note":"PR body not available"}]'
    [ "$status" -eq 0 ]
    [[ "$output" == *"PR body not available"* ]]
}

# ---------------------------------------------------------------------------
# DRY_RUN end-to-end
# ---------------------------------------------------------------------------

@test "DRY_RUN: prints title+body to stdout, no real gh invocation" {
    # Replace gh mock with a strict one that fails if called with issue create
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" << 'GHEOF'
#!/bin/bash
if [[ "$*" == *"issue create"* ]] || [[ "$*" == *"issue comment"* ]]; then
    echo "ERROR: gh should not be called in DRY_RUN mode" >&2
    exit 99
fi
# issue list returns empty
echo "[]"
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    export COMMIT_SUBJECT="deps(php): update 4 dependencies"
    export PR_NUMBER="999"
    export PR_TITLE="📦 deps(php): update 4 dependencies"
    export PR_BODY="| Dependency | Old | New |
|---|---|---|
| FOO | 1.0 | 1.1 |"
    export PR_LABELS="automation,dependencies,php,minor-update"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 0 ]

    # Must contain the expected issue title marker
    [[ "$output" == *"🚨 [php]"* ]]
    # Must contain dep data from PR_BODY
    [[ "$output" == *"FOO"* ]]
    [[ "$output" == *"1.0"* ]]
    [[ "$output" == *"1.1"* ]]
}

@test "DRY_RUN: version-bump prints container and new version" {
    export COMMIT_SUBJECT="build(postgres): update to 18.2"
    export PR_TITLE="🚀 Minor: postgres to 18.2"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"🚨 [postgres]"* ]]
    [[ "$output" == *"18.2"* ]]
}

@test "DRY_RUN: no-match exits 1 (caller uses generic issue logic)" {
    export COMMIT_SUBJECT="fix(ci): corrected shellcheck warning"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Dedup: mock gh issue list returns existing issue → "commented"
# ---------------------------------------------------------------------------

@test "dedup: existing open issue found → result contains 'commented'" {
    # Override gh mock: issue list returns one match; issue comment succeeds
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" << 'GHEOF'
#!/bin/bash
case "$*" in
    *"issue list"*)
        cat <<JSON
[{"number":999,"title":"🚨 [php] Build failed after dep update (PR #100)","body":"Refs #100"}]
JSON
        ;;
    *"issue comment"*)
        echo "https://github.com/oorabona/docker-containers/issues/999#issuecomment-1"
        ;;
    *"label create"*)
        echo "label created" >&2
        ;;
    *)
        echo "unexpected gh args: $*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    export COMMIT_SUBJECT="deps(php): update 4 dependencies"
    export PR_NUMBER="100"
    export PR_TITLE="📦 deps(php): update 4 dependencies"
    export PR_BODY="| Dependency | Old | New |
|---|---|---|
| FOO | 1.0 | 1.1 |"
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"commented"* ]]
    [[ "$output" == *"#999"* ]]
}

# ---------------------------------------------------------------------------
# open_version_drift_issue — drift table rendering
# Guards the "jq .[] over row strings" regression: the buggy program applied
# | .[] to the whole comma-separated output stream (header array + row strings),
# causing jq to error on strings and fall back to "unable to render drift table".
# ---------------------------------------------------------------------------

@test "drift table: renders drift rows and omits in_sync rows" {
    # One drift row + one in_sync row. Only the drift row must appear in the table.
    local drift_json='[
        {"status":"drift","kind":"extension","name":"pgvector","declared":"0.8.0","published":"0.7.4"},
        {"status":"in_sync","kind":"extension","name":"timescaledb","declared":"2.17.2","published":"2.17.2"}
    ]'
    export DRY_RUN="true"

    run open_version_drift_issue "$drift_json" "postgres"
    [ "$status" -eq 0 ]

    # Must contain the rendered drift row
    [[ "$output" == *"| pgvector |"* ]]
    # Must contain the table header (proves the header | .[] scoping is also correct)
    [[ "$output" == *"| Kind | Name | Declared | Published | Status |"* ]]
    # Must NOT fall back to the error sentinel (guards the jq regression)
    [[ "$output" != *"unable to render drift table"* ]]
    # in_sync row must NOT appear (guards the select(.status=="drift") filter)
    [[ "$output" != *"| timescaledb |"* ]]
}

# ---------------------------------------------------------------------------
# Dedup: mock gh issue list returns empty → "created"
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# recovery mode: --mode recovery
# ---------------------------------------------------------------------------

@test "recovery: open 'Auto Build Failed' issue found → gh issue close called" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    # Track calls via a log file so we can assert what was called
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        echo '[{"number":42,"title":"Auto Build Failed - 2026-06-01"}]'
        ;;
    *"issue comment"*)
        echo "comment posted" >&2
        ;;
    *"issue close"*)
        echo "issue closed" >&2
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export call_log
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    [ "$status" -eq 0 ]

    # gh issue close must have been called with the issue number
    grep -q "issue close" "$call_log"
    grep -q "42" "$call_log"
    # gh issue comment must have been called first (recovery comment)
    grep -q "issue comment" "$call_log"
}

@test "recovery: no open issue → exit 0, gh issue close NOT called" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        echo "[]"
        ;;
    *"issue close"*)
        echo "ERROR: close should not be called when no issue open" >&2
        exit 99
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export call_log
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    [ "$status" -eq 0 ]

    # gh issue close must NOT have been called
    if [ -f "$call_log" ]; then
        run grep "issue close" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

@test "recovery: non-matching title ('Build Warning') → not closed" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        # Title does NOT contain "Auto Build Failed"
        echo '[{"number":7,"title":"Build Warning - some other issue"}]'
        ;;
    *"issue close"*)
        echo "ERROR: should not close a non-matching issue" >&2
        exit 99
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export call_log
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    [ "$status" -eq 0 ]

    # gh issue close must NOT have been called (title didn't match)
    if [ -f "$call_log" ]; then
        run grep "issue close" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

# ---------------------------------------------------------------------------
# Dedup: mock gh issue list returns empty → "created"
# ---------------------------------------------------------------------------

@test "dedup: no existing issue → result contains 'created'" {
    # Override gh mock: issue list returns empty; issue create returns URL
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" << 'GHEOF'
#!/bin/bash
case "$*" in
    *"issue list"*)
        echo "[]"
        ;;
    *"issue create"*)
        echo "https://github.com/oorabona/docker-containers/issues/42"
        ;;
    *"label create"*)
        echo "label created" >&2
        ;;
    *)
        echo "unexpected gh args: $*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    export COMMIT_SUBJECT="deps(php): update 4 dependencies"
    export PR_NUMBER="200"
    export PR_TITLE="📦 deps(php): update 4 dependencies"
    export PR_BODY="| Dependency | Old | New |
|---|---|---|
| LIBSSL | 1.1.1w | 3.5.6 |"
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"created"* ]]
    [[ "$output" == *"#42"* ]]
}

# ---------------------------------------------------------------------------
# Finding 2: find_open_generic_build_failure_issue must require BOTH labels
# ---------------------------------------------------------------------------

@test "recovery: issue with build-failure but WITHOUT automation label is NOT closed" {
    # The mock returns an issue that only has the build-failure label
    # (no automation label).  The query now requires --label automation so
    # gh issue list returns [] (the mock below models the label-AND behaviour).
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        # Simulates gh returning no results when automation label is required
        # but absent on the candidate issue.
        echo "[]"
        ;;
    *"issue close"*)
        echo "ERROR: must not close an issue without automation label" >&2
        exit 99
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export call_log
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    [ "$status" -eq 0 ]

    # Verify that gh issue list was called with the automation label
    grep -q "\-\-label.*automation\|automation.*\-\-label" "$call_log"

    # gh issue close must NOT have been called
    if [ -f "$call_log" ]; then
        run grep "issue close" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

# ---------------------------------------------------------------------------
# Finding 3: recovery mode is best-effort — gh errors must not propagate
# ---------------------------------------------------------------------------

@test "recovery: gh issue comment failure → exit 0 (best-effort, non-critical)" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
case "\$*" in
    *"issue list"*)
        echo '[{"number":55,"title":"Auto Build Failed - 2026-06-01"}]'
        ;;
    *"issue comment"*)
        # Simulate a transient API failure
        echo "gh: error: HTTP 503 Service Unavailable" >&2
        exit 1
        ;;
    *"issue close"*)
        echo "ERROR: close should not be called after comment failure" >&2
        exit 99
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    # Must exit 0 regardless of gh failure — recovery is non-critical
    [ "$status" -eq 0 ]
}

@test "recovery: gh issue list failure → exit 0, not aborted by set -e (Finding 3)" {
    # find_open_generic_build_failure_issue returns 1 when gh issue list fails.
    # Under set -e the bare subshell assignment would abort before the best-effort
    # warning path.  The fix (|| true) must keep recovery at exit 0.
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        echo "gh: error: HTTP 503 Service Unavailable" >&2
        exit 1
        ;;
    *"issue close"*)
        echo "ERROR: close must not be called when list failed" >&2
        exit 99
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export call_log
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    # Must exit 0 — set -e must not abort on find_open_generic_build_failure_issue
    [ "$status" -eq 0 ]

    # gh issue close must NOT have been called
    if [ -f "$call_log" ]; then
        run grep "issue close" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

@test "recovery: gh issue close failure → exit 0 (best-effort, non-critical)" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
case "\$*" in
    *"issue list"*)
        echo '[{"number":55,"title":"Auto Build Failed - 2026-06-01"}]'
        ;;
    *"issue comment"*)
        echo "comment posted" >&2
        ;;
    *"issue close"*)
        # Simulate a transient API failure on close
        echo "gh: error: HTTP 503 Service Unavailable" >&2
        exit 1
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    # Must exit 0 regardless of gh failure — recovery is non-critical
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Finding 1: DRY_RUN master build must NOT trigger recovery close
#
# These tests exercise the summary job's build_succeeded / build_failed signal
# computation in isolation.  The logic is mirrored verbatim from the YAML
# summary step's Step A block and run in a subshell.
#
# Fidelity requirement: both signals are written to $GITHUB_OUTPUT (an
# append-only file), not echoed to stdout.  The helper sets up a real temp
# file for GITHUB_OUTPUT and cats it to stdout after the subshell, so bats
# captures the actual emitted lines in $output.  This matches production:
# GitHub Actions reads the file, not stdout.
# ---------------------------------------------------------------------------

# Helper: runs the summary job's signal-computation logic with given inputs.
# Writes build_failed=... and build_succeeded=... to a temp GITHUB_OUTPUT file,
# then cats that file to stdout so bats $output contains the real emitted lines.
# Args: dry_run_flag container_count detect_result bap_result bex_result mem_result cm_result
_run_build_succeeded_logic() {
    local dry_run_flag="$1"
    local container_count="$2"
    local detect_result="${3:-success}"
    local bap_result="${4:-success}"
    local bex_result="${5:-skipped}"
    local mem_result="${6:-skipped}"
    local cm_result="${7:-success}"

    local output_file
    output_file="$(mktemp)"

    bash <<LOGIC
set -euo pipefail
GITHUB_OUTPUT="${output_file}"
dry_run_flag="${dry_run_flag}"
container_count="${container_count}"
detect_result="${detect_result}"
bap_result="${bap_result}"
bex_result="${bex_result}"
mem_result="${mem_result}"
cm_result="${cm_result}"

# build_failed: any monitored pipeline job failed or cancelled.
build_failed=false
for _r in "\$detect_result" "\$bap_result" "\$bex_result" "\$mem_result" "\$cm_result"; do
  if [ "\$_r" = "failure" ] || [ "\$_r" = "cancelled" ]; then
    build_failed=true
  fi
done

# container_count must be a non-negative integer.
count_valid=true
[[ "\$container_count" =~ ^[0-9]+\$ ]] || count_valid=false

# build_succeeded: a REAL successful build was published.
build_succeeded=false
if [ "\$build_failed" = "false" ] && [ "\$count_valid" = "true" ] \
   && [ "\$container_count" -gt 0 ] && [ "\$bap_result" = "success" ] \
   && [ "\$dry_run_flag" != "true" ]; then
  build_succeeded=true
fi

# Emit BOTH signals unconditionally to GITHUB_OUTPUT.
{
  echo "build_failed=\${build_failed}"
  echo "build_succeeded=\${build_succeeded}"
} >> "\$GITHUB_OUTPUT"
LOGIC

    # Cat the real GITHUB_OUTPUT content to stdout so bats captures it.
    cat "${output_file}"
    rm -f "${output_file}"
}

@test "summary logic: DRY_RUN=true with bap_result=success → build_succeeded=false (no recovery)" {
    # A dry-run workflow_dispatch on master: build-and-push reports success but
    # nothing was actually published.  build_succeeded must stay false so the
    # recovery step is never triggered.
    run _run_build_succeeded_logic "true" "3" "success" "success" "skipped" "skipped" "success"
    [ "$status" -eq 0 ]
    # Verify the real GITHUB_OUTPUT content (not a local echo).
    [[ "$output" == *"build_succeeded=false"* ]]
    [[ "$output" == *"build_failed=false"* ]]
}

@test "summary logic: DRY_RUN=false with bap_result=success → build_succeeded=true (real recovery)" {
    # A genuine successful master build (not dry-run) must produce build_succeeded=true.
    run _run_build_succeeded_logic "false" "3" "success" "success" "skipped" "skipped" "success"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build_succeeded=true"* ]]
    [[ "$output" == *"build_failed=false"* ]]
}

@test "summary logic: detect-containers failure → build_failed=true AND build_succeeded=false both in GITHUB_OUTPUT" {
    # When detect-containers fails, downstream build jobs are skipped and
    # container_count is empty.  build_failed must be true (issue-open path
    # reachable) AND must be PRESENT in GITHUB_OUTPUT — the previous tangled
    # if/elif only emitted build_succeeded=false in this branch, silently
    # dropping the build_failed signal.
    run _run_build_succeeded_logic "false" "" "failure" "skipped" "skipped" "skipped" "skipped"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build_failed=true"* ]]
    [[ "$output" == *"build_succeeded=false"* ]]
}

@test "summary logic: detect-containers cancelled → build_failed=true AND build_succeeded=false both in GITHUB_OUTPUT" {
    run _run_build_succeeded_logic "false" "" "cancelled" "skipped" "skipped" "skipped" "skipped"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build_failed=true"* ]]
    [[ "$output" == *"build_succeeded=false"* ]]
}

@test "summary logic: count=0 → build_failed=false, build_succeeded=false (no issue, no recovery)" {
    # count=0 means no containers needed building — not a failure, not a success.
    run _run_build_succeeded_logic "false" "0" "success" "skipped" "skipped" "skipped" "skipped"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build_failed=false"* ]]
    [[ "$output" == *"build_succeeded=false"* ]]
}

@test "summary logic: empty container_count (detect skipped output) → build_succeeded=false in GITHUB_OUTPUT" {
    # An empty container_count (detect-containers output not set) must not reach
    # the [ -gt 0 ] arithmetic and must not produce build_succeeded=true.
    run _run_build_succeeded_logic "false" "" "success" "success" "skipped" "skipped" "success"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build_succeeded=false"* ]]
}

@test "summary logic: non-numeric container_count (e.g. 'abc') → build_succeeded=false in GITHUB_OUTPUT" {
    run _run_build_succeeded_logic "false" "abc" "success" "success" "skipped" "skipped" "success"
    [ "$status" -eq 0 ]
    [[ "$output" == *"build_succeeded=false"* ]]
}

# ---------------------------------------------------------------------------
# Recovery: event transparency
#
# The YAML recovery step if: uses event_name != 'pull_request' so that
# workflow_call (upstream-monitor) and workflow_dispatch master builds reach
# the script, not only direct push events.  The script itself does not
# inspect GITHUB_EVENT_NAME in recovery mode — that filtering belongs to the
# YAML gate.  The tests below document script-level event transparency.
# ---------------------------------------------------------------------------

@test "recovery: DRY_RUN mode with workflow_call event → exits 0 (script is event-transparent)" {
    # workflow_call master builds (upstream-monitor) now reach the recovery
    # step via the event_name != 'pull_request' gate.  The script must handle
    # any event value without error.
    export GITHUB_EVENT_NAME="workflow_call"
    export GITHUB_REF_NAME="master"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    [ "$status" -eq 0 ]
}

@test "recovery: pull_request event → script exits 0 (YAML gate prevents invocation)" {
    # On pull_request the YAML if: excludes the recovery step entirely.
    # If somehow invoked in that context, the script must still exit 0 —
    # recovery is best-effort and wrong-caller is not a script-level error.
    export GITHUB_EVENT_NAME="pull_request"
    export GITHUB_REF_NAME="refs/pull/99/merge"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery
    [ "$status" -eq 0 ]
}
