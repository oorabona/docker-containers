#!/usr/bin/env bats

# Unit tests for helpers/dependency-graph.sh
#
# All tests use _DEPGRAPH_CONTAINERS_OVERRIDE and _DEPGRAPH_LINEAGE_DIR to
# avoid touching the real project containers or .build-lineage directory.
#
# Mutation guards:
#   MG1: Remove internal-ref check → external library/php matches as php
#   MG2: Remove self-dep check → container A listed as its own dep
#   MG3: Remove sidecar skip → sidecar .sbom.json parsed as lineage
#   MG4: Remove cycle detection → _depgraph_validate_no_cycles returns 0 on cycle
#   MG5: Remove transitive dedup → diamond deps appear twice

load "../test_helper"

setup() {
    setup_temp_dir
    export _DEPGRAPH_LINEAGE_DIR="$TEST_TEMP_DIR/lineage"
    mkdir -p "$_DEPGRAPH_LINEAGE_DIR"

    # Use synthetic container set by default
    export _DEPGRAPH_CONTAINERS_OVERRIDE="php wordpress debian web-shell github-runner containerA containerB containerC"

    export PROJECT_ROOT
    export HELPERS_DIR
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helper: write a lineage JSON file
# ---------------------------------------------------------------------------
_write_lineage() {
    local container="$1"
    local tag="$2"
    local base_ref="$3"
    local file="${_DEPGRAPH_LINEAGE_DIR}/${container}-${tag}.json"
    printf '{"container":"%s","tag":"%s","base_image_ref":"%s","base_image_digest":"sha256:%s"}' \
        "$container" "$tag" "$base_ref" "$(printf '%064d' 0)" > "$file"
}

# ---------------------------------------------------------------------------
# Scenario 1: Direct dep — wordpress→php via ghcr.io ref
# ---------------------------------------------------------------------------
@test "depgraph: wordpress lineage with ghcr.io/oorabona/php:latest → direct dep=php" {
    _write_lineage "wordpress" "6.9.1-alpine" "ghcr.io/oorabona/php:latest"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

# ---------------------------------------------------------------------------
# Scenario 2: External-only — debian with library/debian:trixie → no internal dep
# MG1: verifies external library/ is NOT classified as internal
# ---------------------------------------------------------------------------
@test "depgraph: debian lineage with library/debian:trixie → empty deps (external)" {
    _write_lineage "debian" "trixie" "library/debian:trixie"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps debian
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Scenario 3: External org ref — hashicorp/terraform:1.0 → no internal dep
# ---------------------------------------------------------------------------
@test "depgraph: hashicorp/terraform:1.0 not classified as internal" {
    _write_lineage "containerA" "1.0" "hashicorp/terraform:1.0"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps containerA
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Scenario 4: Multiple deps — container depends on two project containers
# ---------------------------------------------------------------------------
@test "depgraph: multiple deps — containerA depends on php AND debian" {
    _write_lineage "containerA" "1.0-php" "ghcr.io/oorabona/php:latest"
    _write_lineage "containerA" "1.0-debian" "ghcr.io/oorabona/debian:trixie"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        deps=\$(_depgraph_get_deps containerA)
        # Order-independent check
        echo \"\$deps\" | tr ' ' '\n' | sort
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"debian"* ]]
    [[ "$output" == *"php"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 5: Transitive deps — A depends on B depends on C
# Expected transitive(A) = "C B" (leaves first)
# ---------------------------------------------------------------------------
@test "depgraph: transitive closure — A→B→C gives C B (leaves first)" {
    _write_lineage "containerA" "1.0" "ghcr.io/oorabona/containerB:latest"
    _write_lineage "containerB" "1.0" "ghcr.io/oorabona/containerC:latest"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps_transitive containerA
    "
    [ "$status" -eq 0 ]
    # containerC should appear before containerB (leaves first)
    c_pos=$(echo "$output" | tr ' ' '\n' | grep -n '^containerC$' | cut -d: -f1)
    b_pos=$(echo "$output" | tr ' ' '\n' | grep -n '^containerB$' | cut -d: -f1)
    [[ -n "$c_pos" && -n "$b_pos" ]]
    [[ "$c_pos" -lt "$b_pos" ]]
}

# ---------------------------------------------------------------------------
# Scenario 6: Cycle detection — A→B→A → validate_no_cycles exits 1
# MG4: if cycle detection removed, this test would fail
# ---------------------------------------------------------------------------
@test "depgraph: cycle detection — A→B→A → _depgraph_validate_no_cycles exits 1" {
    _write_lineage "containerA" "1.0" "ghcr.io/oorabona/containerB:latest"
    _write_lineage "containerB" "1.0" "ghcr.io/oorabona/containerA:latest"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_validate_no_cycles
    "
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Scenario 7: Sidecar skip — .sbom.json not counted as lineage
# MG3: if sidecar skip removed, the sidecar would be parsed as a dep
# ---------------------------------------------------------------------------
@test "depgraph: sidecar skip — .sbom.json not parsed as lineage" {
    # Write a sidecar file that references php — should NOT count
    printf '{"container":"wordpress","tag":"6.9.1-alpine","base_image_ref":"ghcr.io/oorabona/php:latest"}' \
        > "${_DEPGRAPH_LINEAGE_DIR}/wordpress-6.9.1-alpine.sbom.json"
    # No real lineage file — deps should be empty
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Scenario 8: Variant tag suffix — wordpress-6.9.4-alpine.json matches container "wordpress"
# ---------------------------------------------------------------------------
@test "depgraph: versioned tag suffix — wordpress-6.9.4-alpine.json matched to wordpress" {
    _write_lineage "wordpress" "6.9.4-alpine" "ghcr.io/oorabona/php:8.5"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

# ---------------------------------------------------------------------------
# Scenario 9: ${REMOTE_CR} literal detected as internal dep
# ---------------------------------------------------------------------------
@test "depgraph: \${REMOTE_CR}/php:latest detected as internal dep" {
    _write_lineage "wordpress" "latest" '${REMOTE_CR}/php:latest'
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

# ---------------------------------------------------------------------------
# Scenario 10: External-namespace overlap — library/php NOT our php
# MG1: the key case — library/php must NOT match internal container "php"
# ---------------------------------------------------------------------------
@test "depgraph: library/php is external, NOT matched to internal php container" {
    _write_lineage "wordpress" "latest" "library/php:8.4-fpm-alpine"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Scenario 11: web-shell depends on debian via ghcr.io
# ---------------------------------------------------------------------------
@test "depgraph: web-shell with ghcr.io/oorabona/debian:trixie → dep=debian" {
    _write_lineage "web-shell" "1.7.7-debian" "ghcr.io/oorabona/debian:trixie"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps web-shell
    "
    [ "$status" -eq 0 ]
    [ "$output" = "debian" ]
}

# ---------------------------------------------------------------------------
# Scenario 12: Deduplication — same dep across multiple variant files listed once
# MG5: if dedup removed, same dep would appear twice
# ---------------------------------------------------------------------------
@test "depgraph: dedup — two variant files with same base ref → dep listed once" {
    _write_lineage "wordpress" "6.9.1-alpine" "ghcr.io/oorabona/php:latest"
    _write_lineage "wordpress" "6.9.2-alpine" "ghcr.io/oorabona/php:latest"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        deps=\$(_depgraph_get_deps wordpress)
        echo \"\$deps\" | tr ' ' '\n' | grep -c '^php$'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Scenario 13: Transitive with diamond — A→B, A→C, B→C: transitive(A) = "C B" (C once)
# MG5: if dedup removed in transitive, C would appear twice
# ---------------------------------------------------------------------------
@test "depgraph: transitive diamond dedup — A→B, A→C, B→C: C appears once" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="containerA containerB containerC"
    _write_lineage "containerA" "1.0-b" "ghcr.io/oorabona/containerB:latest"
    _write_lineage "containerA" "1.0-c" "ghcr.io/oorabona/containerC:latest"
    _write_lineage "containerB" "1.0" "ghcr.io/oorabona/containerC:latest"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        t=\$(_depgraph_get_deps_transitive containerA)
        echo \"\$t\" | tr ' ' '\n' | grep -c '^containerC$'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Scenario 14: _depgraph_get_consumers — reverse lookup
# ---------------------------------------------------------------------------
@test "depgraph: get_consumers — php is consumed by wordpress" {
    export _DEPGRAPH_CONTAINERS_OVERRIDE="php wordpress"
    _write_lineage "wordpress" "latest" "ghcr.io/oorabona/php:latest"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_consumers php
    "
    [ "$status" -eq 0 ]
    [ "$output" = "wordpress" ]
}
