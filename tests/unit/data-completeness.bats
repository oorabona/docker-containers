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
    FIXTURE_TRIVY_NO_COUNTS="$PROJECT_ROOT/tests/fixtures/containers-trivy-no-counts.yml"
    FIXTURE_TRIVY_NO_SCAN_RECORD_COUNTS="$PROJECT_ROOT/tests/fixtures/containers-trivy-no-scan-record-counts.yml"
    FIXTURE_TRIVY_EMPTY_COUNTS="$PROJECT_ROOT/tests/fixtures/containers-trivy-empty-counts.yml"
}

trivy_summary_from_fixture() {
    local fixture="$1"
    local container_index="$2"

    yq -o=json ".[$container_index].versions[0].variants[0].trivy_summary" "$fixture"
}

assert_trivy_summary_valid() {
    local summary="$1"

    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    run jq -e "$(trivy_summary_jq)"'trivy_summary_valid' <<<"$summary"
    [ "$status" -eq 0 ]
}

assert_trivy_summary_rejected() {
    local summary="$1"

    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    run jq -e "$(trivy_summary_jq)"'trivy_summary_valid | not' <<<"$summary"
    [ "$status" -eq 0 ]
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
    ! [[ "$output" == *"No versions found for healthy"* ]]
}

@test "verify-dashboard-data: single-version fixture detects top-level variants" {
    FIXTURE_SINGLE="$PROJECT_ROOT/tests/fixtures/containers-single-version.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_SINGLE"
    [ "$status" -eq 0 ]
    # The fixture deliberately retains the legacy Trivy shape, so only its
    # trivy_summary is a gap; its other single-version fields remain complete.
    [[ "$output" == *"Missing trivy_summary for simple"* ]]
    ! [[ "$output" == *"Missing attestation_url for simple"* ]]
    ! [[ "$output" == *"Missing sbom_summary for simple"* ]]
    # 'partial' is missing attestation_url and trivy_summary → warnings expected
    [[ "$output" == *"Missing attestation_url for partial"* ]]
    [[ "$output" == *"Missing trivy_summary for partial"* ]]
    # Warnings must indicate the single-version path (not versions[N].variants[N])
    [[ "$output" == *"single-version"* ]]
}

@test "verify-dashboard-data: missing top-level trivy counts is flagged" {
    local summary repaired_summary
    summary=$(trivy_summary_from_fixture "$FIXTURE_TRIVY_NO_COUNTS" 0)
    repaired_summary=$(jq -c '.counts = {critical: 0, high: 0, medium: 0, low: 0, info: 0}' <<<"$summary")

    assert_trivy_summary_rejected "$summary"
    assert_trivy_summary_valid "$repaired_summary"

    run "$VERIFY_SCRIPT" "$FIXTURE_TRIVY_NO_COUNTS"
    # Advisory mode: exits 0 but must warn
    [ "$status" -eq 0 ]
    [[ "$output" == *"Missing trivy_summary for top-counts-missing variant 1.0-top-counts"* ]]
}

@test "verify-dashboard-data STRICT=1: missing scan-record trivy counts exits 1" {
    local summary repaired_summary
    summary=$(trivy_summary_from_fixture "$FIXTURE_TRIVY_NO_SCAN_RECORD_COUNTS" 0)
    repaired_summary=$(jq -c '.scan_record.counts = {critical: 0, high: 0, medium: 0, low: 0, info: 0}' <<<"$summary")

    assert_trivy_summary_rejected "$summary"
    assert_trivy_summary_valid "$repaired_summary"

    STRICT=1 run "$VERIFY_SCRIPT" "$FIXTURE_TRIVY_NO_SCAN_RECORD_COUNTS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing trivy_summary for scan-record-counts-missing variant 1.0-scan-record-counts"* ]]
}

@test "verify-dashboard-data: trivy_summary with display_source + empty counts object is flagged" {
    local empty_summary control_summary
    empty_summary=$(trivy_summary_from_fixture "$FIXTURE_TRIVY_EMPTY_COUNTS" 0)
    control_summary=$(trivy_summary_from_fixture "$FIXTURE_TRIVY_EMPTY_COUNTS" 1)

    assert_trivy_summary_valid "$control_summary"
    run jq -en --argjson empty "$empty_summary" --argjson control "$control_summary" '
        ($empty | del(.counts, .scan_record.counts)) == ($control | del(.counts, .scan_record.counts))
    '
    [ "$status" -eq 0 ]
    assert_trivy_summary_rejected "$empty_summary"

    run "$VERIFY_SCRIPT" "$FIXTURE_TRIVY_EMPTY_COUNTS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Missing trivy_summary for empty-counts variant 2.0-empty-counts"* ]]
    ! [[ "$output" == *"Missing trivy_summary for empty-counts-control variant 2.0-empty-counts-control"* ]]
}

@test "the canonical unavailable Trivy summary satisfies the evidence validator" {
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    run jq -e "$(trivy_summary_jq)"'trivy_summary_valid' <<<"$_TRIVY_EMPTY"
    [ "$status" -eq 0 ]
}

@test "verify-dashboard-data: canonical unavailable Trivy summary is a gap" {
    tmpfile=$(mktemp --suffix=.yml)
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    printf '%s\n' \
'- name: evidence-state' \
'  versions:' \
'    - version: "2.0"' \
'      variants:' \
'        - name: unavailable' \
'          tag: 2.0-unavailable' \
'          is_default: true' \
'          attestation_url: "https://example.com/att/unavailable"' \
'          multi_arch_platforms: [linux/amd64]' \
'          sbom_summary:' \
'            total_packages: 10' \
"          trivy_summary: $_TRIVY_EMPTY" > "$tmpfile"
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Missing trivy_summary for evidence-state variant 2.0-unavailable"* ]]
}

@test "verify-dashboard-data: Code Scanning without last_scan is complete" {
    tmpfile=$(mktemp --suffix=.yml)
    cat > "$tmpfile" <<'EOF'
- name: evidence-state
  versions:
    - version: "2.0"
      variants:
        - name: code-scanning
          tag: 2.0-code-scanning
          is_default: true
          attestation_url: "https://example.com/att/code-scanning"
          multi_arch_platforms: [linux/amd64]
          sbom_summary:
            total_packages: 10
          trivy_summary:
            display_source: "code-scanning"
            last_scan: null
            as_of: "2026-05-01T00:00:00Z"
            counts:
              critical: 1
              high: 0
              medium: 0
              low: 0
              info: 0
            top_advisories: []
            scan_record: null
            code_scanning:
              fetched_at: "2026-05-01T00:00:00Z"
              counts:
                critical: 1
                high: 0
                medium: 0
                low: 0
                info: 0
              top_advisories: []
EOF
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"
    [ "$status" -eq 0 ]
    ! [[ "$output" == *"Missing trivy_summary for evidence-state variant 2.0-code-scanning"* ]]
}

@test "verify-dashboard-data: malformed Trivy evidence is a gap in every schema path" {
    tmpfile=$(mktemp --suffix=.yml)
    cat > "$tmpfile" <<'EOF'
- name: nonvariant
  has_variants: false
  attestation_url: "https://example.com/att/nonvariant"
  multi_arch_platforms: [linux/amd64]
  sbom_summary: {total_packages: 1}
  trivy_summary: {display_source: "bogus", counts: {critical: 0, high: "2"}}
- name: multiversion
  versions:
    - version: "1"
      variants:
        - name: base
          tag: 1-base
          attestation_url: "https://example.com/att/multi"
          multi_arch_platforms: [linux/amd64]
          sbom_summary: {total_packages: 1}
          trivy_summary: {display_source: "bogus", counts: {critical: 0, high: "2"}}
- name: singleversion
  variants:
    - name: base
      tag: 1-base
      attestation_url: "https://example.com/att/single"
      multi_arch_platforms: [linux/amd64]
      sbom_summary: {total_packages: 1}
      trivy_summary: {display_source: "bogus", counts: {critical: 0, high: "2"}}
EOF
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Missing trivy_summary for nonvariant"* ]]
    [[ "$output" == *"Missing trivy_summary for multiversion variant 1-base"* ]]
    [[ "$output" == *"Missing trivy_summary for singleversion variant 1-base"* ]]
}

@test "verify-dashboard-data: a scan record hiding Code Scanning is a gap in every schema path" {
    tmpfile=$(mktemp --suffix=.yml)
    cat > "$tmpfile" <<'EOF'
- name: nonvariant
  has_variants: false
  attestation_url: "https://example.com/att/nonvariant"
  multi_arch_platforms: [linux/amd64]
  sbom_summary: {total_packages: 1}
  trivy_summary: &hidden_code_scanning
    display_source: "scan-record"
    last_scan: "2026-09-04T00:00:00Z"
    as_of: "2026-09-04T00:00:00Z"
    counts: {critical: 0, high: 0, medium: 0, low: 0, info: 0}
    top_advisories: []
    scan_record:
      scan_at: "2026-09-04T00:00:00Z"
      counts: {critical: 0, high: 0, medium: 0, low: 0, info: 0}
    code_scanning:
      fetched_at: "2026-09-05T00:00:00Z"
      counts: {critical: 0, high: 1, medium: 0, low: 0, info: 0}
      top_advisories: []
- name: multiversion
  versions:
    - version: "1"
      variants:
        - name: base
          tag: 1-base
          attestation_url: "https://example.com/att/multi"
          multi_arch_platforms: [linux/amd64]
          sbom_summary: {total_packages: 1}
          trivy_summary: *hidden_code_scanning
- name: singleversion
  variants:
    - name: base
      tag: 1-base
      attestation_url: "https://example.com/att/single"
      multi_arch_platforms: [linux/amd64]
      sbom_summary: {total_packages: 1}
      trivy_summary: *hidden_code_scanning
EOF
    run "$VERIFY_SCRIPT" "$tmpfile"
    rm -f "$tmpfile"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Missing trivy_summary for nonvariant"* ]]
    [[ "$output" == *"Missing trivy_summary for multiversion variant 1-base"* ]]
    [[ "$output" == *"Missing trivy_summary for singleversion variant 1-base"* ]]
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
    # The fixture deliberately retains the legacy Trivy shape, so only its
    # trivy_summary is a gap; its other single-version fields remain complete.
    [[ "$output" == *"Missing trivy_summary for real"* ]]
    ! [[ "$output" == *"Missing attestation_url for real"* ]]
    ! [[ "$output" == *"Missing sbom_summary for real"* ]]
}

@test "verify-dashboard-data: has_variants:false fixture handles top-level fields" {
    FIXTURE_NO_VARIANTS="$PROJECT_ROOT/tests/fixtures/containers-no-variants.yml"
    run "$VERIFY_SCRIPT" "$FIXTURE_NO_VARIANTS"
    [ "$status" -eq 0 ]
    # The fixture deliberately retains the legacy Trivy shape, so only its
    # trivy_summary is a gap; its other top-level fields remain complete.
    [[ "$output" == *"Missing trivy_summary for standalone"* ]]
    ! [[ "$output" == *"Missing attestation_url for standalone"* ]]
    ! [[ "$output" == *"Missing sbom_summary for standalone"* ]]
    [[ "$output" == *"Missing attestation_url for incomplete"* ]]
    [[ "$output" == *"Missing trivy_summary for incomplete"* ]]
    [[ "$output" == *"Missing sbom_summary for incomplete"* ]]
    [[ "$output" == *"top-level fields"* ]]
}
