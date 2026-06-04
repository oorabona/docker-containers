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
# Static label ensure: create path must call gh label create for dep-attributed
# BEFORE gh issue create, so a repo missing the static label never causes a
# "could not add label: 'dep-attributed' not found" failure on issue create.
# ---------------------------------------------------------------------------

@test "create path: gh label create dep-attributed called before gh issue create" {
    # Mock records every gh invocation to a call log so we can assert ordering.
    # gh issue create only succeeds AFTER seeing a prior label create dep-attributed.
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        echo "[]"
        ;;
    *"label create"*)
        # All label creates succeed (best-effort idempotent)
        exit 0
        ;;
    *"issue create"*)
        # Verify that dep-attributed label was created before reaching issue create.
        if ! grep -q "label create dep-attributed" "$call_log" 2>/dev/null; then
            echo "ERROR: gh label create dep-attributed was never called before gh issue create" >&2
            exit 1
        fi
        echo "https://github.com/oorabona/docker-containers/issues/77"
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    # Mock sleep to skip retry_with_backoff waits
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TEMP_DIR/bin/sleep"
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    export COMMIT_SUBJECT="deps(php): update 4 dependencies"
    export PR_NUMBER="300"
    export PR_TITLE="📦 deps(php): update 4 dependencies"
    export PR_BODY="| Dependency | Old | New |
|---|---|---|
| LIBSSL | 1.1.1w | 3.5.6 |"
    export DRY_RUN="false"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"created"* ]]
    [[ "$output" == *"#77"* ]]

    # Assert gh label create was called for dep-attributed
    grep -q "label create dep-attributed" "$call_log"

    # Assert gh label create was called before gh issue create (ordering)
    local label_line issue_line
    label_line=$(grep -n "label create dep-attributed" "$call_log" | head -1 | cut -d: -f1)
    issue_line=$(grep -n "issue create" "$call_log" | head -1 | cut -d: -f1)
    [ -n "$label_line" ]
    [ -n "$issue_line" ]
    [ "$label_line" -lt "$issue_line" ]
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
# FINDING-1 — content_stale rows must be counted and rendered by
# open_version_drift_issue (not silently dropped as a no-op).
#
# A run that produces ONLY content_stale rows must open/refresh an issue.
# Before the fix the count used select(.status=="drift") exclusively, so a
# content_stale-only JSON was counted as 0 drift rows and the function
# returned early without creating an issue.
# ---------------------------------------------------------------------------

@test "FINDING-1: content_stale-only drift_json → issue created (not a no-op)" {
    # drift_json has exactly one content_stale row and no drift rows.
    local drift_json='[
        {"status":"content_stale","kind":"container","name":"jekyll","declared":"4.3.4","published":"4.3.4"}
    ]'
    export DRY_RUN="true"

    run open_version_drift_issue "$drift_json" "jekyll"
    [ "$status" -eq 0 ]

    # Must print dry-run output (not silent exit as if no drift)
    [[ "$output" == *"DRY_RUN"* || "$output" == *"dry-run"* ]]

    # Must render the content_stale row in the table
    [[ "$output" == *"| jekyll |"* ]]

    # The status column must show content_stale (distinguishable from drift)
    [[ "$output" == *"content_stale"* ]]

    # Must NOT fall back to the error sentinel
    [[ "$output" != *"unable to render drift table"* ]]
}

@test "FINDING-1: mixed drift+content_stale → both rows rendered, count = 2" {
    # drift_json has one drift row and one content_stale row.
    local drift_json='[
        {"status":"drift","kind":"container","name":"foo","declared":"1.0.0","published":""},
        {"status":"content_stale","kind":"container","name":"bar","declared":"2.0.0","published":"2.0.0"}
    ]'
    export DRY_RUN="true"

    run open_version_drift_issue "$drift_json" ""
    [ "$status" -eq 0 ]

    # Both rows must appear in the table
    [[ "$output" == *"| foo |"* ]]
    [[ "$output" == *"| bar |"* ]]

    # The status values must both be visible
    [[ "$output" == *"drift"* ]]
    [[ "$output" == *"content_stale"* ]]

    # in_sync must not appear
    [[ "$output" != *"in_sync"* ]]
}

@test "FINDING-1: in_sync-only drift_json → still a no-op (content_stale fix must not break this)" {
    # An all-in_sync JSON must remain a no-op — the fix must not break that path.
    local drift_json='[
        {"status":"in_sync","kind":"container","name":"foo","declared":"1.0.0","published":"1.0.0"}
    ]'
    export DRY_RUN="true"

    run open_version_drift_issue "$drift_json" "foo"
    [ "$status" -eq 0 ]

    # No dry-run output (no issue to open)
    [[ "$output" != *"DRY_RUN"* && "$output" != *"dry-run"* && "$output" != *"Issue"* ]]
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

# ---------------------------------------------------------------------------
# Proof A — container-scoped open: --mode failure --container <c>
#
# With --container set, the script opens/comments the dep:<c> issue WITHOUT
# relying on commit/PR/branch auto-detection.  Even when no dep-bump signal
# is present in the environment, it must still open the issue (exit 0).
# ---------------------------------------------------------------------------

@test "Proof A: --container postgres in DRY_RUN opens dep:postgres issue (no auto-detection required)" {
    # Clear all dep-bump signals — auto-detection would return 1 without the override.
    export COMMIT_SUBJECT="chore: unrelated commit"
    export GITHUB_REF_NAME="master"
    unset PR_TITLE PR_NUMBER PR_BODY PR_LABELS
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container postgres
    # Must succeed (not exit 1 like the no-override path would)
    [ "$status" -eq 0 ]

    # DRY_RUN output must reference the dep:postgres dedup label set
    [[ "$output" == *"dep:postgres"* ]]
}

@test "Proof A: --container postgres DRY_RUN shows issue title containing [postgres]" {
    export COMMIT_SUBJECT="chore: unrelated"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container postgres
    [ "$status" -eq 0 ]

    # Issue title must reference the container name
    [[ "$output" == *"[postgres]"* ]]
}

# ---------------------------------------------------------------------------
# Proof B — container-scoped close: --mode recovery --container <c>
#
# Mutation locked: close_container_build_failure_on_recovery searches by
# labels build-failure,automation,dep:<container> — NOT by title substring
# "Auto Build Failed".  If you change the label query to a title-based search
# (the global close bug), Proof B breaks because the mock returns an issue
# with "Auto Build Failed" title but WITHOUT the dep:postgres label filter.
#
# Critically: a different container's issue (dep:nginx) must NOT be closed.
# ---------------------------------------------------------------------------

@test "Proof B: --mode recovery --container postgres closes dep:postgres issue, not dep:nginx" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"

    # Mock: --label dep:postgres → return postgres issue.
    #       --label dep:nginx   → return nginx issue (must NOT be closed).
    #       Close must only target #77 (postgres).
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"--label dep:postgres"*)
        echo '[{"number":77,"title":"Build failed postgres"}]'
        ;;
    *"--label dep:nginx"*)
        echo '[{"number":88,"title":"Build failed nginx"}]'
        ;;
    *"issue comment"*"77"*)
        echo "comment posted" >&2
        ;;
    *"issue close"*"77"*)
        echo "closed postgres issue" >&2
        ;;
    *"issue close"*"88"*)
        echo "ERROR: must not close nginx issue during postgres recovery" >&2
        exit 99
        ;;
    *"issue list"*)
        echo "[]"
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

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery --container postgres
    [ "$status" -eq 0 ]

    # gh issue close must have been called with #77 (postgres)
    grep -q "issue close" "$call_log"
    grep -q "77" "$call_log"

    # The close call must have used dep:postgres label (not title-based search)
    grep -q "\-\-label dep:postgres" "$call_log"

    # gh issue close for #88 (nginx) must NOT appear
    if grep -q "issue close" "$call_log"; then
        ! grep "issue close" "$call_log" | grep -q "88"
    fi
}

@test "Proof B: --mode recovery --container postgres DRY_RUN shows dep:postgres in output (not title search)" {
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery --container postgres
    [ "$status" -eq 0 ]

    # DRY_RUN output must reference the container-scoped label
    [[ "$output" == *"dep:postgres"* ]]
    # Must NOT reference the generic title-based search
    [[ "$output" != *"Auto Build Failed"* ]]
}

# ---------------------------------------------------------------------------
# Proof C — recovery no-op: no open issue for the container → exit 0
# ---------------------------------------------------------------------------

@test "Proof C: --mode recovery --container nonexistent, no open issue → exit 0, no close" {
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
        echo "ERROR: close must not be called when no issue exists" >&2
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

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery --container nonexistent
    [ "$status" -eq 0 ]

    # gh issue close must NOT have been called
    if [ -f "$call_log" ]; then
        run grep "issue close" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

# ---------------------------------------------------------------------------
# Proof D — backward compatibility: without --container, all existing
# auto-detection and generic fallback paths work unchanged.
# ---------------------------------------------------------------------------

@test "Proof D: without --container, deps(php) commit → auto-detects php, exit 0 (DRY_RUN)" {
    export COMMIT_SUBJECT="deps(php): update 4 dependencies"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[php]"* ]]
}

@test "Proof D: without --container, no dep-bump → exit 1 (generic fallback)" {
    export COMMIT_SUBJECT="fix(ci): something unrelated"
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh"
    [ "$status" -eq 1 ]
}

@test "Proof D: without --container, --mode recovery uses global title-based close (unscoped, unchanged)" {
    mkdir -p "$TEST_TEMP_DIR/bin"
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
        echo "closed" >&2
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

    # Must have closed issue #42 via global title-based search (unscoped recovery unchanged)
    grep -q "issue close" "$call_log"
    grep -q "42" "$call_log"
}

# ---------------------------------------------------------------------------
# Finding 5 — malformed/injection-shaped container names are rejected
#
# Both the override-open and recovery-close paths validate container names
# against ^[a-z0-9_-]+$. A name containing shell metacharacters or spaces
# must be rejected with a warning and exit 0 (no gh issue create/close
# attempted). Prevents label injection via a crafted OVERRIDE_CONTAINER.
# ---------------------------------------------------------------------------

@test "FIX5+F2: --mode failure --container 'foo;bar' (invalid) → exit 3, no gh calls (fail-closed)" {
    # Invalid container name in failure mode must return 3 (gh/op failure class) so that
    # the checkpoint loop's `|| issue_open_failed=true` fires → issue_mode downgrades
    # per-container→generic → generic backstop alerts (fail-closed, not silent drop).
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue create"* | *"issue comment"* | *"issue close"*)
        echo "ERROR: gh must not be called for an invalid container name" >&2
        exit 99
        ;;
    *"issue list"*)
        echo "[]"
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
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container "foo;bar"
    # exit 3 (gh/op failure class) — triggers issue_open_failed=true in checkpoint loop
    [ "$status" -eq 3 ]

    # gh issue create/comment must NOT have been called
    if [ -f "$call_log" ]; then
        run grep -E "issue (create|comment|close)" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

@test "FIX5: --mode recovery --container 'a b' is rejected, exit 0, no gh close (DRY_RUN)" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue close"*)
        echo "ERROR: gh close must not be called for an invalid container name" >&2
        exit 99
        ;;
    *"issue list"*)
        echo '[{"number":99,"title":"some build failure"}]'
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
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery --container "a b"
    [ "$status" -eq 0 ]

    # gh issue close must NOT have been called
    if [ -f "$call_log" ]; then
        run grep "issue close" "$call_log"
        [ "$status" -ne 0 ]
    fi
}

# ---------------------------------------------------------------------------
# FIX 2 — gh issue list failure in close_container_build_failure_on_recovery
# must exit 0 (best-effort) with a warning, not abort under set -euo pipefail.
# ---------------------------------------------------------------------------

@test "FIX2: --mode recovery --container postgres, gh issue list fails → exit 0, no gh close (set -e safe)" {
    # close_container_build_failure_on_recovery uses `if ! x=$(cmd); then` pattern.
    # Under set -euo pipefail, the old `x=$(cmd); rc=$?; if rc -ne 0` was dead code:
    # set -e aborted before the rc check.  The fix must keep exit 0 (best-effort).
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        # Simulate gh CLI failure (network error, auth error, etc.)
        echo "gh: failed to list issues: context deadline exceeded" >&2
        exit 1
        ;;
    *"issue close"*)
        echo "ERROR: gh close must not be called when list failed" >&2
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
    export GITHUB_REPOSITORY="owner/repo"
    export GITHUB_RUN_ID="12345"
    export GITHUB_SHA="abcdef1234567890abcdef1234567890abcdef12"
    export GITHUB_SERVER_URL="https://github.com"

    # Recovery with a failing gh issue list must exit 0 (best-effort, not abort under set -e)
    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery --container postgres
    [ "$status" -eq 0 ]

    # gh issue close must NOT have been called
    run grep "issue close" "$call_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# FIX A+2 — find_or_create_issue must fail with exit 3 (gh op failure) on
# create/comment failure, distinct from exit 1 (no-dep-bump-detected).
# ---------------------------------------------------------------------------

@test "FIX A+2: find_or_create_issue gh issue create failure → script exits 3 (gh op), not 1 (no-dep-bump)" {
    # Exit code 3 = gh/issue-operation failure (distinct from 1 = no dep-bump).
    # The auto-build.yaml summary step interprets rc=3 as a warning, NOT as
    # "no-dep-bump" → no false suppression of the generic issue backstop.
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        # No existing open issue for this container
        echo '[]'
        ;;
    *"label create"*)
        # Best-effort label creation — succeed
        exit 0
        ;;
    *"issue create"*)
        # Simulate gh CLI failure (e.g. auth error, rate limit)
        echo "gh: error: HTTP 401 Unauthorized" >&2
        exit 1
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    # Mock sleep to avoid retry_with_backoff delays (3 attempts × 5+10s = 15s wall time)
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TEMP_DIR/bin/sleep"
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export DRY_RUN="false"    # Override setup default (setup sets DRY_RUN=true)
    export GITHUB_REPOSITORY="owner/repo"
    export GITHUB_RUN_ID="12345"
    export GITHUB_SHA="abcdef1234567890abcdef1234567890abcdef12"
    export GITHUB_SERVER_URL="https://github.com"

    # Script must exit 3 (gh op failure), NOT 1 (no-dep-bump)
    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container postgres
    [ "$status" -eq 3 ]

    # Must NOT print a bogus "created #<empty>" or "created #0"
    [[ "$output" != *"created #"$'\n'* ]] || [[ "$output" != *"created #0"* ]]
}

@test "FIX A+2: find_or_create_issue gh issue create returns empty number → exits 3 (not 1)" {
    # When gh issue create succeeds (exit 0) but outputs no parseable issue number,
    # the script must exit 3 (gh/parse failure) rather than 1 (no-dep-bump) or 0.
    mkdir -p "$TEST_TEMP_DIR/bin"
    local call_log="$TEST_TEMP_DIR/gh_calls.log"
    cat > "$TEST_TEMP_DIR/bin/gh" << GHEOF
#!/bin/bash
echo "\$*" >> "$call_log"
case "\$*" in
    *"issue list"*)
        echo '[]'
        ;;
    *"label create"*)
        exit 0
        ;;
    *"issue create"*)
        # Succeed but output no numeric issue number (unexpected API response)
        echo "https://github.com/owner/repo/issues/"
        ;;
    *)
        echo "unexpected gh args: \$*" >&2
        exit 1
        ;;
esac
GHEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    # No sleep mock needed: gh issue create succeeds (exit 0), no retries
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export DRY_RUN="false"    # Override setup default (setup sets DRY_RUN=true)
    export GITHUB_REPOSITORY="owner/repo"
    export GITHUB_RUN_ID="12345"
    export GITHUB_SHA="abcdef1234567890abcdef1234567890abcdef12"
    export GITHUB_SERVER_URL="https://github.com"

    # Script must exit 3 (gh parse failure), NOT 1 (no-dep-bump)
    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container postgres
    [ "$status" -eq 3 ]
}

@test "FIX 2: no-dep-bump auto-detect path exits 1 (not 3) — exit codes are distinct" {
    # Confirm the contract: rc=1 means "no dep-bump detected" (not a gh failure).
    # This is the --mode failure path WITHOUT --container, where detect_dep_bump fails.
    # setup() provides COMMIT_SUBJECT="chore: update readme" — no dep-bump pattern.
    export DRY_RUN="false"    # Override setup default

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure
    # exit 1 = no dep-bump detected (caller should fall back to generic issue logic)
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# F3 — FAILED_ALLOWLIST cross-check in auto-detect path
# ---------------------------------------------------------------------------

@test "F3: FAILED_ALLOWLIST set, detected container absent → exits 1 (skip, no spurious issue)" {
    # deps(php) commit detected, but FAILED_ALLOWLIST=['other'] — php is not in the failure set.
    # Script must exit 1 (no-op, same as no-dep-bump) without opening a gh issue.
    export COMMIT_SUBJECT="deps(php): bump to 8.3"
    export FAILED_ALLOWLIST='["other"]'
    export DRY_RUN="true"   # DRY_RUN; would exit 0 if it reached find_or_create_issue

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure
    # Must exit 1 (skip) — not 0 (would mean spurious issue opened)
    [ "$status" -eq 1 ]
}

@test "F3: FAILED_ALLOWLIST set, detected container present → proceeds (exits 0 in DRY_RUN)" {
    # deps(php) commit detected, FAILED_ALLOWLIST=['php'] — php IS in the failure set.
    # Script must proceed to open the issue (DRY_RUN → exit 0 with dry-run output).
    export COMMIT_SUBJECT="deps(php): bump to 8.3"
    export FAILED_ALLOWLIST='["php"]'
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure
    # Must exit 0 (DRY_RUN path reached → issue would be opened)
    [ "$status" -eq 0 ]
}

@test "F3: FAILED_ALLOWLIST unset → no cross-check, original behaviour (exits 0 in DRY_RUN)" {
    # No FAILED_ALLOWLIST → non-checkpoint run; original #514 behaviour preserved.
    # deps(php) commit detected, no allowlist → proceeds unconditionally.
    export COMMIT_SUBJECT="deps(php): bump to 8.3"
    unset FAILED_ALLOWLIST
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure
    [ "$status" -eq 0 ]
}

@test "F3: FAILED_ALLOWLIST='' (empty string) → no cross-check, original behaviour" {
    # Empty string (checkpoint skipped/guard-break) → same as unset → no allowlist check.
    export COMMIT_SUBJECT="deps(php): bump to 8.3"
    export FAILED_ALLOWLIST=""
    export DRY_RUN="true"

    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# F4 — --container with no value exits 2 (usage error, distinct from 1)
# ---------------------------------------------------------------------------

@test "F4: --container with no value → exit 2 + warning (not exit 1 no-dep-bump)" {
    # Under set -u, bare --container with no $2 would crash with "unbound variable".
    # With ${2:-} guard it must exit 2 (usage error) with a warning, not exit 1.
    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container
    [ "$status" -eq 2 ]
    [[ "$output" == *"--container requires a value"* ]]
}

# ---------------------------------------------------------------------------
# F2 — invalid --container name in failure mode → exit 3 (downgrade, not 0)
# ---------------------------------------------------------------------------

@test "F2: --mode failure --container 'Bad.Name' (invalid chars) → exit 3, not 0" {
    # An invalid container name must return 3 (gh/op failure class) so that
    # the checkpoint loop's `|| issue_open_failed=true` fires → issue_mode
    # downgrades per-container→generic → generic backstop alerts.
    # Previously returned 0, which silently suppressed the alert.
    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode failure --container "Bad.Name"
    [ "$status" -eq 3 ]
}

@test "F2: --mode recovery --container 'Bad.Name' (invalid chars) → exit 0 (best-effort close, unchanged)" {
    # Recovery path keeps best-effort return 0 for invalid names — close has no alert
    # obligation, so fail-open is correct there.  This test confirms the asymmetry.
    run bash "$SCRIPTS_DIR/open-dep-failure-issue.sh" --mode recovery --container "Bad.Name"
    [ "$status" -eq 0 ]
}
