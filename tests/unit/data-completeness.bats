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
    [[ "$output" == *"Version 1.0 of phantom has no variants"* ]]
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

@test "verify-dashboard-data: missing counts in trivy_summary is flagged" {
    FIXTURE_NO_COUNTS="$PROJECT_ROOT/tests/fixtures/containers-trivy-no-counts.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_NO_COUNTS"
    # Advisory mode: exits 0 but must warn
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning"* ]]
    # Must mention trivy_summary and the affected container
    [[ "$output" == *"trivy_summary"* ]]
    [[ "$output" == *"myapp"* ]]
}

@test "verify-dashboard-data STRICT=1: missing counts in trivy_summary exits 1" {
    FIXTURE_NO_COUNTS="$PROJECT_ROOT/tests/fixtures/containers-trivy-no-counts.yml"
    STRICT=1 run "$VERIFY_SCRIPT" "$FIXTURE_NO_COUNTS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"trivy_summary"* ]]
}

@test "verify-dashboard-data: trivy_summary with last_scan + empty counts object is flagged" {
    tmpfile=$(mktemp --suffix=.yml)
    cat > "$tmpfile" <<'EOF'
- name: scanonly
  versions:
    - version: "2.0"
      variants:
        - name: base
          tag: 2.0-base
          is_default: true
          build_digest: "sha256:abcdef"
          attestation_url: "https://example.com/att/1"
          multi_arch_platforms:
            - linux/amd64
          sbom_summary:
            total_packages: 10
          trivy_summary:
            last_scan: "2026-05-01T10:00:00Z"
            counts: {}
EOF
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"
    # counts: {} lacks counts.critical — must be flagged
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning"* ]]
    [[ "$output" == *"trivy_summary"* ]]
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

@test "verify-dashboard-data: single-version container with empty variants[] flags <no-variants>" {
    FIXTURE_SINGLE_EMPTY="$PROJECT_ROOT/tests/fixtures/containers-single-version-empty.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_SINGLE_EMPTY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Container ghost (single-version) has no variants"* ]]
    ! [[ "$output" == *"Missing"*"real"* ]]
}

@test "verify-dashboard-data: has_variants:false fixture handles top-level fields" {
    FIXTURE_NO_VARIANTS="$PROJECT_ROOT/tests/fixtures/containers-no-variants.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_NO_VARIANTS"
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"Missing"*"standalone"* ]]
    [[ "$output" == *"Missing attestation_url for incomplete"* ]]
    [[ "$output" == *"Missing trivy_summary for incomplete"* ]]
    [[ "$output" == *"Missing sbom_summary for incomplete"* ]]
    [[ "$output" == *"top-level fields"* ]]
}
