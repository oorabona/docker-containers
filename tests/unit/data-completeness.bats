#!/usr/bin/env bats
# Tests for scripts/verify-dashboard-data.sh — smoke gate for containers.yml
# trust-strip data completeness.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify-dashboard-data.sh"
    FIXTURE_COMPLETE="$PROJECT_ROOT/tests/fixtures/containers-complete.yml"
    FIXTURE_MISSING="$PROJECT_ROOT/tests/fixtures/containers-missing.yml"
}

@test "verify-dashboard-data: complete fixture exits 0 with notice" {
    run "$VERIFY_SCRIPT" "$FIXTURE_COMPLETE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"All containers have complete"* ]]
}

@test "verify-dashboard-data: missing-fields fixture warns + exits 0 (advisory mode)" {
    run "$VERIFY_SCRIPT" "$FIXTURE_MISSING"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning"* ]]
    [[ "$output" == *"gap"* ]]
}

@test "verify-dashboard-data STRICT=1: missing-fields fixture exits 1" {
    STRICT=1 run "$VERIFY_SCRIPT" "$FIXTURE_MISSING"
    [ "$status" -eq 1 ]
}
