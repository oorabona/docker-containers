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

@test "otherwise coherent error status is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"error","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
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
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":7,"high":4,"medium":0,"low":0,"info":0},"alert_count":11}' \
        > "$HISTORY_FILE"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-12-01T00:00:00+00:00"
        and .counts == {"critical":7,"high":4,"medium":0,"low":0,"info":0}
        and .top_advisories == [{"rule_id":"CVE-api"}]' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "legacy record without counts keeps the critical-only overlay" {
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","alert_count":2}' \
        > "$HISTORY_FILE"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-12-01T00:00:00+00:00"
        and .counts == {"critical":2,"high":2,"medium":1,"low":0,"info":0}' <<<"$output"
    [ "$status" -eq 0 ]
}

assert_history_rejected() {
    local record="$1"
    local expected
    expected=$(api_fallback)
    printf '%s\n' "$record" > "$HISTORY_FILE"

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

@test "dirty record with empty or incomplete counts is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{},"alert_count":0}'
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":1},"alert_count":1}'
}

@test "record with a negative count is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":-1,"high":1,"medium":0,"low":0,"info":0},"alert_count":0}'
}

@test "record whose alert count disagrees with counts is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"alert_count":2}'
}

@test "clean record with a positive count sum is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"clean","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"alert_count":1}'
}

@test "record with a non-date timestamp is rejected" {
    assert_history_rejected '{"last_scan":"not-a-date","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
}

@test "record with a numeric timestamp is rejected" {
    assert_history_rejected '{"last_scan":42,"status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
}

@test "two JSON history records are rejected without aborting an unguarded caller" {
    expected=$(api_fallback)
    printf '%s\n%s\n' \
        '{"last_scan":"2026-12-01T00:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}' \
        '{"last_scan":"2026-12-02T00:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}' \
        > "$HISTORY_FILE"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}
