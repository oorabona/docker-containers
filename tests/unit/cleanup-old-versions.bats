#!/usr/bin/env bats

# Unit tests for scripts/cleanup-old-versions.sh fail-closed registry handling.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    STUB_DIR="$(mktemp -d)"
    export GH_LOG="$STUB_DIR/gh.log"

    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"--method DELETE"* ]]; then
    printf 'DELETE:%s\n' "$*" >> "$GH_LOG"
    if [[ "${GH_MODE:-}" == "delete-failure" ]]; then
        echo "gh: delete denied" >&2
        exit 1
    fi
    exit 0
fi

if [[ "${GH_MODE:-}" == "listing-failure" && "$*" == *"/container/broken/versions"* ]]; then
    echo "gh: API rate limit exceeded" >&2
    exit 1
fi

if [[ "${GH_MODE:-}" == "malformed-listing" && "$*" == *"/container/broken/versions"* ]]; then
    printf '%s\n' 'not-json'
    exit 0
fi

if [[ "${GH_MODE:-}" == "empty-listing" && "$*" == *"/container/broken/versions"* ]]; then
    exit 0
fi

if [[ "${GH_MODE:-}" == "malformed-record" && "$*" == *"/container/broken/versions"* ]]; then
    printf '%s\n' '[{"id":101,"metadata":{"container":{"tags":"not-an-array"}},"created_at":"2000-01-01T00:00:00Z"}]'
    exit 0
fi

if [[ "${GH_MODE:-}" == "delete-failure" || "${GH_MODE:-}" == "cleanup-failure" ]]; then
    printf '%s\n' '[{"id":101,"metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]'
else
    printf '%s\n' '[]'
fi
EOF
    chmod +x "$STUB_DIR/gh"
}

assert_executable() {
    local script_path="$1"
    if [[ ! -x "$script_path" ]]; then
        echo "ASSERTION FAILED: expected executable script: $script_path" >&2
        return 1
    fi
}

assert_no_delete_attempts() {
    local log_file="$1"
    if [[ -s "$log_file" ]]; then
        echo "ASSERTION FAILED: expected no DELETE attempt after an invalid later date" >&2
        return 1
    fi
}

assert_output_reports_invalid_date() {
    if [[ "$output" != *"Failed to parse version date; skipping stale"* ]]; then
        echo "ASSERTION FAILED: expected invalid later date to stop the package before DELETE" >&2
        return 1
    fi
}

assert_summary_reports_successful_deletion() {
    if [[ "$output" != *"Summary: kept=0, deleted=1, delete_failures=0"* ]]; then
        echo "ASSERTION FAILED: expected summary to report the successful deletion after cleanup failure" >&2
        return 1
    fi
}

@test "workflow-executed registry pruners are executable" {
    assert_executable "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
    assert_executable "$PROJECT_ROOT/scripts/cleanup-outdated-tags.sh"
}

@test "a zero-status malformed listing is unassessed, while a later package is assessed" {
    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_MODE="malformed-listing" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" broken healthy

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Version listing was not a JSON array; skipping broken"* ]]
    [[ "$output" == *"Processing: healthy"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 1"* ]]
}

@test "a zero-byte successful listing is rejected rather than treated as an empty array" {
    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_MODE="empty-listing" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" broken

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Version listing was not a JSON array; skipping broken"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 1"* ]]
}

@test "two paginated version arrays are flattened so a second-page version is classified" {
    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '[{"id":101,"metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]'
printf '%s\n' '[{"id":102,"metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]'
EOF
    chmod +x "$STUB_DIR/gh"

    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        KEEP_LATEST_COUNT="1" \
        KEEP_MONTHS="0" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" stale

    [[ "$status" -eq 0 ]]
    if [[ "$output" != *"Would delete version 102"* ]]; then
        echo "ASSERTION FAILED: expected second-page version 102 to be classified" >&2
        return 1
    fi
    [[ "$output" == *"Found 2 versions"* ]]
}

@test "a non-array first paginated page is rejected even when a later page is valid" {
    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '{}'
printf '%s\n' '[]'
EOF
    chmod +x "$STUB_DIR/gh"

    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" broken

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Version listing was not a JSON array; skipping broken"* ]]
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 1"* ]]
}

@test "a JSON record that jq cannot prepare is unassessed, cleans its temporary file, and does not abandon later packages" {
    cat > "$STUB_DIR/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${PRUNER_TEMP_FILE:?}"
: > "$PRUNER_TEMP_FILE"
printf '%s\n' "$PRUNER_TEMP_FILE"
EOF
    chmod +x "$STUB_DIR/mktemp"
    local temp_file="$STUB_DIR/version-list"

    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_MODE="malformed-record" \
        GH_LOG="$GH_LOG" \
        PRUNER_TEMP_FILE="$temp_file" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" broken healthy

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to prepare version list; skipping broken"* ]]
    [[ "$output" == *"Processing: healthy"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
    [[ ! -e "$temp_file" ]]
}

@test "sourcing is inert and script_root uses BASH_SOURCE rather than the caller directory" {
    run env -u GH_TOKEN -u OWNER bash -c '
        set -e
        before=$(set +o)
        cd /
        source "$1"
        after=$(set +o)
        [[ "$before" == "$after" ]]
        [[ "$(script_root)" == "$2" ]]
    ' _ "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" "$PROJECT_ROOT"

    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

teardown() {
    rm -rf "$STUB_DIR"
}

@test "listing failure is skipped, reported, and makes the run fail after later packages are assessed" {
    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_MODE="listing-failure" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" broken healthy

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"gh: API rate limit exceeded"* ]]
    [[ "$output" == *"Failed to list versions; skipping broken"* ]]
    [[ "$output" == *"Processing: healthy"* ]]
    [[ "$output" == *"No versions found (might be new or private)"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 1"* ]]
    [[ "$output" == *"Delete failures: 0"* ]]
}

@test "failed deletion is counted and makes the completed run fail" {
    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_MODE="delete-failure" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" stale

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"gh: delete denied"* ]]
    [[ "$output" == *"Failed to delete"* ]]
    [[ "$output" == *"Summary: kept=0, deleted=0, delete_failures=1"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 0"* ]]
    [[ "$output" == *"Delete failures: 1"* ]]
    [[ "$(<"$GH_LOG")" == *"/versions/101"* ]]
}

@test "an invalid later date attempts no DELETE for the package" {
    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"--method DELETE"* ]]; then
    printf 'DELETE:%s\n' "$*" >> "$GH_LOG"
    exit 0
fi

printf '%s\n' '[
  {"id":101,"metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"},
  {"id":102,"metadata":{"container":{"tags":[]}},"created_at":"not-a-date"}
]'
EOF
    chmod +x "$STUB_DIR/gh"

    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" stale

    assert_no_delete_attempts "$GH_LOG"
    [[ "$status" -eq 1 ]]
    assert_output_reports_invalid_date
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
}

@test "a failed post-delete cleanup still reports successful deletions" {
    cat > "$STUB_DIR/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${RM_CALLS:-}" ]]; then
    exec /bin/rm "$@"
fi

calls=0
[[ -f "$RM_CALLS" ]] && calls=$(<"$RM_CALLS")
calls=$((calls + 1))
printf '%s\n' "$calls" > "$RM_CALLS"
[[ "$calls" -eq 1 ]]
EOF
    chmod +x "$STUB_DIR/rm"
    local rm_calls="$STUB_DIR/rm-calls"

    run env \
        PATH="$STUB_DIR:$PATH" \
        GH_MODE="cleanup-failure" \
        GH_LOG="$GH_LOG" \
        RM_CALLS="$rm_calls" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" stale

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Failed to remove deletion list after cleanup"* ]]
    assert_summary_reports_successful_deletion
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
    [[ "$output" == *"Versions deleted: 1"* ]]
    [[ "$(<"$GH_LOG")" == *"/versions/101"* ]]
}
