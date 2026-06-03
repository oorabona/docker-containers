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
