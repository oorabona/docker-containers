#!/usr/bin/env bats

# Unit tests for scripts/cleanup-old-versions.sh fail-closed registry handling.

bats_require_minimum_version 1.7.0

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

if [[ "$*" != *"/versions"* ]]; then
    case "${GH_MODE:-}" in
        delete-failure|cleanup-failure) package_version_count=1 ;;
        malformed-record)
            [[ "$*" == *"/container/broken"* ]] && package_version_count=1 || package_version_count=0
            ;;
        *) package_version_count=0 ;;
    esac
    printf '{"version_count":%s}\n' "$package_version_count"
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
    printf '%s\n' '[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["obsolete"]}},"created_at":"2000-01-01T00:00:00Z"}]'
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

assert_output_has_line() {
    local expected_line="$1"
    local output_line

    while IFS= read -r output_line; do
        if [[ "$output_line" == "$expected_line" ]]; then
            return 0
        fi
    done <<< "$output"

    printf 'ASSERTION FAILED: expected output line: %s\n' "$expected_line" >&2
    return 1
}

assert_summary_reports_successful_deletion() {
    if [[ "$output" != *"Summary: kept=0, decided=1, deleted=1, delete_failures=0"* ]]; then
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
    if [[ "$output" != *"Summary: kept=0, decided=2, deleted=1, delete_failures=0"* || "$output" != *"Packages assessed: 1"* ]]; then
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

@test "two paginated version arrays are flattened so a second-page untagged version is retained" {
    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" != *"/versions"* ]]; then
    printf '%s\n' '{"version_count":2}'
    exit 0
fi

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
    if [[ "$output" == *"Would delete version 102"* || "$output" != *"Keep #2 (version 102; tags: untagged) - untagged; deferred to cleanup-outdated-tags.sh"* ]]; then
        echo "ASSERTION FAILED: expected second-page untagged version 102 to be retained" >&2
        return 1
    fi
    [[ "$output" == *"Found 2 versions"* ]]
}

@test "a short version listing is unassessed, attempts no deletion, and does not abandon later packages" {
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
                if [[ "$*" == *"/versions"* ]]; then
                    [[ "$*" == *"/container/short/versions"* ]] && printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]" || printf "%s\\n" "[]"
                elif [[ "$*" == *"/container/short"* ]]; then
                    printf "%s\\n" "{\"version_count\":2}"
                else
                    printf "%s\\n" "{\"version_count\":0}"
                fi
            }
            main short healthy
        '

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Version listing count does not agree with package version_count or version_count was invalid: package version_count is invalid or does not match the versions listing; skipping short"* ]]
    [[ "$output" == *"Processing: healthy"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 1"* ]]
    [[ ! -s "$GH_LOG" ]]
}

@test "a listing matching its package total keeps the normal retention and deletion behavior" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="false" \
        KEEP_LATEST_COUNT="1" \
        KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" == *"/versions"* ]]; then
                    printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"obsolete\"]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
                else
                    printf "%s\\n" "{\"version_count\":2}"
                fi
            }
            main stale
        '

    [[ "$status" -eq 0 ]]
    [[ "$(<"$GH_LOG")" == *"/versions/102"* ]]
    [[ "$output" == *"Summary: kept=1, decided=1, deleted=1, delete_failures=0"* ]]
}

@test "stale untagged records beyond the latest-count window never reach DELETE" {
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
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\n" "{\"version_count\":3}"; return 0; fi
                printf "%s\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":103,\"name\":\"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
            }
            main stale-untagged
        '

    [[ "$status" -eq 0 ]]
    [[ ! -s "$GH_LOG" ]]
    [[ "$output" == *"Summary: kept=3, decided=0, deleted=0, delete_failures=0"* ]]
    [[ "$output" == *"Versions decided for deletion: 0"* ]]
    [[ "$output" == *"Versions deleted: 0"* ]]
}

@test "age cleanup deletes a stale tagged record but not a stale untagged record" {
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
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"obsolete\"]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
            }
            main mixed-stale
        '

    [[ "$status" -eq 0 ]]
    [[ "$(<"$GH_LOG")" == *"/versions/101"* ]]
    [[ "$(<"$GH_LOG")" != *"/versions/102"* ]]
    [[ "$(wc -l < "$GH_LOG")" -eq 1 ]]
    assert_output_has_line "    ✓ Deleted version 101"
    [[ "$output" == *"Summary: kept=1, decided=1, deleted=1, delete_failures=0"* ]]
    [[ "$output" == *"Versions decided for deletion: 1"* ]]
    [[ "$output" == *"Versions deleted: 1"* ]]
}

@test "dry run reports a decided deletion without reporting a removal" {
    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$GH_LOG" \
        GH_TOKEN="test-token" \
        OWNER="test-owner" \
        DRY_RUN="true" \
        KEEP_LATEST_COUNT="0" \
        KEEP_MONTHS="0" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
            gh() {
                if [[ "$*" == *"--method DELETE"* ]]; then printf "DELETE:%s\\n" "$*" >> "$GH_LOG"; return 0; fi
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":1}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"obsolete\"]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
            }
            main stale
        '

    [[ "$status" -eq 0 ]]
    [[ ! -s "$GH_LOG" ]]
    assert_output_has_line "    [DRY RUN] Would delete version 101"
    [[ "$output" == *"Summary: kept=0, decided=1, deleted=0, delete_failures=0"* ]]
    [[ "$output" == *"Versions decided for deletion: 1"* ]]
    [[ "$output" == *"Versions deleted: 0"* ]]
    [[ "$output" == *"Delete failures: 0"* ]]
}

@test "an absent or non-numeric package version total refuses the listing" {
    local package_response
    for package_response in '{}' '{"version_count":"two"}'; do
        : > "$GH_LOG"
        run env \
            PROJECT_ROOT="$PROJECT_ROOT" \
            GH_LOG="$GH_LOG" \
            PACKAGE_RESPONSE="$package_response" \
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
                    if [[ "$*" == *"/versions"* ]]; then
                        [[ "$*" == *"/container/broken/versions"* ]] && printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]" || printf "%s\\n" "[]"
                    elif [[ "$*" == *"/container/broken"* ]]; then
                        printf "%s\\n" "$PACKAGE_RESPONSE"
                    else
                        printf "%s\\n" "{\"version_count\":0}"
                    fi
                }
                main broken healthy
            '

        [[ "$status" -eq 1 ]]
        [[ "$output" == *"Version listing count does not agree with package version_count or version_count was invalid: package version_count is invalid or does not match the versions listing; skipping broken"* ]]
        [[ "$output" == *"Processing: healthy"* ]]
        [[ "$output" == *"Packages assessed: 1"* ]]
        [[ "$output" == *"Packages skipped (listing failed): 1"* ]]
        [[ ! -s "$GH_LOG" ]]
    done
}

@test "a non-array first paginated page is rejected even when a later page is valid" {
    cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" != *"/versions"* ]]; then
    printf '%s\n' '{"version_count":1}'
    exit 0
fi

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

@test "a preparation failure removes both work files and does not abandon later packages" {
    local versions_file="$STUB_DIR/versions-file"
    local deletions_file="$STUB_DIR/deletions-file"
    local observed_file="$STUB_DIR/work-files-observed"
    local mktemp_calls="$STUB_DIR/mktemp-calls"

    run env \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$GH_LOG" \
        PRUNER_VERSIONS_FILE="$versions_file" \
        PRUNER_DELETIONS_FILE="$deletions_file" \
        PRUNER_WORK_FILES_OBSERVED="$observed_file" \
        PRUNER_MKTEMP_CALLS="$mktemp_calls" \
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
                if [[ "$*" == *"/versions"* ]]; then
                    [[ "$*" == *"/container/broken/versions"* ]] && printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]" || printf "%s\\n" "[]"
                elif [[ "$*" == *"/container/broken"* ]]; then
                    printf "%s\\n" "{\"version_count\":1}"
                else
                    printf "%s\\n" "{\"version_count\":0}"
                fi
            }
            mktemp() {
                calls=0; [[ -f "$PRUNER_MKTEMP_CALLS" ]] && calls=$(<"$PRUNER_MKTEMP_CALLS")
                calls=$((calls + 1)); printf "%s\\n" "$calls" > "$PRUNER_MKTEMP_CALLS"
                case "$calls" in
                    1) temp_path="$PRUNER_VERSIONS_FILE" ;;
                    2) temp_path="$PRUNER_DELETIONS_FILE" ;;
                    *) return 1 ;;
                esac
                : > "$temp_path"
                printf "%s\\n" "$temp_path"
            }
            jq() {
                local argument
                for argument in "$@"; do
                    case "$argument" in
                        ".[] | {id: "*)
                            [[ -e "$PRUNER_VERSIONS_FILE" && -e "$PRUNER_DELETIONS_FILE" ]] || return 97
                            printf "both work files existed\\n" > "$PRUNER_WORK_FILES_OBSERVED"
                            echo "jq: preparation failed" >&2
                            return 1
                            ;;
                    esac
                done
                command jq "$@"
            }
            main broken healthy
        '

    [[ "$status" -eq 1 ]]
    [[ "$(<"$observed_file")" == "both work files existed" ]]
    [[ ! -e "$versions_file" ]]
    [[ ! -e "$deletions_file" ]]
    [[ ! -s "$GH_LOG" ]]
    [[ "$output" == *"Failed to prepare version list; skipping broken"* ]]
    [[ "$output" == *"Processing: healthy"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (processing failed): 1"* ]]
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
        if declare -F purge_container >/dev/null; then
            echo "ASSERTION FAILED: purge_container must not exist after failed validation-helper source" >&2
            exit 1
        fi
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
    assert_output_has_line "    ✗ Failed to delete version 101"
    [[ "$output" == *"Summary: kept=0, decided=1, deleted=0, delete_failures=1"* ]]
    [[ "$output" == *"Packages assessed: 1"* ]]
    [[ "$output" == *"Packages skipped (listing failed): 0"* ]]
    [[ "$output" == *"Versions decided for deletion: 1"* ]]
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

if [[ "$*" != *"/versions"* ]]; then
    printf '%s\n' '{"version_count":2}'
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":1}"; return 0; fi
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\\n" "{\"version_count\":2}"; return 0; fi
                printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[\"obsolete-a\"]}},\"created_at\":\"2000-01-01T00:00:00Z\"},{\"id\":102,\"name\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"metadata\":{\"container\":{\"tags\":[\"obsolete-b\"]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"
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
                if [[ "$*" != *"/versions"* ]]; then command jq -c "{version_count: length}" <<< "$RESPONSE_JSON"; return 0; fi
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
            CLEANUP_CONFIG_VALIDATED=true
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14
            gh() { [[ "$*" != *"/versions"* ]] && { printf "%s\\n" "{\"version_count\":1}"; return; }; printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"; }
            purge_container malformed
        '

    [[ "$status" -eq 14 ]]

    local real_jq
    real_jq="$(command -v jq)"
    cat > "$STUB_DIR/jq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == *$'\n    validate_old_versions' ]] && exit 137
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
            CLEANUP_CONFIG_VALIDATED=true
            LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14
            gh() { [[ "$*" != *"/versions"* ]] && { printf "%s\\n" "{\"version_count\":1}"; return; }; printf "%s\\n" "[{\"id\":101,\"name\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"metadata\":{\"container\":{\"tags\":[]}},\"created_at\":\"2000-01-01T00:00:00Z\"}]"; }
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
                if [[ "$*" != *"/versions"* ]]; then printf "%s\n" "{\"version_count\":2}"; return 0; fi
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

@test "age cleanup rejects invalid configuration before gh or curl" {
    local command_dir="$BATS_TEST_TMPDIR/invalid-cleanup-config-bin"
    local gh_log="$BATS_TEST_TMPDIR/invalid-cleanup-config-gh.log"
    local curl_log="$BATS_TEST_TMPDIR/invalid-cleanup-config-curl.log"
    mkdir -p "$command_dir"
    : > "$gh_log"
    : > "$curl_log"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >> "$GH_LOG"' \
        'if [[ "$*" == *"--method DELETE"* ]]; then exit 0; fi' \
        'if [[ "$*" == *"/versions"* ]]; then printf "%s\\n" '\''[{"id":101,"name":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","metadata":{"container":{"tags":["stale"]}},"created_at":"2000-01-01T00:00:00Z"}]'\''; else printf "%s\\n" '\''{"version_count":1}'\''; fi' \
        > "$command_dir/gh"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$*" >> "$CURL_LOG"' > "$command_dir/curl"
    chmod +x "$command_dir/gh" "$command_dir/curl"

    run env \
        PATH="$command_dir:$PATH" \
        PROJECT_ROOT="$PROJECT_ROOT" \
        GH_LOG="$gh_log" \
        CURL_LOG="$curl_log" \
        GH_TOKEN=test-token \
        OWNER=test-owner \
        DRY_RUN=TRUE \
        KEEP_LATEST_COUNT=0 \
        KEEP_MONTHS=0 \
        bash -c 'source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"; main stale'

    [[ "$status" -eq 64 ]]
    [[ "$output" == "cleanup configuration rejected: DRY_RUN must be exactly true or false" ]]
    [[ ! -s "$gh_log" ]]
    [[ ! -s "$curl_log" ]]
    [[ "$(<"$gh_log")" != *"--method DELETE"* ]]
    [[ "$(<"$curl_log")" != *"DELETE"* ]]
}

@test "age purge refuses direct invocation before its first network call" {
    local gh_log="$BATS_TEST_TMPDIR/direct-age-purge-gh.log"
    : > "$gh_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
        gh() { printf "%s\\n" "$*" >> "$GH_LOG"; }
        unset CLEANUP_CONFIG_VALIDATED
        purge_container stale
    '

    [[ "$status" -eq 64 ]]
    [[ "$output" == "cleanup deletion refused: configuration has not been validated" ]]
    [[ ! -s "$gh_log" ]]
}

@test "age deletion wrapper refuses without a validation marker" {
    local gh_log="$BATS_TEST_TMPDIR/direct-age-delete-gh.log"
    : > "$gh_log"

    run env PROJECT_ROOT="$PROJECT_ROOT" GH_LOG="$gh_log" bash -c '
        source "$PROJECT_ROOT/scripts/cleanup-old-versions.sh"
        gh() { printf "%s\\n" "$*" >> "$GH_LOG"; }
        unset CLEANUP_CONFIG_VALIDATED
        cleanup_delete stale 101
    '

    [[ "$status" -eq 64 ]]
    [[ "$output" == "cleanup deletion refused: configuration has not been validated" ]]
    [[ ! -s "$gh_log" ]]
}
