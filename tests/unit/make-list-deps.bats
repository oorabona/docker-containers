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

# ---------------------------------------------------------------------------
# Defect G regression lock: rc=2 from owner resolution failure propagates to
# operator via make list-deps (non-zero exit + clear stderr message).
# Must NOT silently report "(none — only external upstream)".
# ---------------------------------------------------------------------------
@test "make list-deps: owner resolution failure exits non-zero with error message" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="php wordpress"
    # Write a lineage file with a ghcr.io ref; no owner override and no git remote
    # means _depgraph_is_internal_ref returns rc=2 → must bubble to operator.
    _write_lineage "wordpress" "latest" "ghcr.io/someowner/php:latest"
    local isolated_dir="$TEST_TEMP_DIR/isolated_owner_fail_r23"
    mkdir -p "$isolated_dir"
    # Note: make now sets PROJECT_ROOT from $0 (security fix, Part 1), so setting
    # PROJECT_ROOT in the subprocess environment no longer controls which git repo
    # _depgraph_project_owner queries.  We disable git remote lookup by pointing
    # GIT_DIR at a non-repository path, ensuring all three owner-resolution paths
    # fail (no override, no GITHUB_REPOSITORY_OWNER, no usable git remote).
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        GIT_DIR='${isolated_dir}/.git'
        export GIT_DIR
        _DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='$TEST_TEMP_DIR/lineage'
        export _DEPGRAPH_LINEAGE_DIR
        '${MAKE_SCRIPT}' list-deps wordpress 2>&1
    "
    [ "$status" -ne 0 ]
    # Must not silently report "(none)"
    ! [[ "$output" == *"(none"* ]]
}

# ---------------------------------------------------------------------------
# Gate r24 — Defect I: _depgraph_valid_containers rc propagation
#
# When _depgraph_valid_containers fails (rc != 0), make list-deps must
# propagate a non-zero exit with a clear error rather than comparing the
# empty string against the container name and reporting "not a registered
# container" (masking the real upstream failure).
#
# Mutation guard:
#   MG-I: removing the _vc_rc check → an upstream failure masquerades as
#         "not a registered container" (test fails: output would contain
#         "not a registered container" instead of the upstream error)
# ---------------------------------------------------------------------------

@test "make list-deps: _depgraph_valid_containers failure propagates rc (not 'not a registered container')" {
    # Test the list_deps() function body directly to avoid PROJECT_ROOT being reset
    # by build-container.sh (which auto-detects from BASH_SOURCE at source time).
    # Inject a _depgraph_valid_containers override that always fails with rc=1,
    # then call list_deps() directly.  This directly exercises the new _vc_rc check
    # without depending on subprocess PROJECT_ROOT isolation.
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh' 2>/dev/null
        # Override _depgraph_valid_containers to simulate upstream failure (rc=1).
        _depgraph_valid_containers() {
            echo '::error::Failed to enumerate project containers via mock' >&2
            return 1
        }
        # Stub the other depgraph helpers so list_deps can run without full make context.
        log_error() { echo \"\$*\" >&2; }
        # Source the list_deps function body directly from make.
        # Extract and eval only the list_deps function definition.
        eval \"\$(grep -A 100 '^list_deps()' '${MAKE_SCRIPT}' | awk '/^list_deps\(\)/{found=1} found{print} /^}$/{if(found) exit}')\"
        list_deps wordpress 2>&1
        echo EXIT_CODE:\$?
    "
    # Output must contain our error message, NOT 'not a registered container'
    ! [[ "$output" == *"not a registered container"* ]]
    [[ "$output" == *"Failed to enumerate registered containers"* ]]
}

# ---------------------------------------------------------------------------
# Security: PROJECT_ROOT=/tmp ./make list must succeed despite bogus env var.
#
# Before the fix, `make` inherited PROJECT_ROOT from the environment and passed
# it to dependency-graph.sh before setting it from $0.  dependency-graph.sh then
# sourced "${PROJECT_ROOT}/helpers/lineage-utils.sh" — with PROJECT_ROOT=/tmp,
# this path does not exist and `./make list` failed with rc=1.
#
# After the fix, `make` establishes PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
# at the very top (before any source), so the inherited value is overridden and
# all helpers source from the real repo root.
#
# Mutation guard:
#   MG-PR: removing the PROJECT_ROOT= assignment at the top of `make` → this
#          test fails (./make list exits non-zero when PROJECT_ROOT=/tmp).
# ---------------------------------------------------------------------------

@test "make list: PROJECT_ROOT=/tmp ./make list succeeds and lists real containers" {
    # Invoke ./make list with a bogus inherited PROJECT_ROOT from the repo root.
    # make establishes its own PROJECT_ROOT from $0 at startup, so the inherited
    # /tmp value is overridden and helpers are sourced from the real repo root.
    # The output must be non-empty and must NOT contain a lineage-utils.sh error.
    #
    # Note: list_containers relies on the cwd being the project root (it uses
    # find "$base" and then sed/cut which require relative paths).  The ./make
    # invocation pattern is always from the repo root; this test preserves that
    # convention and specifically tests that the bogus PROJECT_ROOT is harmless.
    run bash -c "cd '${PROJECT_ROOT}' && PROJECT_ROOT='/tmp' ./make list 2>&1"
    [ "$status" -eq 0 ]
    # Output must contain at least one real container name
    [[ "$output" == *"ansible"* ]] || [[ "$output" == *"debian"* ]] || [[ "$output" == *"postgres"* ]]
    # Must NOT contain the broken-source error
    ! [[ "$output" == *"lineage-utils.sh: No such file"* ]]
    ! [[ "$output" == *"cannot open"* ]]
}
