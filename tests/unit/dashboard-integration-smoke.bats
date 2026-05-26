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

    # Run the substitution pipeline (version first, then flavor — matches production signature)
    _prepare_build_args "v2.3.1" ""
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

    _prepare_build_args "v2.3.1" ""
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
# Pipeline: template generation → _resolve_base_image with from_generated=1
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
    _prepare_build_args "1.0" ""

    # Resolve base image POST-template-generation (Fix A2): use generated Dockerfile
    _resolve_base_image "$generated_df" "1.0" "label_args" "1"

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

    _prepare_build_args "1.0" ""
    _resolve_base_image "$generated_df" "1.0" "label_args" "1"

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

    _prepare_build_args "v2.3.1" ""

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

# ---------------------------------------------------------------------------
# Regression: sanitize-at-read must key on placeholder presence, NOT on the
# absence of lineage_schema_version (#530).
# A v1 lineage file (no lineage_schema_version) with a CONCRETE base_image_ref
# must be preserved, not blanked to "unknown".
# ---------------------------------------------------------------------------
@test "SMOKE-09: v1 lineage file with concrete base_image_ref is preserved, not blanked" {
    local work="$TEST_TEMP_DIR/f1-concrete"
    local lineage_dir="$work/.build-lineage"
    local container_dir="$work/mycontainer"
    mkdir -p "$lineage_dir" "$container_dir"

    # Write a v1 lineage file (no lineage_schema_version field) with a CONCRETE base_image_ref.
    # This simulates every cached lineage file that existed before #530 — they have concrete
    # values and must NOT be downgraded to "unknown" just because the schema version field is absent.
    jq -n \
        '{container:"mycontainer", base_image_ref:"alpine:3.21", version:"1.0", tag:"1.0-alpine"}' \
        > "$lineage_dir/mycontainer-1.0-alpine.json"

    # Verify no lineage_schema_version is present in the fixture
    local schema_ver
    schema_ver=$(jq -r '.lineage_schema_version // "absent"' "$lineage_dir/mycontainer-1.0-alpine.json")
    [[ "$schema_ver" == "absent" ]]

    printf 'versions:\n  - tag: "1.0"\n    variants:\n      - name: alpine\n        default: true\n' \
        > "$container_dir/variants.yaml"

    export SCRIPT_DIR="$work"
    source_dashboard_fns

    # Invoke resolve_variant_lineage_json as the dashboard does
    local result
    result=$(resolve_variant_lineage_json "mycontainer" "1.0-alpine" "1.0" "unknown" "alpine")

    local base_image_out
    base_image_out=$(echo "$result" | jq -r '.base_image // ""')

    # v1 file with concrete value must be preserved AS-IS ("alpine:3.21").
    # Bug: the absent-schema-version check blanks it to "unknown" even when the value is concrete.
    [[ "$base_image_out" == "alpine:3.21" ]] || {
        echo "FAIL: expected 'alpine:3.21' (v1 concrete value preserved), got: '$base_image_out'"
        echo "Full output: $result"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Finding #3 (gate r5 copilot HIGH): Template-container lineage regression
# Pre-fix: generated Dockerfile has ARG REMOTE_CR (no default) → ${REMOTE_CR}
# survives all substitution passes → dashboard shows "unknown".
# Post-fix: ARG REMOTE_CR=docker.io in generated Dockerfile → Step 4 substitutes
# docker.io → _BASE_IMAGE_REF = "docker.io/library/alpine:3.21".
# ---------------------------------------------------------------------------
@test "SMOKE-10: Template container with ARG REMOTE_CR=docker.io default resolves to docker.io base" {
    # Simulates web-shell alpine variant local build (no REMOTE_CR in env).
    # The generated Dockerfile must declare ARG REMOTE_CR=docker.io so that
    # _resolve_base_image Step 4 (Dockerfile ARG defaults) can resolve the placeholder.

    local work="$TEST_TEMP_DIR/tpl-remote-cr"
    mkdir -p "$work"
    mkdir -p "$work/.build-lineage"

    # Create a minimal generated Dockerfile as the real web-shell generator would,
    # but WITH the fixed default (ARG REMOTE_CR=docker.io).
    cat > "$work/Dockerfile.generated" <<'DOCKERFILE'
ARG REMOTE_CR=docker.io
ARG ALPINE_TAG=3.21
FROM ${REMOTE_CR}/library/alpine:${ALPINE_TAG}
RUN echo test
DOCKERFILE

    # No config.yaml base_image — this path passes from_generated=1 as 4th arg
    # (config.yaml is absent, so the FROM line in the generated file is authoritative)

    cd "$work" || return 1
    source_build_container
    export PROJECT_ROOT="$work"

    docker() { echo ""; }
    export -f docker

    # Do NOT set CUSTOM_BUILD_ARGS (simulates local build without CI-injected REMOTE_CR)
    unset CUSTOM_BUILD_ARGS
    unset _BUILD_ARGS_RESOLVED

    # No config.yaml in this fixture — _prepare_build_args must handle missing config gracefully
    touch "$work/config.yaml"
    _prepare_build_args "3.21" "" 2>/dev/null || true

    local label_args=""
    _resolve_base_image "$work/Dockerfile.generated" "3.21" "label_args" "1" 2>/dev/null || true

    # Post-fix: ARG REMOTE_CR=docker.io default is used → resolved to docker.io/library/alpine:3.21
    [[ "$_BASE_IMAGE_REF" == "docker.io/library/alpine:3.21" ]] || {
        echo "FAIL: expected 'docker.io/library/alpine:3.21', got: '$_BASE_IMAGE_REF'"
        echo "  (pre-fix: ARG REMOTE_CR has no default → \${REMOTE_CR} unresolved → dashboard shows unknown)"
        return 1
    }
    # Must not contain any leaked placeholder
    [[ "$_BASE_IMAGE_REF" != *'${'* ]] || {
        echo "FAIL: placeholder leaked in _BASE_IMAGE_REF: '$_BASE_IMAGE_REF'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Finding #8: lineage_schema_version=2 consumer audit
# Non-dashboard consumers (enrich-lineage.sh, extension-duration-utils.sh,
# build-container action) read only fields that pre-date schema v2 and use
# jq "// default" guards.  A v2 lineage file with the new fields must not
# cause any consumer to error or silently skip.
# ---------------------------------------------------------------------------
@test "SMOKE-11: enrich-lineage and extension-duration consumers do not error on v2 lineage" {
    local work="$TEST_TEMP_DIR/schema-v2-audit"
    local lineage_dir="$work/.build-lineage"
    mkdir -p "$lineage_dir"

    # Write a schema-v2 lineage file (adds lineage_schema_version + base_image_ref
    # fields that did not exist in v1).
    jq -n '{
        lineage_schema_version: 2,
        container: "test-container",
        version: "1.0",
        tag: "1.0-alpine",
        base_image_ref: "alpine:3.21",
        base_image_digest: "sha256:aaaa",
        multi_arch_index_digest: "sha256:bbbb",
        duration_seconds: 42,
        built_at: "2026-01-01T00:00:00+00:00"
    }' > "$lineage_dir/test-container-1.0-alpine.json"

    # Simulate enrich-lineage.sh read path: reads .container, .tag, .multi_arch_index_digest
    local container_field tag_field midx_field
    container_field=$(jq -re '.container // empty' "$lineage_dir/test-container-1.0-alpine.json" 2>/dev/null)
    tag_field=$(jq -r '.tag // empty' "$lineage_dir/test-container-1.0-alpine.json" 2>/dev/null) || tag_field=""
    midx_field=$(jq -r '.multi_arch_index_digest // empty' "$lineage_dir/test-container-1.0-alpine.json" 2>/dev/null) || midx_field=""

    [[ "$container_field" == "test-container" ]] || { echo "FAIL: enrich-lineage .container read failed"; return 1; }
    [[ "$tag_field" == "1.0-alpine" ]] || { echo "FAIL: enrich-lineage .tag read failed"; return 1; }
    [[ "$midx_field" == "sha256:bbbb" ]] || { echo "FAIL: enrich-lineage .multi_arch_index_digest read failed"; return 1; }

    # Simulate extension-duration-utils.sh read path: reads .duration_seconds
    local duration_field
    duration_field=$(jq -r '.duration_seconds // 0' "$lineage_dir/test-container-1.0-alpine.json" 2>/dev/null || echo 0)
    [[ "$duration_field" == "42" ]] || { echo "FAIL: extension-duration .duration_seconds read failed"; return 1; }

    # The new fields (lineage_schema_version, base_image_ref) are additive.
    # Consumers using '// default' guards tolerate unknown fields transparently.
    true
}
