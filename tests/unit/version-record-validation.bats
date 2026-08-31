#!/usr/bin/env bats

# Unit tests for the shared destructive-cleanup configuration contract.

bats_require_minimum_version 1.7.0

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
}

@test "validate_cleanup_config rejects every non-canonical destructive setting" {
    local variable value expected

    while IFS='|' read -r variable value expected; do
        run env \
            DRY_RUN=false \
            KEEP_LATEST_COUNT=10 \
            KEEP_MONTHS=6 \
            "$variable=$value" \
            bash -c 'source "$1/helpers/version-record-validation.sh"; validate_cleanup_config' _ "$PROJECT_ROOT"

        [[ "$status" -eq 64 ]]
        [[ "$output" == "$expected" ]]
    done <<'CASES'
DRY_RUN|TRUE|cleanup configuration rejected: DRY_RUN must be exactly true or false
DRY_RUN|1|cleanup configuration rejected: DRY_RUN must be exactly true or false
DRY_RUN|yes|cleanup configuration rejected: DRY_RUN must be exactly true or false
DRY_RUN||cleanup configuration rejected: DRY_RUN must be exactly true or false
KEEP_LATEST_COUNT|-1|cleanup configuration rejected: KEEP_LATEST_COUNT must be 0 or [1-9][0-9]*
KEEP_MONTHS|-1|cleanup configuration rejected: KEEP_MONTHS must be 0 or [1-9][0-9]*
KEEP_LATEST_COUNT|06|cleanup configuration rejected: KEEP_LATEST_COUNT must be 0 or [1-9][0-9]*
KEEP_MONTHS|06|cleanup configuration rejected: KEEP_MONTHS must be 0 or [1-9][0-9]*
KEEP_LATEST_COUNT| 6|cleanup configuration rejected: KEEP_LATEST_COUNT must be 0 or [1-9][0-9]*
KEEP_MONTHS| 6|cleanup configuration rejected: KEEP_MONTHS must be 0 or [1-9][0-9]*
KEEP_LATEST_COUNT|6 months|cleanup configuration rejected: KEEP_LATEST_COUNT must be 0 or [1-9][0-9]*
KEEP_MONTHS|6 months|cleanup configuration rejected: KEEP_MONTHS must be 0 or [1-9][0-9]*
CASES
}

@test "validate_cleanup_config accepts documented dry-run and retention values" {
    local dry_run keep_latest_count keep_months

    while IFS='|' read -r dry_run keep_latest_count keep_months; do
        run env \
            DRY_RUN="$dry_run" \
            KEEP_LATEST_COUNT="$keep_latest_count" \
            KEEP_MONTHS="$keep_months" \
            bash -c 'source "$1/helpers/version-record-validation.sh"; validate_cleanup_config; [[ -n "$CUTOFF_DATE" && "$CUTOFF_TS" =~ ^-?[0-9]+$ ]]' _ "$PROJECT_ROOT"

        [[ "$status" -eq 0 ]]
        [[ -z "$output" ]]
    done <<'CASES'
true|0|0
false|0|0
true|10|10
false|10|10
CASES
}

@test "validate_cleanup_config accepts the executable retention maximum" {
    run env \
        DRY_RUN=false \
        KEEP_LATEST_COUNT=2147483647 \
        KEEP_MONTHS=2147483647 \
        bash -c 'source "$1/helpers/version-record-validation.sh"; validate_cleanup_config' _ "$PROJECT_ROOT"

    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "validate_cleanup_config rejects retention values above the executable maximum" {
    local variable value

    while IFS='|' read -r variable value; do
        run env \
            DRY_RUN=false \
            KEEP_LATEST_COUNT=10 \
            KEEP_MONTHS=6 \
            "$variable=$value" \
            bash -c 'source "$1/helpers/version-record-validation.sh"; validate_cleanup_config' _ "$PROJECT_ROOT"

        [[ "$status" -eq 64 ]]
        [[ "$output" == "cleanup configuration rejected: $variable must be between 0 and 2147483647" ]]
    done <<'CASES'
KEEP_LATEST_COUNT|2147483648
KEEP_MONTHS|2147483648
KEEP_LATEST_COUNT|9223372036854775808
KEEP_MONTHS|9223372036854775808
CASES
}

@test "validate_cleanup_config rejects a month count whose cutoff date is not representable" {
    local date_dir="$BATS_TEST_TMPDIR/unrepresentable-cutoff-date"
    mkdir -p "$date_dir"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$date_dir/date"
    chmod +x "$date_dir/date"

    run env \
        PATH="$date_dir:$PATH" \
        DRY_RUN=false \
        KEEP_LATEST_COUNT=10 \
        KEEP_MONTHS=6 \
        bash -c 'source "$1/helpers/version-record-validation.sh"; validate_cleanup_config' _ "$PROJECT_ROOT"

    [[ "$status" -eq 64 ]]
    [[ "$output" == "cleanup configuration rejected: KEEP_MONTHS must produce a representable cutoff" ]]
}

@test "destructive cleanup code has no configuration-validity marker" {
    run grep -rlZ 'CLEANUP_CONFIG_VALIDATED' \
        "$PROJECT_ROOT/helpers" \
        "$PROJECT_ROOT/scripts"

    [[ "$status" -eq 1 ]]
    [[ -z "$output" ]]
}

@test "validate_cleanup_config rejects each unset value under nounset with its documented status" {
    local variable expected

    while IFS='|' read -r variable expected; do
        run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
            set -u
            source "$PROJECT_ROOT/helpers/version-record-validation.sh"
            DRY_RUN=false KEEP_LATEST_COUNT=10 KEEP_MONTHS=6
            unset "$1"
            validate_cleanup_config
        ' _ "$variable"

        [[ "$status" -eq 64 ]]
        [[ "$output" == "$expected" ]]
    done <<'CASES'
DRY_RUN|cleanup configuration rejected: DRY_RUN must be exactly true or false
KEEP_LATEST_COUNT|cleanup configuration rejected: KEEP_LATEST_COUNT must be 0 or [1-9][0-9]*
KEEP_MONTHS|cleanup configuration rejected: KEEP_MONTHS must be 0 or [1-9][0-9]*
CASES
}
