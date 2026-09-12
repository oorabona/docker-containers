#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
    TEST_TEMP_DIR=$(mktemp -d)
    PROJECT_ROOT=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)
    CATEGORY='container-test-latest-linux/amd64'
    HISTORY_FILE="$TEST_TEMP_DIR/.trivy-scan-history/test-latest-linux-amd64.json"
    mkdir -p "$(dirname "$HISTORY_FILE")"
    SCRIPT_DIR="$TEST_TEMP_DIR"
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    _fetch_trivy_alerts_once() { :; }
    _TRIVY_FETCH_OUTCOME=ok
    _TRIVY_FETCHED_AT='2026-09-05T14:00:00Z'
    _TRIVY_SUMMARY_MAP='{}'
}

teardown() { rm -rf "$TEST_TEMP_DIR"; }

write_history_record() { printf '%s\n' "$1" > "$HISTORY_FILE"; }

set_api_entry() {
    _TRIVY_SUMMARY_MAP=$(jq -cn --arg category "$CATEGORY" --argjson entry "$1" '{$category: $entry}')
}

valid_code_scanning_summary() {
    printf '%s\n' '{"display_source":"code-scanning","last_scan":null,"as_of":"2026-09-05T14:00:00Z","counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-2026-0001","severity":"high","title":"Test advisory","package_name":"libtest"}],"scan_record":null,"code_scanning":{"fetched_at":"2026-09-05T14:00:00Z","counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-2026-0001","severity":"high","title":"Test advisory","package_name":"libtest"}]}}'
}

valid_scan_record_summary() {
    printf '%s\n' '{"display_source":"scan-record","last_scan":"2026-09-04T14:00:00Z","as_of":"2026-09-04T14:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":{"scan_at":"2026-09-04T14:00:00Z","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}},"code_scanning":null}'
}

assert_summary_valid() {
    run jq -e "$(trivy_summary_jq)"'trivy_summary_valid' <<<"$1"
    [ "$status" -eq 0 ]
}

assert_summary_rejected() {
    run jq -e "$(trivy_summary_jq)"'trivy_summary_valid | not' <<<"$1"
    [ "$status" -eq 0 ]
}

assert_history_rejected() {
    local record="$1"
    write_history_record "$record"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.scan_record == null' <<<"$output"
    [ "$status" -eq 0 ]
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

run_record_parser_failure_with_errexit() {
    local inherit_errexit="$1"

    run bash -c '
        set -e
        if [[ "$1" == "enabled" ]]; then
            shopt -s inherit_errexit
        else
            shopt -u inherit_errexit
        fi

        project_root="$2"
        history_file="$3"
        category="$4"
        source "$project_root/helpers/trivy-utils.sh"
        SCRIPT_DIR=$(dirname "$(dirname "$history_file")")
        _fetch_trivy_alerts_once() { :; }
        _TRIVY_FETCH_OUTCOME=ok
        _TRIVY_FETCHED_AT=2026-09-05T14:00:00Z
        _TRIVY_SUMMARY_MAP=$(command jq -nc --arg category "$category" \
            '\''{$category: {counts: {critical: 0, high: 1, medium: 0, low: 0, info: 0}, top_advisories: []}}'\'')

        jq() {
            if [[ "$*" == *"def empty_counts:"* ]]; then
                return 1
            fi
            command jq "$@"
        }

        result=$(get_trivy_summary "$category")
        printf "%s\\n" "$result"
    ' _ "$inherit_errexit" "$PROJECT_ROOT" "$HISTORY_FILE" "$CATEGORY"
}

@test "a valid cross-subshell cache envelope is adopted without calling the API" {
    local cache_file="$TEST_TEMP_DIR/trivy-cache.json"
    local calls="$TEST_TEMP_DIR/gh-calls"
    local summary_map='{"container-test-latest-linux/amd64":{"counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[]}}'
    : > "$calls"
    jq -cn --argjson summary_map "$summary_map" \
        '{outcome: "ok", fetched_at: "2026-09-05T14:00:00Z", summary_map: $summary_map}' > "$cache_file"

    run bash -c '
        source "$1/helpers/trivy-utils.sh"
        TRIVY_CACHE_FILE="$2"
        calls="$3"
        expected_summary_map="$4"
        expected_outcome="$5"
        expected_fetched_at="$6"
        gh() { printf "x\\n" >> "$calls"; return 1; }
        unset _TRIVY_FETCH_OUTCOME _TRIVY_FETCHED_AT _TRIVY_SUMMARY_MAP
        _fetch_trivy_alerts_once
        if [[ "$_TRIVY_FETCH_OUTCOME" != "$expected_outcome" \
            || "$_TRIVY_FETCHED_AT" != "$expected_fetched_at" \
            || "$_TRIVY_SUMMARY_MAP" != "$expected_summary_map" ]]; then
            printf "FAIL: cache envelope was not adopted: outcome=%s fetched_at=%s summary_map=%s\\n" \
                "$_TRIVY_FETCH_OUTCOME" "$_TRIVY_FETCHED_AT" "$_TRIVY_SUMMARY_MAP" >&2
            exit 1
        fi
    ' _ "$PROJECT_ROOT" "$cache_file" "$calls" "$summary_map" ok '2026-09-05T14:00:00Z'

    [ "$status" -eq 0 ]
    [ -f "$calls" ]
    [ "$(wc -l < "$calls")" -eq 0 ]
}

@test "a malformed cross-subshell cache envelope is a cache miss" {
    local cache_file="$TEST_TEMP_DIR/trivy-cache.json"
    local calls="$TEST_TEMP_DIR/gh-calls"
    : > "$calls"
    printf '%s\n' '{"summary_map":{}}' > "$cache_file"

    run bash -c '
        source "$1/helpers/trivy-utils.sh"
        TRIVY_CACHE_FILE="$2"
        calls="$3"
        log_warning() { :; }
        gh() { printf "x\\n" >> "$calls"; return 1; }
        unset _TRIVY_FETCH_OUTCOME _TRIVY_FETCHED_AT _TRIVY_SUMMARY_MAP
        _fetch_trivy_alerts_once
    ' _ "$PROJECT_ROOT" "$cache_file" "$calls"

    [ "$status" -eq 0 ]
    [ -f "$calls" ]
    [ "$(wc -l < "$calls")" -eq 3 ]
}

@test "parser failure under inherited errexit retains the API result" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    run_record_parser_failure_with_errexit enabled

    [ "$status" -eq 0 ]
    run jq -e 'type == "object" and .scan_record == null and .display_source == "code-scanning" and .counts.high == 1' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "parser failure without inherited errexit retains the API result" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    run_record_parser_failure_with_errexit disabled

    [ "$status" -eq 0 ]
    run jq -e 'type == "object" and .scan_record == null and .display_source == "code-scanning" and .counts.high == 1' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "successful API zero observation beats a dirty record without discarding it" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"dirty","counts":{"critical":3,"high":0,"medium":0,"low":0,"info":0},"alert_count":3}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "code-scanning" and .counts.critical == 0 and .scan_record.counts.critical == 3 and .code_scanning.counts.critical == 0' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "unavailable API does not fabricate a zero observation" {
    _TRIVY_FETCH_OUTCOME=unavailable
    _TRIVY_FETCHED_AT=''

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "unavailable" and .display_source != "code-scanning" and .as_of == null and .code_scanning == null and .counts == {critical:0,high:0,medium:0,low:0,info:0}' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "a failing API call under errexit leaves the caller alive and unavailable" {
    run bash -c '
        set -euo pipefail
        source "$1/helpers/trivy-utils.sh"
        log_warning() { :; }
        gh() { printf "transport failure\\n" >&2; return 1; }
        _fetch_trivy_alerts_once
        printf "MARKER outcome=%s fetched_at=%s\\n" "$_TRIVY_FETCH_OUTCOME" "$_TRIVY_FETCHED_AT"
    ' _ "$PROJECT_ROOT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"MARKER outcome=unavailable fetched_at="* ]]
}

@test "stderr-file allocation failure is unavailable and never invokes gh" {
    local calls="$TEST_TEMP_DIR/gh-calls"
    : > "$calls"

    run bash -c '
        set -euo pipefail
        source "$1/helpers/trivy-utils.sh"
        calls="$2"
        log_warning() { :; }
        gh() { printf "x\\n" >> "$calls"; return 0; }
        mktemp() {
            if [[ "$1" == *trivy-gh-error* ]]; then
                return 1
            fi
            command mktemp "$@"
        }
        _fetch_trivy_alerts_once
        printf "outcome=%s fetched_at=%s\\n" "$_TRIVY_FETCH_OUTCOME" "$_TRIVY_FETCHED_AT"
    ' _ "$PROJECT_ROOT" "$calls"

    [ "$status" -eq 0 ]
    [ "$output" = "outcome=unavailable fetched_at=" ]
    [ "$(wc -l < "$calls")" -eq 0 ]
}

@test "zero-status object or empty API body is unavailable and preserves a dirty scan record" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00Z","status":"dirty","counts":{"critical":3,"high":0,"medium":0,"low":0,"info":0},"alert_count":3}'

    local body
    for body in '{}' ''; do
        run bash -c '
            set -euo pipefail
            source "$1/helpers/trivy-utils.sh"
            SCRIPT_DIR="$2"
            category="$3"
            body="$4"
            log_warning() { :; }
            gh() { printf "%s" "$body"; }
            get_trivy_summary "$category"
        ' _ "$PROJECT_ROOT" "$TEST_TEMP_DIR" "$CATEGORY" "$body"

        [ "$status" -eq 0 ]
        run jq -e '
            .display_source == "scan-record"
            and .code_scanning == null
            and .counts == {critical:3,high:0,medium:0,low:0,info:0}
            and .scan_record.counts == {critical:3,high:0,medium:0,low:0,info:0}
        ' <<<"$output"
        [ "$status" -eq 0 ]
    done
}

@test "advisories stay with the Code Scanning channel" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00+00:00","status":"dirty","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"alert_count":1}'
    set_api_entry '{"counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api","severity":"high","title":null,"package_name":null}]}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "code-scanning" and .top_advisories == .code_scanning.top_advisories' <<<"$output"
    [ "$status" -eq 0 ]

    _TRIVY_FETCH_OUTCOME=unavailable
    _TRIVY_FETCHED_AT=''
    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "scan-record" and .top_advisories == [] and .counts == .scan_record.counts' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "last_scan is never a Code Scanning fetch time" {
    set_api_entry '{"counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[]}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "code-scanning" and .last_scan == null and .as_of == .code_scanning.fetched_at' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "trivy_summary_valid enforces resolver display precedence and scan instants" {
    local scan_summary code_summary
    scan_summary=$(valid_scan_record_summary)
    code_summary=$(valid_code_scanning_summary)

    assert_summary_valid "$scan_summary"
    assert_summary_valid "$code_summary"

    # A scan-record display must not hide a successful Code Scanning channel.
    assert_summary_rejected "$(jq -c '.code_scanning = {fetched_at: "2026-09-05T14:00:00Z", counts: {critical: 0, high: 1, medium: 0, low: 0, info: 0}, top_advisories: []}' <<<"$scan_summary")"

    # last_scan is either the exact scan record instant, or null without one.
    assert_summary_rejected "$(jq -c '.last_scan = .code_scanning.fetched_at' <<<"$code_summary")"
    assert_summary_rejected "$(jq -c '.last_scan = "2026-09-04T14:00:01Z"' <<<"$scan_summary")"
}

@test "trivy_summary_valid bounds the combined severity total to JavaScript's safe integer ceiling" {
    local code_summary exact_total unsafe_total
    code_summary=$(valid_code_scanning_summary)

    exact_total=$(jq -c '
        .counts = {critical: 9007199254740991, high: 0, medium: 0, low: 0, info: 0}
        | .code_scanning.counts = .counts
    ' <<<"$code_summary")
    unsafe_total=$(jq -c '
        .counts = {critical: 9007199254740991, high: 1, medium: 0, low: 0, info: 0}
        | .code_scanning.counts = .counts
    ' <<<"$code_summary")

    assert_summary_valid "$exact_total"
    assert_summary_rejected "$unsafe_total"
}

@test "trivy_summary_valid bounds Code Scanning advisories by resolver output" {
    local code_summary zero_total_one_advisory six_advisories five_advisories two_advisories
    code_summary=$(valid_code_scanning_summary)

    zero_total_one_advisory=$(jq -c '
        .counts = {critical: 0, high: 0, medium: 0, low: 0, info: 0}
        | .code_scanning.counts = .counts
    ' <<<"$code_summary")
    six_advisories=$(jq -c '
        .counts = {critical: 10, high: 0, medium: 0, low: 0, info: 0}
        | .code_scanning.counts = .counts
        | .top_advisories[0] as $advisory
        | .top_advisories = [range(0; 6) | $advisory]
        | .code_scanning.top_advisories = .top_advisories
    ' <<<"$code_summary")
    five_advisories=$(jq -c '
        .counts = {critical: 10, high: 0, medium: 0, low: 0, info: 0}
        | .code_scanning.counts = .counts
        | .top_advisories[0] as $advisory
        | .top_advisories = [range(0; 5) | $advisory]
        | .code_scanning.top_advisories = .top_advisories
    ' <<<"$code_summary")
    two_advisories=$(jq -c '
        .counts = {critical: 2, high: 0, medium: 0, low: 0, info: 0}
        | .code_scanning.counts = .counts
        | .top_advisories[0] as $advisory
        | .top_advisories = [range(0; 2) | $advisory]
        | .code_scanning.top_advisories = .top_advisories
    ' <<<"$code_summary")

    assert_summary_rejected "$zero_total_one_advisory"
    assert_summary_rejected "$six_advisories"
    assert_summary_valid "$five_advisories"
    assert_summary_valid "$two_advisories"
}

@test "trivy_summary_valid rejects malformed timestamps and advisory rows" {
    local code_summary
    code_summary=$(valid_code_scanning_summary)

    assert_summary_valid "$code_summary"
    assert_summary_rejected "$(jq -c '.as_of = "not-a-time" | .code_scanning.fetched_at = "not-a-time"' <<<"$code_summary")"

    # Rows are checked at both the displayed and nested channel positions.
    assert_summary_rejected "$(jq -c '.top_advisories = [null] | .code_scanning.top_advisories = [null]' <<<"$code_summary")"
    assert_summary_rejected "$(jq -c '.top_advisories = [{rule_id: "CVE", severity: 3, title: null, package_name: null}] | .code_scanning.top_advisories = [{rule_id: "CVE", severity: 3, title: null, package_name: null}]' <<<"$code_summary")"

    # Cached-map entries use the same row predicate before becoming a channel.
    set_api_entry '{"counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[null]}'
    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "unavailable" and .code_scanning == null' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "fetched_at is captured before Code Scanning summarisation" {
    local marker="$TEST_TEMP_DIR/summarisation-started"

    run bash -c '
        source "$1/helpers/trivy-utils.sh"
        marker="$2"
        log_warning() { :; }
        gh() {
            printf "[{\"rule\":{\"id\":\"CVE-1\",\"security_severity_level\":\"high\",\"description\":\"test\"},\"most_recent_instance\":{\"category\":\"container-test-latest-linux/amd64\",\"location\":{\"path\":\"pkg\"}}}]\\n"
        }
        date() {
            if [[ -e "$marker" ]]; then
                printf "2026-09-05T14:00:02Z\\n"
            else
                printf "2026-09-05T14:00:00Z\\n"
            fi
        }
        jq() {
            if [[ "$*" == *"def severity_bucket:"* ]]; then
                : > "$marker"
                sleep 2
            fi
            command jq "$@"
        }
        _fetch_trivy_alerts_once
        [[ "$_TRIVY_FETCH_OUTCOME" == ok && "$_TRIVY_FETCHED_AT" == "2026-09-05T14:00:00Z" ]]
    ' _ "$PROJECT_ROOT" "$marker"

    [ "$status" -eq 0 ]
    [ -e "$marker" ]
}

@test "an unknown -00:00 record offset retains the live API HIGH finding" {
    set_api_entry '{"counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-live-HIGH","severity":"high","title":null,"package_name":null}]}'
    write_history_record '{"last_scan":"2026-05-07T12:00:01-00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "code-scanning" and .counts.high == 1 and .scan_record.scan_at == "2026-05-07T12:00:01-00:00" and .scan_record.counts.high == 0' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "a stale clean cache record cannot hide a newer API HIGH finding" {
    local record_timestamp
    set_api_entry '{"last_scan":"2026-05-08T12:00:00Z","counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-TUESDAY-HIGH","severity":"high","title":null,"package_name":null}]}'

    for record_timestamp in 2026-05-07T12:00:00+00:00 2026-05-09T12:00:00+00:00; do
        write_history_record "{\"last_scan\":\"$record_timestamp\",\"status\":\"clean\",\"counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"info\":0},\"alert_count\":0}"

        run get_trivy_summary "$CATEGORY"
        [ "$status" -eq 0 ]
        run jq -e --arg timestamp "$record_timestamp" '
            .display_source == "code-scanning"
            and .counts.high == 1
            and .top_advisories[0].rule_id == "CVE-TUESDAY-HIGH"
            and .scan_record.scan_at == $timestamp
        ' <<<"$output"
        [ "$status" -eq 0 ]
    done
}

@test "pre-fix dated error record is rejected" {
    write_history_record '{"last_scan":"2026-12-01T00:00:00+00:00","status":"error","alert_count":-1,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.scan_record == null' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "otherwise coherent error status is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"error","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
}

@test "post-fix undated error record is rejected" {
    write_history_record '{"status":"error","alert_count":-1,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.scan_record == null' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "dated record without status is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","counts":{"critical":0}}'
}

@test "usable dirty record remains in scan_record while Code Scanning displays" {
    write_history_record '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{"critical":7,"high":4,"medium":0,"low":0,"info":0},"alert_count":11}'
    set_api_entry '{"counts":{"critical":0,"high":1,"medium":0,"low":0,"info":0},"top_advisories":[{"rule_id":"CVE-api","severity":"high","title":null,"package_name":null}]}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "code-scanning"
        and .counts == {critical:0,high:1,medium:0,low:0,info:0}
        and .scan_record.scan_at == "2026-12-01T00:00:00+00:00"
        and .scan_record.counts == {critical:7,high:4,medium:0,low:0,info:0}' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "legacy record without counts normalizes critical-only scan record" {
    write_history_record '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","alert_count":2}'

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.scan_record.scan_at == "2026-12-01T00:00:00+00:00"
        and .scan_record.counts == {critical:2,high:0,medium:0,low:0,info:0}' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "legacy dirty record with zero alerts is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","alert_count":0}'
}

@test "legacy clean record with alerts is rejected" {
    assert_history_rejected '{"last_scan":"2026-12-01T00:00:00+00:00","status":"clean","alert_count":5}'
}

@test "unrecognised transport and authentication failures are retried" {
    local calls="$TEST_TEMP_DIR/gh-calls"
    : > "$calls"
    run bash -c '
        source "$1/helpers/trivy-utils.sh"
        SCRIPT_DIR="$2"
        calls="$3"
        log_warning() { :; }
        sleep() { :; }
        gh() { printf "x\n" >> "$calls"; printf "diagnostic de transport non classifie\\n" >&2; return 1; }
        get_trivy_summary "$4"
    ' _ "$PROJECT_ROOT" "$TEST_TEMP_DIR" "$calls" "$CATEGORY"
    [ "$status" -eq 0 ]
    local transport_calls
    transport_calls=$(wc -l < "$calls")
    if [ "$transport_calls" -ne 3 ]; then
        printf 'FAIL: expected three unrecognised transport calls, got %s\n' "$transport_calls" >&2
        return 1
    fi
    run jq -e '.display_source == "unavailable" and .code_scanning == null' <<<"$output"
    [ "$status" -eq 0 ]

    : > "$calls"
    run bash -c '
        source "$1/helpers/trivy-utils.sh"
        SCRIPT_DIR="$2"
        calls="$3"
        log_warning() { :; }
        gh() { printf "x\n" >> "$calls"; printf "HTTP 401: Bad credentials\\n" >&2; return 1; }
        get_trivy_summary "$4"
    ' _ "$PROJECT_ROOT" "$TEST_TEMP_DIR" "$calls" "$CATEGORY"
    [ "$status" -eq 0 ]
    local authentication_calls
    authentication_calls=$(wc -l < "$calls")
    if [ "$authentication_calls" -ne 3 ]; then
        printf 'FAIL: expected three authentication calls, got %s\n' "$authentication_calls" >&2
        return 1
    fi
    run jq -e '.display_source == "unavailable" and .code_scanning == null' <<<"$output"
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
    printf '%s\n%s\n' \
        '{"last_scan":"2026-12-01T00:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}' \
        '{"last_scan":"2026-12-02T00:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}' \
        > "$HISTORY_FILE"

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.scan_record == null' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "scan-history accepts producer metadata keys and preserves normalized counts" {
    write_history_record '{"last_scan":"2026-05-07T12:00:00Z","status":"dirty","counts":{"critical":1,"high":2,"medium":0,"low":0,"info":0},"alert_count":3,"scanned_severities":["CRITICAL","HIGH"]}'
    _TRIVY_FETCH_OUTCOME=unavailable
    _TRIVY_FETCHED_AT=''

    run get_trivy_summary "$CATEGORY"
    [ "$status" -eq 0 ]
    run jq -e '.display_source == "scan-record" and .last_scan == "2026-05-07T12:00:00Z" and .counts == {critical:1,high:2,medium:0,low:0,info:0}' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "trivy-utils self-test passes when executed directly" {
    run bash "$PROJECT_ROOT/helpers/trivy-utils.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All self-tests passed."* ]]
}
