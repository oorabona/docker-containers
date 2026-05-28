#!/usr/bin/env bats

# Unit tests for ./make list-deps subcommand
#
# Tests use _DEPGRAPH_CONTAINERS_OVERRIDE and _DEPGRAPH_LINEAGE_DIR to avoid
# touching the real project state.
#
# Mutation guards:
#   MG1: Remove validation → unknown container accepted
#   MG2: Remove direct dep printing → output missing 'direct' line
#   MG3: Remove transitive dep printing → output missing 'transitive' line

load "../test_helper"

MAKE_SCRIPT=""

setup() {
    setup_temp_dir
    MAKE_SCRIPT="${PROJECT_ROOT}/make"
    export _DEPGRAPH_LINEAGE_DIR="$TEST_TEMP_DIR/lineage"
    mkdir -p "$_DEPGRAPH_LINEAGE_DIR"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helper: write a lineage JSON fixture
# ---------------------------------------------------------------------------
_write_lineage() {
    local container="$1"
    local tag="$2"
    local base_ref="$3"
    jq -cn \
        --arg container "$container" \
        --arg tag "$tag" \
        --arg base_ref "$base_ref" \
        '{"container":$container,"tag":$tag,"base_image_ref":$base_ref,"base_image_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' \
        > "${_DEPGRAPH_LINEAGE_DIR}/${container}-${tag}.json"
}

# ---------------------------------------------------------------------------
# Test 1: Known container with direct dep prints correct output
# MG2: verifies 'direct:' line is present
# ---------------------------------------------------------------------------
@test "make list-deps: known container prints direct and transitive" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="php wordpress"
    _write_lineage "wordpress" "latest" "ghcr.io/oorabona/php:latest"
    run bash -c "_DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress' _DEPGRAPH_LINEAGE_DIR='$TEST_TEMP_DIR/lineage' '${MAKE_SCRIPT}' list-deps wordpress 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"container: wordpress"* ]]
    [[ "$output" == *"direct: php"* ]]
    [[ "$output" == *"transitive"*"php"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: Unknown container exits non-zero with error message
# MG1: verifies validation is present
# ---------------------------------------------------------------------------
@test "make list-deps: unknown container exits 1 with error" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="php wordpress"
    run bash -c "_DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress' _DEPGRAPH_LINEAGE_DIR='$TEST_TEMP_DIR/lineage' '${MAKE_SCRIPT}' list-deps unknown-container 2>&1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a registered container"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: Container with no deps prints "(none)" messages
# MG3: verifies no-dep case is explicitly shown
# ---------------------------------------------------------------------------
@test "make list-deps: container with no internal deps prints (none)" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="debian"
    _write_lineage "debian" "trixie" "debian:trixie"
    run bash -c "_DEPGRAPH_CONTAINERS_OVERRIDE='debian' _DEPGRAPH_LINEAGE_DIR='$TEST_TEMP_DIR/lineage' '${MAKE_SCRIPT}' list-deps debian 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"container: debian"* ]]
    [[ "$output" == *"(none"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: Multi-level transitive — output shows leaves-first order
# ---------------------------------------------------------------------------
@test "make list-deps: multi-level transitive order is leaves first" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="alpha beta gamma"
    _write_lineage "alpha" "latest" "ghcr.io/oorabona/beta:latest"
    _write_lineage "beta" "latest" "ghcr.io/oorabona/gamma:latest"
    run bash -c "_DEPGRAPH_CONTAINERS_OVERRIDE='alpha beta gamma' _DEPGRAPH_LINEAGE_DIR='$TEST_TEMP_DIR/lineage' '${MAKE_SCRIPT}' list-deps alpha 2>/dev/null"
    [ "$status" -eq 0 ]
    # gamma (leaf) must appear before beta in transitive line
    transitive_line=$(echo "$output" | grep "^transitive")
    gamma_pos=$(echo "$transitive_line" | grep -bo 'gamma' | head -1 | cut -d: -f1)
    beta_pos=$(echo "$transitive_line" | grep -bo 'beta' | head -1 | cut -d: -f1)
    [[ -n "$gamma_pos" && -n "$beta_pos" ]]
    [[ "$gamma_pos" -lt "$beta_pos" ]]
}

# ---------------------------------------------------------------------------
# Test 5: help mentions list-deps
# ---------------------------------------------------------------------------
@test "make help: mentions list-deps" {
    run bash -c "'${MAKE_SCRIPT}' help 2>/dev/null"
    [[ "$output" == *"list-deps"* ]]
}

# ---------------------------------------------------------------------------
# Test 6: No container arg exits non-zero
# ---------------------------------------------------------------------------
@test "make list-deps: missing container arg exits non-zero" {
    run bash -c "'${MAKE_SCRIPT}' list-deps 2>&1"
    [ "$status" -ne 0 ]
}
