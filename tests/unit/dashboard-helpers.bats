#!/usr/bin/env bats

# Unit tests for dashboard helper functions in generate-dashboard.sh
# Covers lineage resolution, version mismatch detection, and fallback chains

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    # Source generate-dashboard.sh — the BASH_SOURCE guard prevents
    # generate_data from running when sourced, only functions are defined
    source "$ORIG_DIR/helpers/logging.sh" 2>/dev/null || true
    source "$ORIG_DIR/helpers/variant-utils.sh" 2>/dev/null || true
    source "$ORIG_DIR/generate-dashboard.sh" 2>/dev/null || true

    # Override SCRIPT_DIR AFTER sourcing — generate-dashboard.sh line 11
    # sets it to dirname "$0", we need it pointing to our test dir
    export SCRIPT_DIR="$TEST_DIR"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# --- Helper: create lineage file ---

create_lineage_file() {
    local filename="$1"
    local version="$2"
    local build_digest="${3:-abc123def456}"
    local base_image_ref="${4:-postgres:${version}}"

    mkdir -p "$TEST_DIR/.build-lineage"
    cat > "$TEST_DIR/.build-lineage/$filename" <<EOF
{
  "container": "postgres",
  "version": "$version",
  "tag": "$version",
  "flavor": "base",
  "build_digest": "$build_digest",
  "base_image_ref": "$base_image_ref",
  "built_at": "2026-02-02T18:00:00+00:00"
}
EOF
}

# ===================================================================
# resolve_variant_lineage_file
# ===================================================================

@test "resolve_variant_lineage_file: finds primary per-tag file" {
    create_lineage_file "postgres-18-alpine.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres-18-alpine.json" ]]
}

@test "resolve_variant_lineage_file: finds variant-specific file" {
    create_lineage_file "postgres-18-alpine-vector.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres-18-alpine-vector.json" ]]
}

@test "resolve_variant_lineage_file: fallback to flavor file" {
    # No per-tag file, but flavor file exists
    create_lineage_file "postgres-vector.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres-vector.json" ]]
}

@test "resolve_variant_lineage_file: fallback to main container file" {
    # No per-tag or per-flavor file, but main container file exists
    create_lineage_file "postgres.json" "18-alpine"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [ "$status" -eq 0 ]
    [[ "$output" == *"postgres.json" ]]
}

@test "resolve_variant_lineage_file: returns empty when nothing found" {
    mkdir -p "$TEST_DIR/.build-lineage"

    run resolve_variant_lineage_file "postgres" "18-alpine" "base"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===================================================================
# resolve_variant_lineage_json — version mismatch detection
# This is the function that had the bug fixed in commit 147e7cc
# ===================================================================

@test "lineage_json: same version — returns real build_digest" {
    create_lineage_file "postgres-18-alpine.json" "18-alpine" "c38236b266dd" "postgres:18-alpine"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    # Should return the real digest, not "unknown"
    [[ "$output" == *"c38236b266dd"* ]]
}

@test "lineage_json: rolling tag 18-alpine vs full version 18.1-alpine — no mismatch" {
    # This is THE bug that was fixed: lineage has "18-alpine" (build tag),
    # current_version is "18.1-alpine" (full upstream version).
    # Major version 18 matches → digest should be preserved.
    create_lineage_file "postgres-18-alpine.json" "18-alpine" "c38236b266dd" "postgres:18-alpine"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18.1-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    # Digest must be preserved (not reset to "unknown")
    [[ "$output" == *"c38236b266dd"* ]]
    [[ "$output" != *'"build_digest":"unknown"'* ]]
}

@test "lineage_json: rolling tag 17-alpine vs full version 17.2-alpine — no mismatch" {
    create_lineage_file "postgres-17-alpine.json" "17-alpine" "deadbeef1234" "postgres:17-alpine"

    run resolve_variant_lineage_json "postgres" "17-alpine" "17.2-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deadbeef1234"* ]]
}

@test "lineage_json: rolling tag 16-alpine vs full version 16.8-alpine — no mismatch" {
    create_lineage_file "postgres-16-alpine.json" "16-alpine" "feed0000cafe" "postgres:16-alpine"

    run resolve_variant_lineage_json "postgres" "16-alpine" "16.8-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feed0000cafe"* ]]
}

@test "lineage_json: different major version — triggers mismatch" {
    # Lineage is from PG 17, but current version is PG 18 → mismatch
    create_lineage_file "postgres-18-alpine.json" "17-alpine" "olddigest1234" "postgres:17-alpine"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18.1-alpine" "postgres" "base"
    [ "$status" -eq 0 ]
    # Digest should be reset to "unknown" due to major version mismatch
    [[ "$output" == *'"build_digest":"unknown"'* ]] || [[ "$output" == *"unknown"* ]]
}

@test "lineage_json: no lineage file — returns unknown digest with derived base_image" {
    mkdir -p "$TEST_DIR/.build-lineage"

    run resolve_variant_lineage_json "postgres" "18-alpine" "18.1-alpine" "postgres:18-alpine" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
}

@test "lineage_json: exact version match (non-rolling tag like terraform)" {
    create_lineage_file "terraform-1.10.0.json" "1.10.0" "tf_digest_123" "hashicorp/terraform:1.10.0"

    run resolve_variant_lineage_json "terraform" "1.10.0" "1.10.0" "hashicorp/terraform" "base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tf_digest_123"* ]]
}

# ===================================================================
# resolve_variant_lineage_file — multiple PG versions coexisting
# ===================================================================

@test "lineage_file: PG 18 and PG 17 files coexist, correct one resolved" {
    create_lineage_file "postgres-18-alpine.json" "18-alpine" "digest_18"
    create_lineage_file "postgres-17-alpine.json" "17-alpine" "digest_17"

    run resolve_variant_lineage_file "postgres" "18-alpine" "base"
    [[ "$output" == *"postgres-18-alpine.json" ]]

    run resolve_variant_lineage_file "postgres" "17-alpine" "base"
    [[ "$output" == *"postgres-17-alpine.json" ]]
}

@test "lineage_file: variant files resolved independently" {
    create_lineage_file "postgres-18-alpine-vector.json" "18-alpine" "vec_digest"
    create_lineage_file "postgres-18-alpine-analytics.json" "18-alpine" "ana_digest"

    run resolve_variant_lineage_file "postgres" "18-alpine-vector" "vector"
    [[ "$output" == *"postgres-18-alpine-vector.json" ]]

    run resolve_variant_lineage_file "postgres" "18-alpine-analytics" "analytics"
    [[ "$output" == *"postgres-18-alpine-analytics.json" ]]
}
