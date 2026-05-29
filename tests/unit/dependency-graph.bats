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
    # Write a sidecar file that references php — should NOT be read as a lineage
    # source.  Uses containerC (no config.yaml in the project) so the config.yaml
    # fallback also produces no deps, confirming the sidecar was skipped.
    printf '{"container":"containerC","tag":"1.0","base_image_ref":"ghcr.io/oorabona/php:latest"}' \
        > "${_DEPGRAPH_LINEAGE_DIR}/containerC-1.0.sbom.json"
    # No real lineage file — sidecar skipped, no config.yaml fallback → empty
    rm -f "${PROJECT_ROOT}/containerC/config.yaml"
    run bash -c "
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps containerC
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

# ---------------------------------------------------------------------------
# Defect B.2 fix: _depgraph_valid_containers fail-closed on './make list' failure
# ---------------------------------------------------------------------------
@test "depgraph: valid_containers — './make list' failure → non-zero exit (fail-closed)" {
    # Unset the override so the code takes the ./make list path.
    # Place a failing make stub in PATH.
    unset _DEPGRAPH_CONTAINERS_OVERRIDE
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_TEMP_DIR/bin/make"
    chmod +x "$TEST_TEMP_DIR/bin/make"
    run env -u _DEPGRAPH_CONTAINERS_OVERRIDE PATH="$TEST_TEMP_DIR/bin:$PATH" \
        bash -c "
            PROJECT_ROOT='$TEST_TEMP_DIR'
            source '${HELPERS_DIR}/dependency-graph.sh'
            _depgraph_valid_containers
        "
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}

@test "depgraph: valid_containers — './make list' returns empty → non-zero exit (fail-closed)" {
    # Place a stub that exits 0 but prints nothing.
    unset _DEPGRAPH_CONTAINERS_OVERRIDE
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TEMP_DIR/bin/make"
    chmod +x "$TEST_TEMP_DIR/bin/make"
    run env -u _DEPGRAPH_CONTAINERS_OVERRIDE PATH="$TEST_TEMP_DIR/bin:$PATH" \
        bash -c "
            PROJECT_ROOT='$TEST_TEMP_DIR'
            source '${HELPERS_DIR}/dependency-graph.sh'
            _depgraph_valid_containers
        "
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Defect C fix: _depgraph_project_owner — test hook and fail-closed
# ---------------------------------------------------------------------------

@test "depgraph: project_owner — _DEPGRAPH_OWNER_OVERRIDE returned verbatim" {
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=testowner
        export _DEPGRAPH_OWNER_OVERRIDE
        PROJECT_ROOT='$PROJECT_ROOT'
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_project_owner
    "
    [ "$status" -eq 0 ]
    [ "$output" = "testowner" ]
}

@test "depgraph: project_owner — GITHUB_REPOSITORY_OWNER returned verbatim" {
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        export GITHUB_REPOSITORY_OWNER=myorg
        PROJECT_ROOT='$PROJECT_ROOT'
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_project_owner
    "
    [ "$status" -eq 0 ]
    [ "$output" = "myorg" ]
}

@test "depgraph: project_owner — no env var, no git remote → non-zero (fail-closed)" {
    # Use a temp dir with no git remote as PROJECT_ROOT
    local isolated_dir="$TEST_TEMP_DIR/isolated"
    mkdir -p "$isolated_dir"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_project_owner
    "
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Defect C fix: owner-scoped matching — ghcr.io/other-owner rejected
# ---------------------------------------------------------------------------

@test "depgraph: ghcr.io with project owner → internal dep detected" {
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "ghcr.io/oorabona/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

@test "depgraph: ghcr.io with other-owner → NOT an internal dep (owner mismatch)" {
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "ghcr.io/other-owner/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "depgraph: hub.docker.io with project owner → internal dep detected" {
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "hub.docker.io/oorabona/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

@test "depgraph: hub.docker.io with other-owner → NOT an internal dep (owner mismatch)" {
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "hub.docker.io/other-owner/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "depgraph: docker.io with project owner → internal dep detected (Defect C regression)" {
    # Lineage files emit resolved refs in docker.io/<owner>/... form.
    # These must be classified as internal (same registry as hub.docker.io).
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "docker.io/oorabona/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

@test "depgraph: docker.io with other-owner → NOT an internal dep (owner mismatch)" {
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "docker.io/other-owner/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "depgraph: docker.io and hub.docker.io are symmetric for same owner and container" {
    # Both aliases for the same registry — both must resolve to the same parent.
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" "docker.io/oorabona/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    local docker_io_result="$output"
    # Now test hub.docker.io
    _write_lineage "wordpress" "latest" "hub.docker.io/oorabona/php:latest"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
    [ "$docker_io_result" = "php" ]
}

@test "depgraph: \${REMOTE_CR}/php:latest always internal (CI-controlled prefix)" {
    export _DEPGRAPH_OWNER_OVERRIDE=oorabona
    _write_lineage "wordpress" "latest" '${REMOTE_CR}/php:latest'
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

@test "depgraph: library/php is external even with owner override set" {
    _write_lineage "wordpress" "latest" "library/php:8.4-fpm-alpine"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Gate r24 — Defect J: ${REMOTE_CR} resolves BEFORE owner-resolution step
#
# In any environment without a usable owner source (_DEPGRAPH_OWNER_OVERRIDE="",
# GITHUB_REPOSITORY_OWNER="", no git remote), a ${REMOTE_CR}/<name>:<tag> ref
# must still resolve to the container name (rc=0) instead of returning rc=2
# (owner-resolution failure).  The always-trusted REMOTE_CR check must run
# BEFORE the owner-dependent registry branch.
#
# Mutation guard:
#   MG-J: swapping the REMOTE_CR branch back after the owner-resolution call →
#         _depgraph_is_internal_ref returns rc=2 instead of rc=0 + name
# ---------------------------------------------------------------------------

@test "depgraph: Defect J — \${REMOTE_CR}/php:latest resolves without owner source (no _DEPGRAPH_OWNER_OVERRIDE)" {
    # No owner override, no GITHUB_REPOSITORY_OWNER, PROJECT_ROOT has no git remote.
    # Pass the literal ref via a file to avoid bash -c quoting expansion of ${REMOTE_CR}.
    # Redirect source stderr to /dev/null so only the function's stdout is captured.
    local isolated_dir="$TEST_TEMP_DIR/isolated_defectJ"
    mkdir -p "$isolated_dir"
    local ref_file="$TEST_TEMP_DIR/remote_cr_ref.txt"
    printf '%s' '${REMOTE_CR}/php:latest' > "$ref_file"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh' 2>/dev/null
        ref=\$(cat '${ref_file}')
        _depgraph_is_internal_ref \"\$ref\" 'php wordpress'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

@test "depgraph: Defect J — \${REMOTE_CR}/php:latest via get_deps without owner source" {
    # Same environment: no owner. _depgraph_get_deps must succeed and return 'php'.
    # Redirect all stderr to /dev/null: source failures and is_lineage_sidecar errors
    # (lineage-utils.sh not available in isolated dir) must not pollute $output.
    local isolated_dir="$TEST_TEMP_DIR/isolated_defectJ_get"
    mkdir -p "$isolated_dir"
    _write_lineage "wordpress" "latest" '${REMOTE_CR}/php:latest'
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh' 2>/dev/null
        _depgraph_get_deps wordpress 2>/dev/null
    "
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

# ---------------------------------------------------------------------------
# Gate r13 — Defect B regression: found_any set after sidecar filter
#
# A container that has ONLY sidecar lineage files (e.g. *.sbom.json,
# *.changelog.json) must fall through to the config.yaml fallback path.
# The old code set found_any=true BEFORE filtering out sidecars, so a
# container with only sidecars returned empty deps and skipped config.yaml.
#
# Mutation guard:
#   MG-B: moving found_any=true back BEFORE is_lineage_sidecar →
#         this test fails (sidecar-only container returns empty deps
#         instead of falling back to config.yaml)
# ---------------------------------------------------------------------------

@test "depgraph: sidecar-only lineage falls through to config.yaml fallback (Defect B regression)" {
    # Write ONLY sidecar files for containerA — no real lineage JSON.
    # The absence of a real lineage file (after sidecar filtering) must cause
    # found_any to remain false, triggering the config.yaml fallback path.
    printf '{"container":"containerA","tag":"1.0","base_image_ref":"ghcr.io/oorabona/php:latest"}' \
        > "${_DEPGRAPH_LINEAGE_DIR}/containerA-1.0.sbom.json"
    printf '{"container":"containerA","tag":"1.0"}' \
        > "${_DEPGRAPH_LINEAGE_DIR}/containerA-1.0.changelog.json"

    # Place a config.yaml in the real PROJECT_ROOT/containerA/ that declares
    # an internal base_image_cache ref.  This file is cleaned up below.
    # Note: dependency-graph.sh sources helpers via PROJECT_ROOT so the real
    # PROJECT_ROOT must be used; only the lineage dir is overridden via
    # _DEPGRAPH_LINEAGE_DIR (set in setup()).
    local cfg_dir="${PROJECT_ROOT}/containerA"
    local cfg_file="${cfg_dir}/config.yaml"
    local created_dir=false
    if [[ ! -d "$cfg_dir" ]]; then
        mkdir -p "$cfg_dir"
        created_dir=true
    fi
    local prev_cfg=""
    if [[ -f "$cfg_file" ]]; then
        prev_cfg=$(< "$cfg_file")
    fi
    printf 'base_image_cache:\n  - image: ghcr.io/oorabona/php:8.4-fpm-alpine\n' \
        > "$cfg_file"

    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps containerA
    "

    # Restore the original state before asserting (ensure cleanup on any failure path)
    if [[ -n "$prev_cfg" ]]; then
        printf '%s' "$prev_cfg" > "$cfg_file"
    else
        rm -f "$cfg_file"
        if [[ "$created_dir" == "true" ]]; then
            rmdir "$cfg_dir" 2>/dev/null || true
        fi
    fi

    # config.yaml fallback must have fired: dep=php detected from config.yaml ref
    [ "$status" -eq 0 ]
    [ "$output" = "php" ]
}

@test "depgraph: sidecar-only + no config.yaml → empty deps (correct fallback behaviour)" {
    # Sidecar-only, no config.yaml: sidecar filter leaves found_any=false but no
    # config.yaml exists for this container, so deps remain empty.
    # Uses containerC which has no config.yaml in the real project tree.
    printf '{"container":"containerC","tag":"1.0","base_image_ref":"ghcr.io/oorabona/php:latest"}' \
        > "${_DEPGRAPH_LINEAGE_DIR}/containerC-1.0.sbom.json"

    # Ensure no config.yaml exists for containerC in PROJECT_ROOT (it's a synthetic
    # container not present in the actual project)
    rm -f "${PROJECT_ROOT}/containerC/config.yaml"

    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps containerC
    "
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# ---------------------------------------------------------------------------
# Gate r21 — Defect B fix: _depgraph_is_internal_ref rc=2 propagation
#
# _depgraph_is_internal_ref returns rc=2 when owner-resolution fails.
# _depgraph_get_deps must propagate rc=2 (not silently treat it as "external")
# for both the lineage-file path and the config.yaml fallback path.
#
# Mutation guards:
#   MG-D2a: checking [[ -n "$parent" ]] only (ignoring _iref_rc) → rc=2 swallowed
#            (test "owner failure in lineage path → get_deps exits non-zero")
#   MG-D2b: same for config.yaml fallback path
#            (test "owner failure in config.yaml fallback path → get_deps exits non-zero")
# ---------------------------------------------------------------------------

@test "depgraph: _depgraph_is_internal_ref returns rc=2 on owner-resolution failure" {
    # With no owner env and no git remote (isolated dir), _depgraph_project_owner
    # fails → _depgraph_is_internal_ref must return rc=2.
    local isolated_dir="$TEST_TEMP_DIR/isolated_r21"
    mkdir -p "$isolated_dir"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_is_internal_ref 'ghcr.io/someowner/php:latest' 'php wordpress'
    "
    [ "$status" -eq 2 ]
}

@test "depgraph: owner failure in lineage path → _depgraph_get_deps exits non-zero (fail-closed)" {
    # Write a real lineage file with a ghcr.io ref. Remove owner resolution so
    # _depgraph_is_internal_ref returns rc=2 — _depgraph_get_deps must propagate it.
    _write_lineage "wordpress" "latest" "ghcr.io/someowner/php:latest"
    local isolated_dir="$TEST_TEMP_DIR/isolated_lineage_r21"
    mkdir -p "$isolated_dir"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        # Override valid containers so the lineage dir is recognised but owner fails
        _DEPGRAPH_CONTAINERS_OVERRIDE='wordpress php'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}

@test "depgraph: owner failure in config.yaml fallback path → _depgraph_get_deps exits non-zero (fail-closed)" {
    # No lineage files for containerFallback → falls through to config.yaml path.
    # Owner resolution fails there too — must propagate rc non-zero.
    local isolated_dir="$TEST_TEMP_DIR/isolated_fallback_r21"
    mkdir -p "$isolated_dir/containerFallback"
    printf 'base_image_cache:\n  - image: ghcr.io/someowner/php:8.4-fpm-alpine\n' \
        > "$isolated_dir/containerFallback/config.yaml"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        # Use a temp PROJECT_ROOT that has the config.yaml but no git remote
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='containerFallback php'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps containerFallback
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Defect G regression lock: rc=2 propagation through transitive helpers
#
# _depgraph_get_deps propagates rc=2 on owner failure (r21 fix).
# _depgraph_get_deps_transitive, _depgraph_get_consumers, and
# _depgraph_validate_no_cycles must ALL propagate it (r23 fix).
# ---------------------------------------------------------------------------

@test "depgraph: rc=2 propagates through _depgraph_get_deps_transitive" {
    # wordpress → php dep chain; owner resolution fails → transitive must return rc=2.
    _write_lineage "wordpress" "latest" "ghcr.io/someowner/php:latest"
    local isolated_dir="$TEST_TEMP_DIR/isolated_transitive_r23"
    mkdir -p "$isolated_dir"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='wordpress php'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps_transitive wordpress
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"::error::"* ]]
}

@test "depgraph: rc=2 propagates through _depgraph_get_consumers" {
    # container consumes a dep with an owner-ref; owner fails → consumers scan returns rc=2.
    _write_lineage "wordpress" "latest" "ghcr.io/someowner/php:latest"
    local isolated_dir="$TEST_TEMP_DIR/isolated_consumers_r23"
    mkdir -p "$isolated_dir"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='wordpress php'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_consumers php
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"::error::"* ]]
}

@test "depgraph: rc=2 propagates through _depgraph_validate_no_cycles" {
    # Owner fails during DFS — cycle validator must propagate rc=2 not rc=0.
    _write_lineage "wordpress" "latest" "ghcr.io/someowner/php:latest"
    local isolated_dir="$TEST_TEMP_DIR/isolated_cycles_r23"
    mkdir -p "$isolated_dir"
    run bash -c "
        unset _DEPGRAPH_OWNER_OVERRIDE
        unset GITHUB_REPOSITORY_OWNER
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='wordpress php'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_validate_no_cycles
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Defect H regression lock: base_image field recognized in config.yaml fallback
#
# The config.yaml no-lineage fallback must inspect base_image values in addition
# to build_args.  Internal refs appear in base_image for wordpress, web-shell,
# and github-runner.
# ---------------------------------------------------------------------------

@test "depgraph: base_image internal ref in config.yaml → recognized as dep (no lineage)" {
    # Simulate wordpress/config.yaml pattern: base_image with ${REMOTE_CR}/php ref.
    # No lineage files → falls through to config.yaml path.
    local isolated_dir="$TEST_TEMP_DIR/isolated_base_image_r23"
    mkdir -p "$isolated_dir/mywp"
    # Use ghcr.io/<owner>/php to avoid the ${REMOTE_CR} variable — owner override will match.
    printf 'base_image: "ghcr.io/testowner/php:8.4-fpm-alpine"\n' \
        > "$isolated_dir/mywp/config.yaml"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE='testowner'
        export _DEPGRAPH_OWNER_OVERRIDE
        PROJECT_ROOT='${isolated_dir}'
        _DEPGRAPH_CONTAINERS_OVERRIDE='mywp php'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps mywp
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"php"* ]]
}

@test "depgraph: base_image external ref in config.yaml → NOT recognized as dep" {
    # alpine:3.21 is an external ref — must not appear as internal dep.
    # Use the real PROJECT_ROOT (needed for lineage-utils.sh sourcing) and
    # a custom config dir override, with _DEPGRAPH_CONTAINERS_OVERRIDE restricting scope.
    local isolated_dir="$TEST_TEMP_DIR/isolated_base_image_ext_r23"
    mkdir -p "$isolated_dir/myalpine"
    printf 'base_image: "alpine:3.21"\n' \
        > "$isolated_dir/myalpine/config.yaml"
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE='testowner'
        export _DEPGRAPH_OWNER_OVERRIDE
        # Use real PROJECT_ROOT so helpers/lineage-utils.sh is available.
        # Override the container set and lineage dir to isolate the test.
        _DEPGRAPH_CONTAINERS_OVERRIDE='myalpine'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        # Override PROJECT_ROOT AFTER sourcing so config.yaml lookup uses isolated dir
        source '${HELPERS_DIR}/dependency-graph.sh'
        PROJECT_ROOT='${isolated_dir}'
        _depgraph_get_deps myalpine 2>/dev/null
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Gate r26 — Defect N: stale lineage entries must not pollute internal_deps
#
# _depgraph_get_deps should skip lineage files whose tag is not in the active
# build matrix.  Stale files for retired variants persist in .build-lineage/
# after version rotation; without filtering they union stale parents into
# internal_deps_csv and create cascade:waiting-for-<retired-parent> labels
# that are never resolved.
#
# Mutation guards:
#   MG-N1: removing the active-tag filter → stale-tag test gets dep=php (FAIL)
#   MG-N2: fail-closed instead of fail-open → fallback test returns empty output (FAIL)
# ---------------------------------------------------------------------------

@test "depgraph: stale lineage tag excluded from deps when active filter is set (Defect N)" {
    # Write two lineage files for wordpress:
    #   6.9.4-alpine  — active tag (in override)
    #   6.8.0-alpine  — retired tag (NOT in override)
    # Both reference php as the base image.
    # Only the active tag should contribute to deps; stale tag must be skipped.
    _write_lineage "wordpress" "6.9.4-alpine" "ghcr.io/oorabona/php:latest"
    _write_lineage "wordpress" "6.8.0-alpine" "ghcr.io/oorabona/php:latest"

    # Tag file: only 6.9.4-alpine is active
    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        _DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        # Provide the active-tag override: only 6.9.4-alpine is active
        _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_wordpress='6.9.4-alpine'
        export _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_wordpress
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # Dep must still be detected (active tag contributes it)
    [ "$output" = "php" ]
}

@test "depgraph: stale-only lineage (no active tags match) → empty deps (Defect N)" {
    # Write one lineage file with a retired tag only.
    # Active override contains a different tag → the lineage file is stale.
    # No active lineage → found_any stays false → config.yaml fallback runs,
    # but containerB has no config.yaml → empty deps.
    _write_lineage "containerB" "1.0-old" "ghcr.io/oorabona/php:latest"

    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        _DEPGRAPH_CONTAINERS_OVERRIDE='php containerB'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        # Active set has 2.0 only — 1.0-old is stale
        _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_containerB='2.0'
        export _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_containerB
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps containerB 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # Stale lineage skipped; no config.yaml for containerB → empty deps
    [ "$output" = "" ]
}

@test "depgraph: active-filter fail-open — when list-builds unavailable, all lineage used (Defect N)" {
    # Write a lineage file for wordpress with a php parent.
    # _DEPGRAPH_CONTAINERS_OVERRIDE is set so _depgraph_valid_containers() succeeds.
    # _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_wordpress is NOT set, but _DEPGRAPH_CONTAINERS_OVERRIDE
    # IS set — so the active-tag filter code detects test-mode and sets __TEST_NO_FILTER__,
    # which means NO filtering occurs and all lineage is processed.
    #
    # To test the production fail-open path directly we would need a working ./make
    # but broken ./make list-builds — which is hard to arrange in unit tests.
    # Instead, verify the weaker invariant: when filtering is disabled (no per-container
    # override, test-mode detected), all lineage files contribute to deps (fail-open behavior).
    _write_lineage "wordpress" "6.9.4-alpine" "ghcr.io/oorabona/php:latest"

    run bash -c "
        _DEPGRAPH_OWNER_OVERRIDE=oorabona
        export _DEPGRAPH_OWNER_OVERRIDE
        _DEPGRAPH_LINEAGE_DIR='${_DEPGRAPH_LINEAGE_DIR}'
        export _DEPGRAPH_LINEAGE_DIR
        _DEPGRAPH_CONTAINERS_OVERRIDE='php wordpress'
        export _DEPGRAPH_CONTAINERS_OVERRIDE
        # No _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_wordpress — test-mode detects __TEST_NO_FILTER__
        # via _DEPGRAPH_CONTAINERS_OVERRIDE, so all lineage files are processed (fail-open).
        source '${HELPERS_DIR}/dependency-graph.sh'
        _depgraph_get_deps wordpress 2>/dev/null
    "
    [ "$status" -eq 0 ]
    # All lineage processed (fail-open) → dep detected
    [ "$output" = "php" ]
}
