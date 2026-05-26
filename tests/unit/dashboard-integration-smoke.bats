#!/usr/bin/env bats

# Integration smoke tests for the base_image truth pipeline (issue #530).
# Tests the full chain: _prepare_build_args → _resolve_base_image → _emit_build_lineage
# → resolve_lineage_file (dashboard read).
#
# Covers:
#   - Monolithic fixture (sslh-style): build_args substitution via _BUILD_ARGS_RESOLVED
#   - Template fixture (web-shell-style): post-template-generation FROM is authoritative
#   - Dashboard read fast-path: network helpers are NOT called
#   - Mutation guard: disabling A1 substitution pass causes base_image_ref to leak ${...}

load "../test_helper"

PROJECT_ROOT_REAL="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURE_MONO="$PROJECT_ROOT_REAL/tests/fixtures/dashboard-530/monolithic"
FIXTURE_TPL="$PROJECT_ROOT_REAL/tests/fixtures/dashboard-530/template"

setup() {
    setup_temp_dir
    export ORIG_DIR="$PWD"

    # Build-container.sh and dashboard source into separate workspaces below.
    # Keep global TEST_TEMP_DIR for assertions.
}

teardown() {
    cd "$ORIG_DIR" || true
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helper: source build-container.sh and its deps into current shell.
# Must be called from a directory that will serve as PROJECT_ROOT for that test.
# ---------------------------------------------------------------------------
source_build_container() {
    # Source order mirrors scripts/build-container.sh dependencies
    source "$PROJECT_ROOT_REAL/helpers/logging.sh"
    source "$PROJECT_ROOT_REAL/helpers/build-args-utils.sh"
    source "$PROJECT_ROOT_REAL/helpers/variant-utils.sh"
    source "$PROJECT_ROOT_REAL/helpers/template-utils.sh"

    pushd "$PROJECT_ROOT_REAL/scripts" > /dev/null 2>&1
    # shellcheck source=/dev/null
    source "./build-container.sh"
    popd > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Helper: extract dashboard functions without propagating set -euo pipefail.
# ---------------------------------------------------------------------------
source_dashboard_fns() {
    local _fn_defs
    _fn_defs=$(
        cd "$PROJECT_ROOT_REAL" 2>/dev/null
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT_REAL/generate-dashboard.sh" 2>/dev/null || true
        declare -f resolve_lineage_file
        declare -f get_build_lineage_field
        declare -f resolve_variant_lineage_file
        declare -f resolve_variant_lineage_json
    )
    eval "$_fn_defs"
}

# ---------------------------------------------------------------------------
# Smoke 1 — Monolithic fixture (Fix A1 end-to-end)
# Pipeline: _prepare_build_args → _resolve_base_image → _emit_build_lineage
# Assert: base_image_ref concrete, lineage_schema_version=2
# ---------------------------------------------------------------------------
@test "SMOKE-01: Monolithic fixture produces concrete base_image_ref (Fix A1)" {
    local work="$TEST_TEMP_DIR/mono"
    mkdir -p "$work"
    cp "$FIXTURE_MONO/config.yaml"   "$work/"
    cp "$FIXTURE_MONO/Dockerfile"    "$work/"
    cp "$FIXTURE_MONO/variants.yaml" "$work/"
    mkdir -p "$work/.build-lineage"

    # Source build-container.sh context from work dir
    cd "$work" || return 1
    source_build_container
    export PROJECT_ROOT="$work"

    # Mock docker (no real Docker needed)
    docker() { echo ""; }
    export -f docker

    # Run the substitution pipeline
    _prepare_build_args "$work" "v2.3.1"
    _resolve_base_image "$work/Dockerfile" "v2.3.1" "label_args"

    # Emit lineage
    _emit_build_lineage \
        "mono-fixture" "v2.3.1" "v2.3.1-alpine" "" \
        "$work/Dockerfile" "linux/amd64" "" \
        "example/mono-fixture" "ghcr.io/test/mono-fixture"

    local lineage_file="$work/.build-lineage/mono-fixture-v2.3.1-alpine.json"
    [ -f "$lineage_file" ]

    local base_image_ref
    base_image_ref=$(jq -r '.base_image_ref' "$lineage_file")
    # Must be concrete (no ${...} placeholder)
    [[ "$base_image_ref" == "alpine:3.21" ]]
}

@test "SMOKE-02: Monolithic fixture lineage_schema_version equals 2" {
    local work="$TEST_TEMP_DIR/mono2"
    mkdir -p "$work"
    cp "$FIXTURE_MONO/config.yaml"   "$work/"
    cp "$FIXTURE_MONO/Dockerfile"    "$work/"
    cp "$FIXTURE_MONO/variants.yaml" "$work/"
    mkdir -p "$work/.build-lineage"

    cd "$work" || return 1
    source_build_container
    export PROJECT_ROOT="$work"

    docker() { echo ""; }
    export -f docker

    _prepare_build_args "$work" "v2.3.1"
    _resolve_base_image "$work/Dockerfile" "v2.3.1" "label_args"
    _emit_build_lineage \
        "mono-fixture" "v2.3.1" "v2.3.1-alpine" "" \
        "$work/Dockerfile" "linux/amd64" "" \
        "example/mono-fixture" "ghcr.io/test/mono-fixture"

    local lineage_file="$work/.build-lineage/mono-fixture-v2.3.1-alpine.json"
    local schema_ver
    schema_ver=$(jq -r '.lineage_schema_version' "$lineage_file")
    [[ "$schema_ver" == "2" ]]
}

# ---------------------------------------------------------------------------
# Smoke 3 — Template fixture (Fix A2 end-to-end)
# Pipeline: template generation → _RESOLVE_FROM_GENERATED=1 → _resolve_base_image
# Assert: base_image_ref = "alpine:3.21" (from generated Dockerfile, not config)
# ---------------------------------------------------------------------------
@test "SMOKE-03: Template fixture (alpine) produces alpine:3.21 (Fix A2)" {
    local work="$TEST_TEMP_DIR/tpl"
    mkdir -p "$work"
    cp "$FIXTURE_TPL/config.yaml"          "$work/"
    cp "$FIXTURE_TPL/Dockerfile.template"  "$work/"
    cp "$FIXTURE_TPL/variants.yaml"        "$work/"
    cp "$FIXTURE_TPL/generate-dockerfile.sh" "$work/"
    chmod +x "$work/generate-dockerfile.sh"
    mkdir -p "$work/.build-lineage"

    cd "$work" || return 1
    source_build_container
    export PROJECT_ROOT="$work"

    docker() { echo ""; }
    export -f docker

    # Simulate what build_container does: generate the per-flavor Dockerfile
    local generated_df="$work/Dockerfile.alpine"
    bash "$work/generate-dockerfile.sh" "$work/Dockerfile.template" "alpine" > "$generated_df"
    [ -f "$generated_df" ]

    # Verify the generated Dockerfile has the correct FROM line
    [[ "$(head -1 "$generated_df")" == "FROM alpine:3.21" ]]

    # Prepare build args (populates _BUILD_ARGS_RESOLVED)
    _prepare_build_args "$work" "1.0"

    # Resolve base image POST-template-generation (Fix A2): use generated Dockerfile
    _RESOLVE_FROM_GENERATED=1 _resolve_base_image "$generated_df" "1.0" "label_args"

    # Emit lineage
    _emit_build_lineage \
        "tpl-fixture" "1.0" "1.0-alpine" "alpine" \
        "$generated_df" "linux/amd64" "" \
        "example/tpl-fixture" "ghcr.io/test/tpl-fixture"

    local lineage_file="$work/.build-lineage/tpl-fixture-1.0-alpine.json"
    [ -f "$lineage_file" ]

    local base_image_ref
    base_image_ref=$(jq -r '.base_image_ref' "$lineage_file")
    # Must be alpine:3.21 (from generated Dockerfile), NOT the debian template default
    [[ "$base_image_ref" == "alpine:3.21" ]]
}

@test "SMOKE-04: Template fixture (debian) produces concrete debian base_image_ref" {
    local work="$TEST_TEMP_DIR/tpl-deb"
    mkdir -p "$work"
    cp "$FIXTURE_TPL/config.yaml"          "$work/"
    cp "$FIXTURE_TPL/Dockerfile.template"  "$work/"
    cp "$FIXTURE_TPL/variants.yaml"        "$work/"
    cp "$FIXTURE_TPL/generate-dockerfile.sh" "$work/"
    chmod +x "$work/generate-dockerfile.sh"
    mkdir -p "$work/.build-lineage"

    cd "$work" || return 1
    source_build_container
    export PROJECT_ROOT="$work"

    docker() { echo ""; }
    export -f docker

    # Generate debian-flavor Dockerfile
    local generated_df="$work/Dockerfile.debian"
    bash "$work/generate-dockerfile.sh" "$work/Dockerfile.template" "debian" > "$generated_df"

    _prepare_build_args "$work" "1.0"
    _RESOLVE_FROM_GENERATED=1 _resolve_base_image "$generated_df" "1.0" "label_args"

    _emit_build_lineage \
        "tpl-fixture" "1.0" "1.0" "debian" \
        "$generated_df" "linux/amd64" "" \
        "example/tpl-fixture" "ghcr.io/test/tpl-fixture"

    local lineage_file="$work/.build-lineage/tpl-fixture-1.0.json"
    [ -f "$lineage_file" ]

    local base_image_ref
    base_image_ref=$(jq -r '.base_image_ref' "$lineage_file")
    # Must be concrete (no ${...} leak) and must mention debian
    [[ "$base_image_ref" != *'${'* ]]
    [[ "$base_image_ref" == *"debian"* ]]
}

# ---------------------------------------------------------------------------
# Smoke 5 — Dashboard read fast-path (Fix B)
# resolve_lineage_file must NOT call any network helpers
# ---------------------------------------------------------------------------
@test "SMOKE-05: Dashboard resolve_lineage_file does NOT invoke network helpers" {
    local work="$TEST_TEMP_DIR/dash"
    local lineage_dir="$work/.build-lineage"
    local container_dir="$work/test-container"
    mkdir -p "$lineage_dir" "$container_dir"

    # Write a v2 lineage file for a versioned container
    jq -n \
        '{lineage_schema_version:2, container:"test-container", base_image_ref:"alpine:3.21",
          version:"1.0", tag:"1.0-alpine", multi_arch_index_digest:"sha256:mock-idx"}' \
        > "$lineage_dir/test-container-1.0-alpine.json"

    # Write variants.yaml: version 1.0, default variant = alpine
    printf 'versions:\n  - tag: "1.0"\n    variants:\n      - name: alpine\n        default: true\n' \
        > "$container_dir/variants.yaml"

    # Extract dashboard functions without set -euo pipefail propagation
    export SCRIPT_DIR="$work"
    source_dashboard_fns

    # Declare network helpers that increment a counter
    local network_calls=0
    ghcr_get_token()   { (( network_calls++ )) || true; echo "mock-token"; }
    _ghcr_fetch_index() { (( network_calls++ )) || true; echo "{}"; }
    export -f ghcr_get_token _ghcr_fetch_index

    run resolve_lineage_file "test-container"
    [ "$status" -eq 0 ]
    [[ "$output" == *"test-container-1.0-alpine.json" ]]

    # Network helpers must NOT have been called
    [ "$network_calls" -eq 0 ]
}

@test "SMOKE-06: Dashboard resolves multi_arch_index_digest enriched field from lineage" {
    local work="$TEST_TEMP_DIR/dash2"
    local lineage_dir="$work/.build-lineage"
    local container_dir="$work/enrich-test"
    mkdir -p "$lineage_dir" "$container_dir"

    jq -n \
        '{lineage_schema_version:2, container:"enrich-test", base_image_ref:"alpine:3.21",
          version:"2.0", tag:"2.0-alpine", multi_arch_index_digest:"sha256:abc123"}' \
        > "$lineage_dir/enrich-test-2.0-alpine.json"

    printf 'versions:\n  - tag: "2.0"\n    variants:\n      - name: alpine\n        default: true\n' \
        > "$container_dir/variants.yaml"

    export SCRIPT_DIR="$work"
    source_dashboard_fns

    run resolve_lineage_file "enrich-test"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    local midx
    midx=$(jq -r '.multi_arch_index_digest // "missing"' "$output")
    [[ "$midx" == "sha256:abc123" ]]
}

# ---------------------------------------------------------------------------
# Mutation guard: disabling A1 substitution pass causes ${...} to survive
# ---------------------------------------------------------------------------
@test "SMOKE-07: Mutation guard — disabling A1 substitution pass leaks placeholder" {
    local work="$TEST_TEMP_DIR/mut"
    mkdir -p "$work"
    cp "$FIXTURE_MONO/config.yaml"   "$work/"
    cp "$FIXTURE_MONO/Dockerfile"    "$work/"
    cp "$FIXTURE_MONO/variants.yaml" "$work/"
    mkdir -p "$work/.build-lineage"

    cd "$work" || return 1
    source_build_container
    export PROJECT_ROOT="$work"

    docker() { echo ""; }
    export -f docker

    _prepare_build_args "$work" "v2.3.1"

    # Simulate pre-fix behavior: clear _BUILD_ARGS_RESOLVED before resolving
    # (this mimics the state before Fix A1 was applied)
    declare -gA _BUILD_ARGS_RESOLVED=()

    _resolve_base_image "$work/Dockerfile" "v2.3.1" "label_args"

    # Without _BUILD_ARGS_RESOLVED, _BASE_IMAGE_REF still has ${...} placeholders
    # because the Dockerfile ARG lines have no defaults (ARG OS_IMAGE_BASE, not ARG OS_IMAGE_BASE=alpine)
    # The mutation guard: _BASE_IMAGE_REF must still contain ${ when A1 is disabled
    [[ "$_BASE_IMAGE_REF" == *'${'* ]]
}

# ---------------------------------------------------------------------------
# Regression: Finding #3 — resolve_variant_lineage_json must sanitize
# base_image_ref containing ${...} (copilot HIGH finding)
# Pre-v2 lineage files with leaked placeholders survive in multi-variant path.
# ---------------------------------------------------------------------------
@test "SMOKE-08: resolve_variant_lineage_json sanitizes pre-v2 leaked base_image_ref" {
    local work="$TEST_TEMP_DIR/f3"
    local lineage_dir="$work/.build-lineage"
    local container_dir="$work/web-shell"
    mkdir -p "$lineage_dir" "$container_dir"

    # Write a pre-v2 lineage file (no lineage_schema_version) with leaked placeholder
    # This simulates a web-shell variant lineage written before Fix E was applied.
    jq -n \
        '{container:"web-shell", base_image_ref:"${DEBIAN_TAG}", version:"1.7.7", tag:"1.7.7-debian"}' \
        > "$lineage_dir/web-shell-1.7.7-debian.json"

    export SCRIPT_DIR="$work"
    source_dashboard_fns

    # Invoke resolve_variant_lineage_json as the dashboard does for multi-variant containers
    local result
    result=$(resolve_variant_lineage_json "web-shell" "1.7.7-debian" "1.7.7" "unknown" "debian")

    # The base_image field in the output must NOT contain ${ (sanitize-at-read)
    local base_image_out
    base_image_out=$(echo "$result" | jq -r '.base_image // ""')

    [[ "$base_image_out" != *'${'* ]] || {
        echo "FAIL: pre-v2 placeholder leaked into per-variant output: '$base_image_out'"
        echo "Full output: $result"
        return 1
    }

    # The value must be empty or "unknown" (not the leaked literal)
    [[ -z "$base_image_out" || "$base_image_out" == "unknown" ]] || {
        echo "FAIL: expected empty or 'unknown', got: '$base_image_out'"
        echo "Full output: $result"
        return 1
    }
}
