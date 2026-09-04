#!/usr/bin/env bats

# Exercise the composite action's extracted writer, as GitHub Actions executes it.

setup() {
    TEST_TEMP_DIR=$(mktemp -d)
    ORIG_DIR=$PWD
    PROJECT_ROOT=$(cd "$ORIG_DIR" && pwd)
    cd "$TEST_TEMP_DIR" || exit 1

    mkdir -p .github/actions/build-container
    cp "$PROJECT_ROOT/.github/actions/build-container/action.yaml" \
        .github/actions/build-container/action.yaml
    yq -r '.runs.steps[] | select(.id == "write-trivy-history") | .run' \
        .github/actions/build-container/action.yaml > write-trivy-history.sh
    chmod +x write-trivy-history.sh
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_TEMP_DIR"
}

run_writer() {
    VULNERABILITY_SEVERITY='UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL' \
        CONTAINER=test CURRENT_TAG=latest PLATFORM=linux/amd64 \
        bash ./write-trivy-history.sh
}

scan_file() {
    echo '.trivy-scan-history/test-latest-linux-amd64.json'
}

@test "real clean Trivy SARIF writes a dated clean record" {
    cp "$PROJECT_ROOT/tests/fixtures/trivy-sarif-clean.json" trivy-results.sarif

    run run_writer
    [ "$status" -eq 0 ]

    run jq -e '.status == "clean" and .alert_count == 0
        and .counts == {"critical":0,"high":0,"medium":0,"low":0,"info":0}
        and has("last_scan")' "$(scan_file)"
    [ "$status" -eq 0 ]

    last_scan=$(jq -r '.last_scan' "$(scan_file)")
    run date -d "$last_scan" +%s
    [ "$status" -eq 0 ]
}

@test "real findings Trivy SARIF writes a dirty normalized record" {
    cp "$PROJECT_ROOT/tests/fixtures/trivy-sarif-findings.json" trivy-results.sarif

    run run_writer
    [ "$status" -eq 0 ]

    run jq -e '.status == "dirty" and .alert_count == 2
        and .counts == {"critical":0,"high":1,"medium":1,"low":0,"info":0}' \
        "$(scan_file)"
    [ "$status" -eq 0 ]
}

@test "structurally incomplete SARIF writes an undated error record" {
    printf '%s\n' '{"runs":[{"results":[]}]}' > trivy-results.sarif

    run run_writer
    [ "$status" -eq 0 ]

    run jq -e '.status == "error" and .alert_count == -1 and has("last_scan") == false' \
        "$(scan_file)"
    [ "$status" -eq 0 ]
}

@test "absent SARIF writes an undated error record" {
    run run_writer
    [ "$status" -eq 0 ]

    run jq -e '.status == "error" and .alert_count == -1 and has("last_scan") == false' \
        "$(scan_file)"
    [ "$status" -eq 0 ]
}
