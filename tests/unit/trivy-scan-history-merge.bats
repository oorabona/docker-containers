#!/usr/bin/env bats

# Exercise the workflow's extracted merge step over real scan-history files.

setup() {
    TEST_TEMP_DIR=$(mktemp -d)
    ORIG_DIR=$PWD
    PROJECT_ROOT=$(cd "$ORIG_DIR" && pwd)
    cd "$TEST_TEMP_DIR" || exit 1

    yq -r '.jobs.cache-lineage.steps[] | select(.name == "Merge Trivy scan history files") | .run' \
        "$PROJECT_ROOT/.github/workflows/auto-build.yaml" > merge-trivy-history.sh
    chmod +x merge-trivy-history.sh
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_TEMP_DIR"
}

@test "merge skips an undated record and preserves the cached usable record" {
    mkdir -p .trivy-scan-history .trivy-scan-history-artifacts/nested
    printf '%s\n' '{"last_scan":"2026-01-01T00:00:00+00:00","status":"clean"}' \
        > .trivy-scan-history/existing.json
    printf '%s\n' '{"last_scan":"2026-02-01T00:00:00+00:00","status":"dirty"}' \
        > .trivy-scan-history-artifacts/nested/usable.json
    printf '%s\n' '{"status":"error","alert_count":-1}' \
        > .trivy-scan-history-artifacts/nested/existing.json

    run bash ./merge-trivy-history.sh
    [ "$status" -eq 0 ]
    [[ "$output" == *'Consolidated 1 Trivy scan history file(s); skipped 1 without last_scan'* ]]

    run jq -r '.last_scan' .trivy-scan-history/usable.json
    [ "$status" -eq 0 ]
    [ "$output" = '2026-02-01T00:00:00+00:00' ]

    run jq -r '.last_scan' .trivy-scan-history/existing.json
    [ "$status" -eq 0 ]
    [ "$output" = '2026-01-01T00:00:00+00:00' ]
}
