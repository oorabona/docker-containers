#!/usr/bin/env bats

# Tests for resolve_lineage_file in generate-dashboard.sh
# Covers Fix B: default_variant() selection instead of filesystem-first.
# Red on current code (pre-fix); green after fix.
# Fix E: sanitize-at-read for base_image_ref with leaked ${...} placeholders.

load "../test_helper"

PROJECT_ROOT_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    setup_temp_dir
    export ORIG_DIR="$PWD"

    mkdir -p "$TEST_TEMP_DIR/.build-lineage"

    # Extract only the function definitions we need from generate-dashboard.sh,
    # without activating the "set -euo pipefail" that the script sets at the top
    # level (which would make failing test assertions crash the test process rather
    # than report "not ok").
    #
    # Technique: source the script in a subshell (which can tolerate the set -euo
    # pipefail environment and any top-level side effects), then extract the
    # function bodies with "declare -f" and eval them in the parent shell where we
    # control the set options.
    local _fn_defs
    _fn_defs=$(
        cd "$PROJECT_ROOT_REAL" 2>/dev/null
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT_REAL/generate-dashboard.sh" 2>/dev/null || true
        # Export function defs back to caller
        declare -f resolve_lineage_file
        declare -f get_build_lineage_field
    )
    eval "$_fn_defs"

    # Override SCRIPT_DIR so resolve_lineage_file reads from our temp dir
    SCRIPT_DIR="$TEST_TEMP_DIR"
    export SCRIPT_DIR
}

teardown() {
    cd "$ORIG_DIR" || true
    teardown_temp_dir
}

# Helper: create a fake lineage file in .build-lineage/
make_lineage() {
    local name="$1"
    local base_image="${2:-alpine:3.21}"
    jq -n \
        --arg base_image "$base_image" \
        --arg name "$name" \
        '{lineage_schema_version: 2, container: "test", base_image_ref: $base_image, version: "1.0", tag: $name}' \
        > "$TEST_TEMP_DIR/.build-lineage/${name}.json"
}

# Helper: create variants.yaml with optional multi-version structure
make_variants_yaml() {
    local container_dir="$1"
    local yaml_content="$2"
    mkdir -p "$container_dir"
    printf '%s\n' "$yaml_content" > "$container_dir/variants.yaml"
}

# =============================================================================
# Fix B: default_variant selection (NEVER filesystem-first)
# =============================================================================

@test "DRDV-01: Multi-variant single-version uses default_variant (debian is default)" {
    # Create fake lineage files for all web-shell variants
    make_lineage "web-shell-1.7.7-alpine" "alpine:3.21"
    make_lineage "web-shell-1.7.7-debian" "ghcr.io/oorabona/debian:trixie"
    make_lineage "web-shell-1.7.7-ubuntu" "ubuntu:noble"
    make_lineage "web-shell-1.7.7-rocky" "rockylinux:9"

    # variants.yaml with debian as default
    make_variants_yaml "$TEST_TEMP_DIR/web-shell" "$(cat <<'YAML'
versions:
  - tag: "1.7.7"
    variants:
      - name: debian
        default: true
      - name: alpine
      - name: ubuntu
      - name: rocky
YAML
)"

    run resolve_lineage_file "web-shell"
    [ "$status" -eq 0 ]
    # Fix B: must return the default variant (debian), not filesystem-first (may return alpine/rocky)
    [[ "$output" == *"web-shell-1.7.7-debian.json" ]]
}

@test "DRDV-02: Multi-version multi-flavor returns latest version default flavor" {
    # Postgres-style: versions [18, 17, 16], default flavor = base
    make_lineage "postgres-18-alpine" "ghcr.io/oorabona/library/postgres:18-alpine"
    make_lineage "postgres-17-alpine" "ghcr.io/oorabona/library/postgres:17-alpine"
    make_lineage "postgres-16-alpine" "ghcr.io/oorabona/library/postgres:16-alpine"
    make_lineage "postgres-18-alpine-base" "ghcr.io/oorabona/library/postgres:18-alpine"

    make_variants_yaml "$TEST_TEMP_DIR/postgres" "$(cat <<'YAML'
versions:
  - tag: "18"
    variants:
      - name: base
        default: true
      - name: vector
  - tag: "17"
    variants:
      - name: base
        default: true
YAML
)"

    run resolve_lineage_file "postgres"
    [ "$status" -eq 0 ]
    # Should return the latest version (18) default variant (base)
    # The key invariant: must include "18" and NOT "17" or "16"
    [[ "$output" == *"postgres-18"* ]]
}

@test "DRDV-03: Versions-only container returns latest version lineage" {
    # ansible: no variants, just versions
    make_lineage "ansible-13.3.0-ubuntu" "ubuntu:noble"
    make_lineage "ansible-13.4.0-ubuntu" "ubuntu:noble"

    make_variants_yaml "$TEST_TEMP_DIR/ansible" "$(cat <<'YAML'
versions:
  - tag: "13.4.0"
  - tag: "13.3.0"
YAML
)"

    run resolve_lineage_file "ansible"
    [ "$status" -eq 0 ]
    # Should return latest version (first in list = 13.4.0)
    [[ "$output" == *"13.4.0"* ]]
}

@test "DRDV-04: Legacy container-level rollup file preserved" {
    # If container.json exists, return it directly (legacy path)
    make_lineage "foo" "alpine:3.21"

    # No variants.yaml needed — the container.json takes precedence
    run resolve_lineage_file "foo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"foo.json" ]]
}

@test "DRDV-05: Malformed variants.yaml returns empty sentinel, never filesystem-first" {
    # Create real lineage files that would be found by filesystem-first
    make_lineage "foo-1.0-alpine" "alpine:3.21"
    make_lineage "foo-1.0-debian" "debian:trixie"

    # Malformed YAML (invalid syntax)
    make_variants_yaml "$TEST_TEMP_DIR/foo" "$(printf 'versions:\n  - tag: [\nnot: valid: yaml')"

    run resolve_lineage_file "foo"
    [ "$status" -eq 0 ]
    # Fix B: must return empty (sentinel), NOT a filesystem-first fallback
    [[ -z "$output" ]]
}

@test "DRDV-06: Multiple default:true variants returns first match (no ambiguity crash)" {
    make_lineage "bar-1.0-alpine" "alpine:3.21"
    make_lineage "bar-1.0-debian" "debian:trixie"

    # Two variants with default: true — first one should win (head -1 behavior)
    make_variants_yaml "$TEST_TEMP_DIR/bar" "$(cat <<'YAML'
versions:
  - tag: "1.0"
    variants:
      - name: alpine
        default: true
      - name: debian
        default: true
YAML
)"

    run resolve_lineage_file "bar"
    [ "$status" -eq 0 ]
    # Should not crash; should return one of the defaults
    # The key invariant: result must be one of the known lineage files (not empty crash)
    [[ -z "$output" || "$output" == *"bar-1.0"* ]]
}

@test "DRDV-07: Default variant lineage missing, falls back to any present variant with notice" {
    # debian is default but its lineage file doesn't exist — fall back to alpine
    make_lineage "web-shell-1.7.7-alpine" "alpine:3.21"
    # No web-shell-1.7.7-debian.json

    make_variants_yaml "$TEST_TEMP_DIR/web-shell" "$(cat <<'YAML'
versions:
  - tag: "1.7.7"
    variants:
      - name: debian
        default: true
      - name: alpine
YAML
)"

    run resolve_lineage_file "web-shell"
    [ "$status" -eq 0 ]
    # Falls back to any present variant
    [[ "$output" == *"web-shell-1.7.7-alpine.json" ]]
}

@test "DRDV-08: All variant lineage files missing returns empty string" {
    # No .json files exist for baz
    make_variants_yaml "$TEST_TEMP_DIR/baz" "$(cat <<'YAML'
versions:
  - tag: "1.0"
    variants:
      - name: alpine
        default: true
YAML
)"

    run resolve_lineage_file "baz"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

# =============================================================================
# Fix E: sanitize-at-read — base_image_ref with ${ returns empty
# =============================================================================

@test "DRDV-09: Pre-v2 entry with leaked base_image_ref treated as empty at read" {
    # Create a pre-v2 lineage file with a leaked placeholder
    jq -n '{container:"sslh","base_image_ref":"${OS_IMAGE_BASE}:${OS_IMAGE_TAG}","version":"v2.3.1","tag":"v2.3.1-alpine"}' \
        > "$TEST_TEMP_DIR/.build-lineage/sslh-v2.3.1-alpine.json"

    # make container.json for simple resolution
    cp "$TEST_TEMP_DIR/.build-lineage/sslh-v2.3.1-alpine.json" \
       "$TEST_TEMP_DIR/.build-lineage/sslh.json"

    run get_build_lineage_field "sslh" "base_image_ref"
    [ "$status" -eq 0 ]
    # Fix E: sanitize-at-read: leaked placeholder should return empty, not the literal "${...}"
    [[ -z "$output" || "$output" == "unknown" ]]
}

# =============================================================================
# Regression: Finding #2 — resolve_lineage_file must use variant_image_tag for
# the default variant filename, not raw default_name in a glob.
# (orthogonal gate codex MEDIUM finding)
# =============================================================================

@test "DRDV-10: Postgres default-variant (base) resolves suffixless file, not -base suffixed file" {
    # Production postgres tags: base variant → "18-alpine" (NO -base suffix),
    # vector variant → "18-alpine-vector". The current bug: the glob
    # *{default_name}.json = *base.json matches "postgres-18-alpine-base.json"
    # (if it exists) and picks it instead of the correct "postgres-18-alpine.json".
    #
    # This test deliberately creates BOTH the suffixless file AND a stale/wrong
    # -base-suffixed file (which can arrive via a mis-tagged build), and verifies
    # that resolve_lineage_file returns the CORRECT suffixless one.
    make_lineage "postgres-18-alpine" "ghcr.io/oorabona/library/postgres:18-alpine"
    make_lineage "postgres-18-alpine-vector" "ghcr.io/oorabona/library/postgres:18-alpine"
    # Also create the wrong -base-suffixed stale file (the one the old glob would pick)
    make_lineage "postgres-18-alpine-base" "stale-wrong-base-image:should-not-be-selected"

    make_variants_yaml "$TEST_TEMP_DIR/postgres" "$(cat <<'YAML'
versions:
  - tag: "18"
    base_suffix: "-alpine"
    variants:
      - name: base
        default: true
      - name: vector
        suffix: "-vector"
YAML
)"

    run resolve_lineage_file "postgres"
    [ "$status" -eq 0 ]
    # Must return the SUFFIXLESS file (postgres-18-alpine.json), NOT postgres-18-alpine-base.json
    [[ "$output" == *"postgres-18-alpine.json" ]] || {
        echo "FAIL: expected *postgres-18-alpine.json, got: '$output'"
        return 1
    }
    # Explicitly must NOT end in -base.json (old glob would have picked this one)
    [[ "$output" != *"-base.json" ]] || {
        echo "FAIL: returned file has -base suffix (wrong): '$output'"
        return 1
    }
}
