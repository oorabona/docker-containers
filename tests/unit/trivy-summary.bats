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

set_api_result() {
    local result="$1"
    _TRIVY_SUMMARY_MAP=$(jq -nc --arg category "$CATEGORY" --argjson result "$result" \
        '{$category: $result}')
}

write_history_record() {
    printf '%s\n' "$1" > "$HISTORY_FILE"
}

@test "API result strictly newer than the record survives byte-for-byte" {
    set_api_result '{"last_scan":"2026-05-07T12:00:01Z","counts":{"critical":3,"high":2,"medium":1,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api"}]}'
    expected=$(api_fallback)
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

@test "record strictly newer than the API overlays its counts" {
    write_history_record '{"last_scan":"2026-05-07T12:00:01+00:00","status":"dirty","counts":{"critical":0,"high":7,"medium":0,"low":0,"info":0},"alert_count":7}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-05-07T12:00:01+00:00" and .counts.high == 7' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "equal instants with the same spelling retain the record overlay" {
    set_api_result '{"last_scan":"2026-05-07T12:00:00+00:00","counts":{"critical":3,"high":2,"medium":1,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api"}]}'
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-05-07T12:00:00+00:00" and .counts.high == 0' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "equal instants with +00:00 record and Z API retain the record overlay" {
    set_api_result '{"last_scan":"2026-05-07T12:00:00Z","counts":{"critical":3,"high":2,"medium":1,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api"}]}'
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-05-07T12:00:00+00:00" and .counts.high == 0' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "record newer by one second with +00:00 spelling overlays the Z API" {
    set_api_result '{"last_scan":"2026-05-07T12:00:00Z","counts":{"critical":3,"high":2,"medium":1,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api"}]}'
    write_history_record '{"last_scan":"2026-05-07T12:00:01+00:00","status":"dirty","counts":{"critical":0,"high":8,"medium":0,"low":0,"info":0},"alert_count":8}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-05-07T12:00:01+00:00" and .counts.high == 8' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "API newer by one second across +00:00 and Z spellings survives unchanged" {
    set_api_result '{"last_scan":"2026-05-07T12:00:01Z","counts":{"critical":3,"high":2,"medium":1,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api"}]}'
    expected=$(api_fallback)
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

@test "record overlays when the API has no entry for its category" {
    _TRIVY_SUMMARY_MAP='{}'
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"dirty","counts":{"critical":0,"high":6,"medium":0,"low":0,"info":0},"alert_count":6}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-05-07T12:00:00+00:00" and .counts.high == 6 and .top_advisories == []' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "unparseable API timestamps retain the record overlay" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    for api_timestamp in '2026-08-22T08:01:12' '1 year ago'; do
        set_api_result "{\"last_scan\":\"$api_timestamp\",\"counts\":{\"critical\":3,\"high\":2,\"medium\":1,\"low\":0,\"info\":0},\"top_advisories\":[{\"rule_id\":\"CVE-api\"}]}"

        run get_trivy_summary "$CATEGORY"
        [ "$status" -eq 0 ]
        run jq -e '.last_scan == "2026-05-07T12:00:00+00:00" and .counts.high == 0' <<<"$output"
        [ "$status" -eq 0 ]
    done
}

@test "a stale clean cache record cannot hide a newer API HIGH finding" {
    set_api_result '{"last_scan":"2026-05-08T12:00:00Z","counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-TUESDAY-HIGH","severity":"high"}]}'
    expected=$(api_fallback)
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
    run jq -e '.counts.high == 1 and .top_advisories[0].rule_id == "CVE-TUESDAY-HIGH"' <<<"$actual"
    [ "$status" -eq 0 ]
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

@test "legacy dirty record with zero alerts is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","alert_count":0}'
}

@test "legacy clean record with alerts is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"clean","alert_count":5}'
}

assert_history_rejected() {
    local record="$1"
    local expected
    expected=$(api_fallback)
    printf '%s\n' "$record" > "$HISTORY_FILE"

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

assert_history_timestamp_accepted() {
    local timestamp="$1"
    local month="$2"
    printf '{"last_scan":"%s","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}\n' "$timestamp" > "$HISTORY_FILE"

    run trivy_scan_history_record "$HISTORY_FILE"
    [ "$status" -eq 0 ]
    if [ "$(jq -r '.usable' <<<"$output")" != "true" ]; then
        printf 'FAIL: expected %s last day (%s) to be accepted; got: %s\n' "$month" "$timestamp" "$output" >&2
        return 1
    fi
    [ "$(jq -r '.last_scan' <<<"$output")" = "$timestamp" ]
}

assert_history_timestamp_rejected() {
    local timestamp="$1"
    printf '{"last_scan":"%s","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}\n' "$timestamp" > "$HISTORY_FILE"

    run trivy_scan_history_record "$HISTORY_FILE"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.usable' <<<"$output")" = "false" ]
    [ "$(jq -r '.reason' <<<"$output")" = "malformed-record" ]
}

assert_api_timestamp_parsed() {
    local timestamp="$1"
    local record_timestamp="$2"
    local expected actual
    set_api_result "{\"last_scan\":\"$timestamp\",\"counts\":{\"critical\":3,\"high\":2,\"medium\":1,\"low\":0,\"info\":0},\"top_advisories\":[{\"rule_id\":\"CVE-api\"}]}"
    expected=$(api_fallback)
    write_history_record "{\"last_scan\":\"$record_timestamp\",\"status\":\"clean\",\"counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"info\":0},\"alert_count\":0}"

    actual=$(get_trivy_summary "$CATEGORY")
    [ "$actual" = "$expected" ]
}

assert_api_timestamp_rejected() {
    local timestamp="$1"
    local record_timestamp="$2"
    local actual
    set_api_result "{\"last_scan\":\"$timestamp\",\"counts\":{\"critical\":3,\"high\":2,\"medium\":1,\"low\":0,\"info\":0},\"top_advisories\":[{\"rule_id\":\"CVE-api\"}]}"
    write_history_record "{\"last_scan\":\"$record_timestamp\",\"status\":\"clean\",\"counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"info\":0},\"alert_count\":0}"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e --arg timestamp "$record_timestamp" '.last_scan == $timestamp and .counts.high == 0' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "scan history accepts the last real day of every month" {
    local month day month_day
    for month_day in January:2026-01-31 February:2026-02-28 March:2026-03-31 April:2026-04-30 \
                     May:2026-05-31 June:2026-06-30 July:2026-07-31 August:2026-08-31 \
                     September:2026-09-30 October:2026-10-31 November:2026-11-30 December:2026-12-31; do
        month=${month_day%%:*}
        day=${month_day#*:}
        assert_history_timestamp_accepted "${day}T00:00:00Z" "$month"
    done
}

@test "scan history rejects the first impossible day of every month" {
    local day
    for day in 2026-01-32 2026-02-30 2026-03-32 2026-04-31 \
               2026-05-32 2026-06-31 2026-07-32 2026-08-32 \
               2026-09-31 2026-10-32 2026-11-31 2026-12-32; do
        assert_history_timestamp_rejected "${day}T00:00:00Z"
    done
}

@test "scan history applies Gregorian leap-year rules" {
    assert_history_timestamp_accepted "2024-02-29T00:00:00Z" "February"
    assert_history_timestamp_rejected "2026-02-29T00:00:00Z"
    assert_history_timestamp_accepted "2000-02-29T00:00:00Z" "February"
    assert_history_timestamp_rejected "1900-02-29T00:00:00Z"
}

@test "API timestamps accept the last real day of every month" {
    local day record_timestamp
    for day in 2026-01-31 2026-02-28 2026-03-31 2026-04-30 \
               2026-05-31 2026-06-30 2026-07-31 2026-08-31 \
               2026-09-30 2026-10-31 2026-11-30 2026-12-31; do
        record_timestamp="${day}T00:00:00+00:00"
        assert_api_timestamp_parsed "${day}T00:00:01Z" "$record_timestamp"
    done
}

@test "API timestamps reject September 31" {
    assert_api_timestamp_rejected "2026-09-31T00:00:01Z" "2026-09-30T00:00:00+00:00"
}

@test "API timestamps apply Gregorian leap-year rules" {
    assert_api_timestamp_parsed "2024-02-29T00:00:01Z" "2024-02-29T00:00:00+00:00"
    assert_api_timestamp_rejected "2026-02-29T00:00:01Z" "2026-02-28T00:00:00+00:00"
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

@test "record with unsafe integers is rejected before rounded agreement can pass" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":9007199254740993,"high":0,"medium":0,"low":0,"info":0},"alert_count":9007199254740992}'
}

@test "record with any count above the safe integer ceiling is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":1,"high":9007199254740992,"medium":0,"low":0,"info":0},"alert_count":9007199254740992}'
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

@test "trivy-utils self-test passes when executed directly" {
    run bash "$PROJECT_ROOT/helpers/trivy-utils.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All self-tests passed."* ]]
}
