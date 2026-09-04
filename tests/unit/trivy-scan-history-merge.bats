#!/usr/bin/env bats

# Exercise both workflows' extracted Trivy history merge loops over real files.

setup() {
    TEST_TEMP_DIR=$(mktemp -d)
    ORIG_DIR=$PWD
    PROJECT_ROOT=$(cd "$ORIG_DIR" && pwd)
    cd "$TEST_TEMP_DIR" || exit 1

    mkdir -p helpers
    cp "$PROJECT_ROOT/helpers/trivy-utils.sh" "$PROJECT_ROOT/helpers/logging.sh" helpers/
    yq -r '.jobs.cache-lineage.steps[] | select(.name == "Merge Trivy scan history files") | .run' \
        "$PROJECT_ROOT/.github/workflows/auto-build.yaml" > merge-auto-build.sh
    chmod +x merge-auto-build.sh

    yq -r '.jobs.build.steps[] | select(.name == "Hydrate Trivy scan history from recent auto-build runs (#352)") | .run' \
        "$PROJECT_ROOT/.github/workflows/update-dashboard.yaml" \
        | sed -n '/^merged=0$/,/^echo "::notice::Hydrated from /p' > merge-update-dashboard.sh
    chmod +x merge-update-dashboard.sh
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_TEMP_DIR"
}

valid_clean_record() {
    printf '%s' '{"last_scan":"2026-01-01T00:00:00+00:00","status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
}

valid_dirty_record() {
    local timestamp="$1"
    jq -nc --arg timestamp "$timestamp" \
        '{last_scan:$timestamp,status:"dirty",counts:{critical:1,high:0,medium:0,low:0,info:0},alert_count:1}'
}

run_merge() {
    local workflow="$1"
    if [[ "$workflow" == update-dashboard ]]; then
        staging=.trivy-scan-history-artifacts bash -e -o pipefail ./merge-update-dashboard.sh
    else
        bash -e -o pipefail ./merge-auto-build.sh
    fi
}

assert_merged_record_is_readable() {
    local category='container-new-latest-linux/amd64'
    SCRIPT_DIR=$PWD
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    _fetch_trivy_alerts_once() { :; }
    _TRIVY_SUMMARY_MAP=$(jq -nc --arg category "$category" \
        '{$category:{last_scan:"2026-01-01T00:00:00Z",counts:{critical:0,high:0,medium:0,low:0,info:0},top_advisories:[]}}')

    run get_trivy_summary "$category"
    [ "$status" -eq 0 ]
    run jq -e '.last_scan == "2026-03-01T00:00:00+00:00" and .counts.critical == 1' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "auto-build merge protects a usable target and replaces an unusable target" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested
    valid_clean_record > .trivy-scan-history/same-latest-linux-amd64.json
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{},"alert_count":0}' \
        > .trivy-scan-history-artifacts/nested/same-latest-linux-amd64.json
    printf '%s\n' '{"last_scan":"not-a-date","status":"error","alert_count":-1}' \
        > .trivy-scan-history/replace-latest-linux-amd64.json
    valid_dirty_record '2026-02-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/replace-latest-linux-amd64.json
    valid_dirty_record '2026-03-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/new-latest-linux-amd64.json
    printf '%s\n' '{"status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}' \
        > .trivy-scan-history-artifacts/nested/undated-latest-linux-amd64.json

    run run_merge auto-build
    [ "$status" -eq 0 ]
    [[ "$output" == *'Consolidated 2 Trivy scan history file(s); skipped 2 unusable record(s)'* ]]
    [ ! -e .trivy-scan-history/undated-latest-linux-amd64.json ]

    run jq -r '.last_scan' .trivy-scan-history/same-latest-linux-amd64.json
    [ "$output" = '2026-01-01T00:00:00+00:00' ]
    run jq -r '.last_scan' .trivy-scan-history/replace-latest-linux-amd64.json
    [ "$output" = '2026-02-01T00:00:00+00:00' ]
    assert_merged_record_is_readable
}

@test "update-dashboard merge protects a usable target and replaces an unusable target" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested
    valid_clean_record > .trivy-scan-history/same-latest-linux-amd64.json
    printf '%s\n' '{"last_scan":"2026-12-01T00:00:00+00:00","status":"dirty","counts":{},"alert_count":0}' \
        > .trivy-scan-history-artifacts/nested/same-latest-linux-amd64.json
    printf '%s\n' '{"last_scan":"not-a-date","status":"error","alert_count":-1}' \
        > .trivy-scan-history/replace-latest-linux-amd64.json
    valid_dirty_record '2026-02-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/replace-latest-linux-amd64.json
    valid_dirty_record '2026-03-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/new-latest-linux-amd64.json
    printf '%s\n' '{"status":"clean","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}' \
        > .trivy-scan-history-artifacts/nested/undated-latest-linux-amd64.json

    run run_merge update-dashboard
    [ "$status" -eq 0 ]
    [[ "$output" == *'merged 2 file(s); skipped 2 unusable or older record(s)'* ]]
    [ ! -e .trivy-scan-history/undated-latest-linux-amd64.json ]

    run jq -r '.last_scan' .trivy-scan-history/same-latest-linux-amd64.json
    [ "$output" = '2026-01-01T00:00:00+00:00' ]
    run jq -r '.last_scan' .trivy-scan-history/replace-latest-linux-amd64.json
    [ "$output" = '2026-02-01T00:00:00+00:00' ]
    assert_merged_record_is_readable
}

@test "auto-build merge skips an undated source sharing a usable target basename" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested
    valid_dirty_record '2026-01-01T00:00:00+00:00' > .trivy-scan-history/collision-latest-linux-amd64.json
    cp .trivy-scan-history/collision-latest-linux-amd64.json expected.json
    printf '%s\n' '{"status":"error","alert_count":-1,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}}' \
        > .trivy-scan-history-artifacts/nested/collision-latest-linux-amd64.json

    run run_merge auto-build
    [ "$status" -eq 0 ]
    run cmp expected.json .trivy-scan-history/collision-latest-linux-amd64.json
    [ "$status" -eq 0 ]
}

@test "update-dashboard merge skips an undated source sharing a usable target basename" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested
    valid_dirty_record '2026-01-01T00:00:00+00:00' > .trivy-scan-history/collision-latest-linux-amd64.json
    cp .trivy-scan-history/collision-latest-linux-amd64.json expected.json
    printf '%s\n' '{"status":"error","alert_count":-1,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0}}' \
        > .trivy-scan-history-artifacts/nested/collision-latest-linux-amd64.json

    run run_merge update-dashboard
    [ "$status" -eq 0 ]
    run cmp expected.json .trivy-scan-history/collision-latest-linux-amd64.json
    [ "$status" -eq 0 ]
}

@test "auto-build merge fails before its success notice when find fails partway" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested fail-find
    valid_dirty_record '2026-01-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/find-failure-latest-linux-amd64.json
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == ".trivy-scan-history-artifacts" ]]; then' \
        "  printf '%s\\0' '.trivy-scan-history-artifacts/nested/find-failure-latest-linux-amd64.json'" \
        '  exit 42' \
        'fi' \
        'exec /usr/bin/find "$@"' > fail-find/find
    chmod +x fail-find/find

    run env PATH="$PWD/fail-find:$PATH" bash -e -o pipefail ./merge-auto-build.sh
    [ "$status" -ne 0 ]
    [[ "$output" != *'Consolidated '* ]]
}

@test "update-dashboard merge fails before its success notice when find fails partway" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested fail-find
    valid_dirty_record '2026-01-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/find-failure-latest-linux-amd64.json
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == ".trivy-scan-history-artifacts" ]]; then' \
        "  printf '%s\\0' '.trivy-scan-history-artifacts/nested/find-failure-latest-linux-amd64.json'" \
        '  exit 42' \
        'fi' \
        'exec /usr/bin/find "$@"' > fail-find/find
    chmod +x fail-find/find

    run env PATH="$PWD/fail-find:$PATH" staging=.trivy-scan-history-artifacts bash -e -o pipefail ./merge-update-dashboard.sh
    [ "$status" -ne 0 ]
    [[ "$output" != *'::notice::Hydrated from '* ]]
}

@test "auto-build merge keeps the prior target intact when copy truncates then fails" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested fail-copy
    valid_dirty_record '2026-01-01T00:00:00+00:00' \
        > .trivy-scan-history/same-latest-linux-amd64.json
    valid_dirty_record '2026-01-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/same-latest-linux-amd64.json
    cp .trivy-scan-history/same-latest-linux-amd64.json expected.json
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'target="${!#}"' \
        "printf '%s' partial > \"\$target\"" \
        'exit 42' > fail-copy/cp
    chmod +x fail-copy/cp

    run env PATH="$PWD/fail-copy:$PATH" bash -e -o pipefail ./merge-auto-build.sh
    [ "$status" -ne 0 ]
    [[ "$output" != *'Consolidated '* ]]
    run cmp expected.json .trivy-scan-history/same-latest-linux-amd64.json
    [ "$status" -eq 0 ]
}

@test "update-dashboard merge keeps the prior target intact when copy truncates then fails" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested fail-copy
    valid_dirty_record '2026-01-01T00:00:00+00:00' \
        > .trivy-scan-history/same-latest-linux-amd64.json
    valid_dirty_record '2026-02-01T00:00:00+00:00' \
        > .trivy-scan-history-artifacts/nested/same-latest-linux-amd64.json
    cp .trivy-scan-history/same-latest-linux-amd64.json expected.json
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'target="${!#}"' \
        "printf '%s' partial > \"\$target\"" \
        'exit 42' > fail-copy/cp
    chmod +x fail-copy/cp

    run env PATH="$PWD/fail-copy:$PATH" staging=.trivy-scan-history-artifacts bash -e -o pipefail ./merge-update-dashboard.sh
    [ "$status" -ne 0 ]
    [[ "$output" != *'::notice::Hydrated from '* ]]
    run cmp expected.json .trivy-scan-history/same-latest-linux-amd64.json
    [ "$status" -eq 0 ]
}
