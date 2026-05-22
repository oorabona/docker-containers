#!/usr/bin/env bats

# Unit tests for scripts/audit-base-image-cache.sh
#
# Strategy: source the script (safe after adding the BASH_SOURCE guard) to test
# helper functions directly using temp-dir fixtures.  The main block is gated by
# [[ "${BASH_SOURCE[0]}" == "${0}" ]] so sourcing does not execute it.
#
# Tests:
#   normalize_image_source
#     NIS-01  <unresolved:REMOTE_CR>/ prefix stripped → library/postgres
#     NIS-02  docker.io/ prefix stripped              → library/nginx
#     NIS-03  library/<x> emits bare alias            → ubuntu emitted alongside library/ubuntu
#     NIS-04  bare name untouched                     → ubuntu stays ubuntu
#     NIS-05  plain resolved name (no prefix)         → composer:2.9.8 source
#   is_cached
#     ABA-01  new-style FROM ${REMOTE_CR}/library/postgres → source: library/postgres = CACHED
#     ABA-02  old-style FROM ${BASE_IMAGE}:${VERSION}, build_args.BASE_IMAGE=ubuntu → CACHED (no regression)
#     ABA-03  genuine mismatch (mysql vs library/postgres) → NOT cached
#     ABA-04  FROM docker.io/library/nginx vs source: library/nginx → CACHED
#     ABA-05  REMOTE_CR in build_args (resolves to docker.io then stripped) → CACHED
#     ABA-06  bare source: debian matches FROM ${BASE_IMAGE} resolved to debian → CACHED
#   is_expected_uncached
#     ABA-07  ghcr.io/oorabona/postgres:17-alpine → matches self-ref pattern
#   Full audit run (real repo — integration smoke)
#     SMOKE-01  postgres has no GAP in full audit run

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/audit-base-image-cache.sh"
ORIG_DIR="$BATS_TEST_DIRNAME/../.."

setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR" || exit 1

    # Create a minimal helpers/logging.sh stub so the script can be sourced
    # without the real repo on PATH (source redirects to ORIG_DIR, but the
    # cd "$ROOT_DIR" happens before source when running as a subprocess —
    # for direct sourcing we stub manually).
    mkdir -p helpers
    cp "$ORIG_DIR/helpers/logging.sh" helpers/logging.sh

    # Source the script; the main block is guarded by BASH_SOURCE==0.
    # AUDIT_ROOT is set so the script's cd lands in our test dir.
    AUDIT_ROOT="$TEST_DIR" source "$SCRIPT"
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

# Helper: write a config.yaml fixture
# Usage: write_config <path> <yaml_content>
write_config() {
    local path="$1" yaml="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$yaml" > "$path"
}

# ─── normalize_image_source ───────────────────────────────────────────────────

@test "NIS-01: <unresolved:REMOTE_CR>/ prefix is stripped, leaving library/postgres" {
    run normalize_image_source "<unresolved:REMOTE_CR>/library/postgres"
    [ "$status" -eq 0 ]
    # First line: normalized form
    [[ "${lines[0]}" == "library/postgres" ]]
    # Second line: bare alias (library/ stripped)
    [[ "${lines[1]}" == "postgres" ]]
}

@test "NIS-02: docker.io/ prefix is stripped, leaving library/nginx" {
    run normalize_image_source "docker.io/library/nginx"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "library/nginx" ]]
    [[ "${lines[1]}" == "nginx" ]]
}

@test "NIS-03: library/<x> emits both library/ubuntu and bare ubuntu" {
    run normalize_image_source "library/ubuntu"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "library/ubuntu" ]]
    [[ "${lines[1]}" == "ubuntu" ]]
}

@test "NIS-04: bare name (no prefix) passes through unchanged, no alias emitted" {
    run normalize_image_source "ubuntu"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "ubuntu" ]]
    [ "${#lines[@]}" -eq 1 ]
}

@test "NIS-05: namespaced source (hashicorp/terraform) passes through, no alias" {
    run normalize_image_source "hashicorp/terraform"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "hashicorp/terraform" ]]
    [ "${#lines[@]}" -eq 1 ]
}

# ─── is_cached ────────────────────────────────────────────────────────────────

# ABA-01: new-style — REMOTE_CR not in build_args → resolves to <unresolved:REMOTE_CR>
# The resolved FROM is "<unresolved:REMOTE_CR>/library/postgres:<unresolved:VERSION>"
# After tag strip + normalization it must match source: library/postgres
@test "ABA-01: new-style REMOTE_CR unresolved matches source: library/postgres" {
    write_config "mypostgres/config.yaml" \
'base_image_cache:
  - source: library/postgres
    tags_from_versions: true'

    # Simulate what resolve_image_ref produces when REMOTE_CR not in build_args
    run is_cached "<unresolved:REMOTE_CR>/library/postgres:<unresolved:VERSION>" "mypostgres/config.yaml"
    [ "$status" -eq 0 ]
}

# ABA-02: old-style — FROM ${BASE_IMAGE}:${VERSION}, build_args.BASE_IMAGE=ubuntu
# resolve_image_ref returns "ubuntu:<unresolved:VERSION>"; is_cached must match source: ubuntu
@test "ABA-02: old-style ubuntu matches source: ubuntu (no regression)" {
    write_config "myubuntu/config.yaml" \
'base_image_cache:
  - arg: BASE_IMAGE
    source: ubuntu
    ghcr_repo: ubuntu-base
    tags: ["22.04"]
build_args:
  BASE_IMAGE: "ubuntu"'

    run is_cached "ubuntu:<unresolved:VERSION>" "myubuntu/config.yaml"
    [ "$status" -eq 0 ]
}

# ABA-03: genuine mismatch — mysql resolved from a postgres source cache → NOT cached
@test "ABA-03: genuine mismatch mysql vs source: library/postgres is NOT cached" {
    write_config "mymysql/config.yaml" \
'base_image_cache:
  - source: library/postgres
    tags_from_versions: true'

    run is_cached "mysql:8.0" "mymysql/config.yaml"
    [ "$status" -ne 0 ]
}

# ABA-04: docker.io/ explicit prefix — FROM docker.io/library/nginx vs source: library/nginx
@test "ABA-04: FROM docker.io/library/nginx matches source: library/nginx" {
    write_config "mynginx/config.yaml" \
'base_image_cache:
  - source: library/nginx
    tags_from_versions: true'

    run is_cached "docker.io/library/nginx:<unresolved:VERSION>" "mynginx/config.yaml"
    [ "$status" -eq 0 ]
}

# ABA-05: REMOTE_CR resolved to docker.io via build_args
@test "ABA-05: REMOTE_CR resolved to docker.io, then stripped, matches library/postgres" {
    write_config "pgwithargs/config.yaml" \
'base_image_cache:
  - source: library/postgres
    tags_from_versions: true
build_args:
  REMOTE_CR: "docker.io"'

    # resolve_image_ref would produce "docker.io/library/postgres:<unresolved:VERSION>"
    run is_cached "docker.io/library/postgres:<unresolved:VERSION>" "pgwithargs/config.yaml"
    [ "$status" -eq 0 ]
}

# ABA-06: bare source: debian matches resolved "debian:<unresolved:VERSION>"
@test "ABA-06: bare source: debian matches resolved debian image" {
    write_config "mydebian/config.yaml" \
'base_image_cache:
  - arg: BASE_IMAGE
    source: debian
    ghcr_repo: debian-base
    tags: ["12"]
build_args:
  BASE_IMAGE: "debian"'

    run is_cached "debian:<unresolved:VERSION>" "mydebian/config.yaml"
    [ "$status" -eq 0 ]
}

# ABA-10: cross-registry NO-FALSE-NEGATIVE guard
# A FROM that uses the same path ("library/postgres") but on a non-docker.io
# registry (ghcr.io, quay.io) must NOT match source: library/postgres.
# The normalization must only strip docker.io/ and <unresolved:VAR>/ — never
# an arbitrary third-party registry prefix.
@test "ABA-10: ghcr.io/library/postgres is NOT cached against source: library/postgres (no false negative)" {
    write_config "nfn/config.yaml" \
'base_image_cache:
  - source: library/postgres
    tags_from_versions: true'

    # ghcr.io is not docker.io — must remain a GAP
    run is_cached "ghcr.io/library/postgres:17" "nfn/config.yaml"
    [ "$status" -ne 0 ]

    # Same invariant for quay.io
    run is_cached "quay.io/library/postgres:17" "nfn/config.yaml"
    [ "$status" -ne 0 ]
}

# ─── is_expected_uncached ─────────────────────────────────────────────────────

@test "ABA-07: ghcr.io/oorabona/* self-ref matches expected-uncached pattern" {
    run is_expected_uncached "ghcr.io/oorabona/postgres:17-alpine"
    [ "$status" -eq 0 ]
}

@test "ABA-08: mcr.microsoft.com/* matches expected-uncached pattern" {
    run is_expected_uncached "mcr.microsoft.com/windows/servercore:ltsc2022"
    [ "$status" -eq 0 ]
}

@test "ABA-09: random external image does NOT match expected-uncached pattern" {
    run is_expected_uncached "docker.io/library/mysql:8.0"
    [ "$status" -ne 0 ]
}

# ─── Integration smoke: real audit run ───────────────────────────────────────

# SMOKE-01: run the full audit against the real repo.
# postgres must NOT appear as GAP (new-style FROM ${REMOTE_CR}/library/postgres).
# Old-style containers must still show as cached (no regression).
@test "SMOKE-01: full repo audit — postgres has no GAP, old-style containers still cached" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # postgres must not be reported as a GAP
    local postgres_gaps
    postgres_gaps=$(echo "$output" | awk '$1=="postgres" && $3=="GAP"' 2>/dev/null || true)
    [ -z "$postgres_gaps" ]

    # At least one cached entry must exist (regression: old-style still works)
    [[ "$output" =~ "cached" ]]

    # Summary line must exist and show 0 unexpected gaps
    [[ "$output" =~ "Summary:" ]]
}
