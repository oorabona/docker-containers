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
    printf '%s\n' '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":"not-an-array"}},"created_at":"2000-01-01T00:00:00Z"}]'
    exit 0
fi

if [[ "${GH_MODE:-}" == "delete-failure" || "${GH_MODE:-}" == "cleanup-failure" ]]; then
    printf '%s\n' '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]'
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

assert_output_reports_invalid_created_at() {
    if [[ "$output" != *"validation failed: versions[1].created_at is invalid"* ]]; then
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

assert_tag_decode_failure_stops_before_delete() {
    local log_file="$1"
    if [[ "$status" -ne 1 || -s "$log_file" || "$output" != *"Failed to read version tags; skipping protected"* ]]; then
        echo "ASSERTION FAILED: tag decode failure must stop the package before DELETE" >&2
        return 1
    fi
}

assert_prepared_decode_preserves_delete_totals() {
    if [[ "$output" != *"Summary: kept=0, deleted=1, delete_failures=0"* || "$output" != *"Packages assessed: 1"* ]]; then
        echo "ASSERTION FAILED: a completed deletion plan must keep successful deletes in the totals and assess the package" >&2
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

printf '%s\n' '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]'
printf '%s\n' '[{"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]'
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

@test "an invalid version record is unassessed, attempts no deletion, and does not abandon later packages" {
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
    [[ "$output" == *"validation failed: versions[0].metadata.container.tags is invalid"* ]]
    [[ "$output" == *"Processing: healthy"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
    [[ ! -s "$GH_LOG" ]]
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

@test "sourcing fails closed when the version validation helper is absent" {
    local missing_root="$BATS_TEST_TMPDIR/missing-helper"
    mkdir -p "$missing_root/scripts"
    cp "$PROJECT_ROOT/scripts/cleanup-old-versions.sh" "$missing_root/scripts/cleanup-old-versions.sh"

    run env -u VERSION_RECORD_VALIDATION_JQ bash -c '
        set +e
        source "$1"
        source_status=$?
        ! declare -F purge_container >/dev/null
        [[ "$source_status" -ne 0 ]]
    ' _ "$missing_root/scripts/cleanup-old-versions.sh"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Failed to source version record validation helper: $missing_root/helpers/version-record-validation.sh"* ]]
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

@test "an invalid later created_at attempts no DELETE for the package" {
    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"--method DELETE"* ]]; then
    printf 'DELETE:%s\n' "$*" >> "$GH_LOG"
    exit 0
fi

printf '%s\n' '[
  {"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"},
  {"id":102,"name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}},"created_at":"not-a-date"}
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
    assert_output_reports_invalid_created_at
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

@test "a tag decode failure stops a protecting version before DELETE" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"v1.2.3\"]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
            }
            jq() {
                if [[ "${!#}" == ".tags[]" ]]; then echo "jq: tag decode exhausted" >&2; return 1; fi
                command jq "$@"
            }
            main protected
        '

    assert_tag_decode_failure_stops_before_delete "$GH_LOG"
    [[ "$output" == *"Packages assessed: 0"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
}

@test "a prepared deletion decode failure assesses the completed plan and still reports an earlier DELETE" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$GH_LOG" \
        BASE64_CALLS="$STUB_DIR/base64-calls" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
            }
            base64() {
                calls=0; [[ -f "$BASE64_CALLS" ]] && calls=$(<"$BASE64_CALLS")
                calls=$((calls + 1)); printf "%s\\n" "$calls" > "$BASE64_CALLS"
                [[ "$calls" -lt 4 ]] || { echo "base64: prepared record lost" >&2; return 1; }
                command base64 "$@"
            }
            main stale
        '

    [[ "$status" -eq 1 ]]
    [[ "$(<"$GH_LOG")" == *"/versions/101"* ]]
    [[ "$(<"$GH_LOG")" != *"/versions/102"* ]]
    assert_prepared_decode_preserves_delete_totals
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
}

run_old_version_validation_case() {
    local response_json="$1"
    local expected_field="$2"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        RESPONSE_JSON="$response_json" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "%s\n" "$*" >> "$GH_LOG"; return 0; fi
                printf "%s\n" "$RESPONSE_JSON"
            }
            main malformed
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"validation failed: $expected_field"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
    [[ ! -s "$GH_LOG" ]]
}

@test "age cleanup maps jq exit 5 to 14 and jq exit 137 to 11" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        CUTOFF_DATE="2000-01-01T00:00:00Z" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14
            gh() { printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"; }
            purge_container malformed
        '

    [[ "$status" -eq 14 ]]

    local real_jq
    real_jq="$(command -v jq)"
    cat > "$STUB_DIR/jq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == *"validate_old_versions"* ]] && exit 137
done
exec "$REAL_JQ" "$@"
EOF
    chmod +x "$STUB_DIR/jq"

    run env \
        PATH="$STUB_DIR:$PATH" \
        REAL_JQ="$real_jq" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        CUTOFF_DATE="2000-01-01T00:00:00Z" \
        bash -c '
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14
            gh() { printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"; }
            purge_container validator-killed
        '

    [[ "$status" -eq 11 ]]
    [[ "$output" == *"Version validator could not run"* ]]
}

@test "age cleanup validation entry point rejects non-arrays and accepts an empty array" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/helpers/version-record-validation.sh"
        for versions in null "{}" "\"\""; do
            if validation_error=$(jq -er "$VERSION_RECORD_VALIDATION_JQ validate_old_versions" <<< "$versions" 2>&1 >/dev/null); then
                exit 1
            else
                validation_status=$?
            fi
            [[ "$validation_status" -eq 5 ]]
            [[ "$validation_error" == *"validation failed: versions must be an array"* ]]
        done
        jq -er "$VERSION_RECORD_VALIDATION_JQ validate_old_versions" <<< "[]" | grep -qx true
    '

    [[ "$status" -eq 0 ]]
}

@test "age cleanup accepts canonical numeric and string IDs with empty tags" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            gh() {
                [[ "$*" == *"--method DELETE"* ]] && return 1
                printf "%s\n" "[{\"id\":1,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":\"2\",\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
            }
            main valid
        '

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Packages skipped (processing failed): 0"* ]]
}

@test "age cleanup rejects invalid digest and IDs before any deletion" {
    run_old_version_validation_case \
        '[{"id":101,"name":"sha256:not-a-digest","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].name is invalid'
    run_old_version_validation_case \
        '[{"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is missing'
    run_old_version_validation_case \
        '[{"id":0,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is invalid'
    run_old_version_validation_case \
        '[{"id":-1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is invalid'
    run_old_version_validation_case \
        '[{"id":"abc","name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is invalid'
    run_old_version_validation_case \
        '[{"id":"01","name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is invalid'
    run_old_version_validation_case \
        '[{"id":1.0,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is invalid'
    run_old_version_validation_case \
        '[{"id":1e3,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[0].id is invalid'
}

@test "age cleanup rejects duplicate normalized IDs before any deletion" {
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"},{"id":"1","name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[1].id duplicates an earlier value at versions[0]'
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"},{"id":"01","name":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","metadata":{"container":{"tags":[]}},"created_at":"2000-01-01T00:00:00Z"}]' \
        'versions[1].id is invalid'
}

@test "age cleanup rejects malformed and trailing-newline RFC3339 timestamps before any deletion" {
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"1 year ago"}]' \
        'versions[0].created_at is invalid'
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"not-a-date"}]' \
        'versions[0].created_at is invalid'
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":""}]' \
        'versions[0].created_at is invalid'
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2026-08-22T08:01:12"}]' \
        'versions[0].created_at is invalid'
    run_old_version_validation_case \
        '[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2026-08-22T08:01:12Z\n"}]' \
        'versions[0].created_at is invalid'
}

@test "age cleanup accepts the measured RFC3339 created_at shape" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/helpers/version-record-validation.sh"
        jq -e "$VERSION_RECORD_VALIDATION_JQ validate_old_versions" <<'\''JSON'\''
[{"id":1,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":[]}},"created_at":"2026-08-22T08:01:12Z"}]
JSON
    '

    [[ "$status" -eq 0 ]]
    [[ "$output" == "true" ]]
}
