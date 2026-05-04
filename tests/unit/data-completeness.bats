#!/usr/bin/env bats
# Tests for scripts/verify-dashboard-data.sh — smoke gate for containers.yml
# trust-strip data completeness.

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify-dashboard-data.sh"
    FIXTURE_COMPLETE="$PROJECT_ROOT/tests/fixtures/containers-complete.yml"
    FIXTURE_MISSING="$PROJECT_ROOT/tests/fixtures/containers-missing.yml"
    FIXTURE_MULTI_VARIANT="$PROJECT_ROOT/tests/fixtures/containers-multi-variant.yml"
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

@test "verify-dashboard-data: multi-variant fixture flags non-default variant gaps" {
    run "$VERIFY_SCRIPT" "$FIXTURE_MULTI_VARIANT"
    [ "$status" -eq 0 ]
    # Should warn for at least 3 distinct field gaps across non-default variants
    warning_count=$(echo "$output" | grep -c "::warning file=")
    [ "$warning_count" -ge 3 ]
    # Should explicitly mention non-default variant paths
    [[ "$output" == *"variants[1]"* || "$output" == *"variants[0])"* ]] || [[ "$output" == *"versions[1]"* ]]
}

@test "verify-dashboard-data STRICT=1: multi-variant fixture exits 1 on non-default gaps" {
    STRICT=1 run "$VERIFY_SCRIPT" "$FIXTURE_MULTI_VARIANT"
    [ "$status" -eq 1 ]
}

@test "verify-dashboard-data: empty-versions fixture flags <no-versions> and <no-variants> sentinels" {
    FIXTURE_EMPTY_VERSIONS="$PROJECT_ROOT/tests/fixtures/containers-empty-versions.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_EMPTY_VERSIONS"
    [ "$status" -eq 0 ]
    # Both sentinels should fire
    [[ "$output" == *"No versions found for lonely"* ]]
    [[ "$output" == *"Version 0 of phantom has no variants"* ]]
    # Healthy container should NOT trigger any warning
    ! [[ "$output" == *"Missing"*"healthy"* ]]
    ! [[ "$output" == *"No versions"*"healthy"* ]]
}

@test "verify-dashboard-data: single-version fixture detects top-level variants" {
    FIXTURE_SINGLE="$PROJECT_ROOT/tests/fixtures/containers-single-version.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_SINGLE"
    [ "$status" -eq 0 ]
    # 'simple' is fully populated → no warning for it
    ! [[ "$output" == *"Missing"*"simple"* ]]
    # 'partial' is missing attestation_url and trivy_summary → warnings expected
    [[ "$output" == *"Missing attestation_url for partial"* ]]
    [[ "$output" == *"Missing trivy_summary for partial"* ]]
    # Warnings must indicate the single-version path (not versions[N].variants[N])
    [[ "$output" == *"single-version"* ]]
}

@test "verify-dashboard-data: malformed YAML exits 2 with ::error::" {
    tmpfile=$(mktemp --suffix=.yml)
    printf 'foo: [unclosed array\nbar: {malformed\n' > "$tmpfile"
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"
    [ "$status" -eq 2 ]
    [[ "$output" == *"::error"* ]]
    [[ "$output" == *"yq failed to parse"* ]]
}

@test "verify-dashboard-data: non-array root YAML exits 2 with ::error::" {
    tmpfile=$(mktemp --suffix=.yml)
    printf '42\n' > "$tmpfile"
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"
    [ "$status" -eq 2 ]
    [[ "$output" == *"::error"* ]]
    [[ "$output" == *"expected top-level YAML sequence"* ]]
}
