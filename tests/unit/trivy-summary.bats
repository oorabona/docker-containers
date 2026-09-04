#!/usr/bin/env bats

# Public-surface tests for get_trivy_summary's scan-history overlay gate.

setup() {
    TEST_TEMP_DIR=$(mktemp -d)
    PROJECT_ROOT=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)
    CATEGORY='container-test-latest-linux/amd64'
    HISTORY_FILE="$TEST_TEMP_DIR/.trivy-scan-history/test-latest-linux-amd64.json"
    API_RESULT='{"last_scan":"2026-01-01T00:00:00Z","counts":{"critical":3,"high":2,"medium":1,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api"}]}'

    mkdir -p "$(dirname "$HISTORY_FILE")"
    SCRIPT_DIR="$TEST_TEMP_DIR"
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    _fetch_trivy_alerts_once() { :; }
    _TRIVY_SUMMARY_MAP=$(jq -nc --arg category "$CATEGORY" --argjson result "$API_RESULT" \
        '{$category: $result}')
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

api_fallback() {
    get_trivy_summary "$CATEGORY"
}

@test "pre-fix dated error record leaves the API result byte-for-byte unchanged" {
    expected=$(api_fallback)
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","status":"error","alert_count":-1,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}}' \
        > "$HISTORY_FILE"

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

@test "post-fix undated error record leaves the API result unchanged" {
    expected=$(api_fallback)
    printf '%s\n' '{"status":"error","alert_count":-1,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}}' \
        > "$HISTORY_FILE"

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

@test "dated record without status is rejected" {
    expected=$(api_fallback)
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","counts":{"critical":0}}' > "$HISTORY_FILE"

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

@test "usable dirty record still overlays its counts onto the API result" {
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":7,"high":4}}' \
        > "$HISTORY_FILE"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-12-01T00:00:00+00:00"
        and .counts == {"critical":7,"high":4,"medium":1,"low":0,"info":0}
        and .top_advisories == [{"rule_id":"CVE-api"}]' <<<"$output"
    [ "$status" -eq 0 ]
}
