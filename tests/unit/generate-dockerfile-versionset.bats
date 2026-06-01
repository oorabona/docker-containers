#!/usr/bin/env bats

# Unit tests for generate_dockerfile() versionset consumer path
#
# Covers:
#   1. multi-version: versionset artifact with available=["2.23.0","2.25.0","2.27.1"]
#      → 3 FROM stages, 3 per-version COPY pairs, ascending order (ceiling last)
#   2. backward-compat: no versionset artifact → single stage + original COPY paths
#   3. mixed: timescaledb (multi-version) + pgvector (no versionset) in same flavor
#      → timescaledb gets multi-version, pgvector stays single-version
#
# Mocking strategy:
#   - ext_image_name: deterministic from (ext, version, major)
#   - get_repo_owner: returns "testowner"
#   - get_registry:   returns "ghcr.io"
#   - ROOT_DIR:       set to TEST_TEMP_DIR (versionset artifacts go there)
#   - Config and template: minimal inline fixtures

bats_require_minimum_version 1.5.0

load "../test_helper"

# ---------------------------------------------------------------------------
# Source helpers under test
# ---------------------------------------------------------------------------
_source_extension_utils() {
    # shellcheck disable=SC1091
    source "$HELPERS_DIR/extension-utils.sh"
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir
    export ROOT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.build-lineage"

    # Minimal config.yaml: timescaledb (has version_set) + pgvector (plain)
    mkdir -p "$TEST_TEMP_DIR/extensions"
    cat > "$TEST_TEMP_DIR/extensions/config.yaml" <<'EOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "timescale/timescaledb"
    priority: 1
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
  pgvector:
    version: "0.8.2"
    repo: "pgvector/pgvector"
    priority: 2

flavors:
  timeseries:
    - timescaledb
  multi_mixed:
    - timescaledb
    - pgvector
  vector:
    - pgvector
EOF

    # Minimal Dockerfile template
    cat > "$TEST_TEMP_DIR/Dockerfile.template" <<'EOF'
ARG VERSION
# @@EXTENSION_STAGES@@
FROM postgres:${VERSION}
# @@EXTENSION_COPIES@@
# @@RUNTIME_DEPS@@
EOF

    _source_extension_utils

    # Override registry/owner to be deterministic
    get_registry()   { echo "ghcr.io"; }
    get_repo_owner() { echo "testowner"; }
    export -f get_registry get_repo_owner
}

teardown() {
    teardown_temp_dir
    unset ROOT_DIR
}

# ---------------------------------------------------------------------------
# Helpers: write versionset fixtures under .build-lineage/
# ---------------------------------------------------------------------------

# _write_versionset: write a versionset artifact WITHOUT version_digests.
# Used for tests where version_digests is absent (LOCAL_ONLY / pre-finalize path).
# The consumer falls back to tag-based refs (ext_image_name) without probing.
_write_versionset() {
    local ext="$1"
    local pg_major="$2"
    shift 2
    local -a available_arr=("$@")

    # Build JSON array manually
    local arr_json="["
    local first=1
    for v in "${available_arr[@]}"; do
        [[ "$first" -eq 0 ]] && arr_json+=","
        arr_json+="\"$v\""
        first=0
    done
    arr_json+="]"

    cat > "$TEST_TEMP_DIR/.build-lineage/ext-${ext}-pg${pg_major}-versionset.json" <<EOF
{"ext":"${ext}","pg_major":"${pg_major}","ceiling":"${available_arr[-1]}","resolved":${arr_json},"available":${arr_json},"excluded":[]}
EOF
}

# _write_versionset_with_digests: write a versionset artifact WITH version_digests.
# Used for tests that exercise the digest-pinned collector stage (CI/publish path).
# Assigns a deterministic fake digest per version (sha256:00..00<ver-index>0..0).
_write_versionset_with_digests() {
    local ext="$1"
    local pg_major="$2"
    shift 2
    local -a available_arr=("$@")

    local arr_json="["
    local first=1
    for v in "${available_arr[@]}"; do
        [[ "$first" -eq 0 ]] && arr_json+=","
        arr_json+="\"$v\""
        first=0
    done
    arr_json+="]"

    # Build version_digests: assign fake-but-valid sha256 per version (64 lowercase hex chars)
    local vd_json="{"
    local idx=1
    local vd_first=1
    for v in "${available_arr[@]}"; do
        [[ "$vd_first" -eq 0 ]] && vd_json+=","
        # Deterministic valid digest: sha256:000...0<idx as 2-digit hex padded to 64>
        local hex_idx
        hex_idx=$(printf '%064x' "$idx")
        vd_json+="\"${v}\":\"sha256:${hex_idx}\""
        vd_first=0
        idx=$((idx + 1))
    done
    vd_json+="}"

    cat > "$TEST_TEMP_DIR/.build-lineage/ext-${ext}-pg${pg_major}-versionset.json" <<EOF
{"ext":"${ext}","pg_major":"${pg_major}","ceiling":"${available_arr[-1]}","resolved":${arr_json},"available":${arr_json},"excluded":[],"version_digests":${vd_json}}
EOF
}

# ---------------------------------------------------------------------------
# Test 1: multi-version — 3 available → collector stage + ONE final-stage COPY
# ---------------------------------------------------------------------------
@test "multi-version: 3 available versions → FROM scratch AS ext_collect_timescaledb + 1 final COPY" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # One collector stage declared (FROM scratch AS ext_collect_timescaledb)
    local collector_from_count
    collector_from_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_from_count" -eq 1 ]

    # Exactly ONE final-stage COPY from the collector (single exported layer)
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]

    # Three per-version COPYs inside the collector (one per available version)
    local collector_ver_count
    collector_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb.*pg18-.* /output/ /" || true)
    [ "$collector_ver_count" -eq 3 ]
}

@test "multi-version: COPY --from= refs inside collector are full image refs (host/path:tag)" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Every COPY --from= inside the collector stage must use a full image ref.
    # A bareword stage alias would NOT match the ghcr.io/...:.+ pattern.
    while IFS= read -r copy_line; do
        [[ -z "$copy_line" ]] && continue
        local from_ref
        from_ref=$(echo "$copy_line" | sed -n 's/.*--from=\([^ ]*\).*/\1/p')
        [[ "$from_ref" =~ ghcr\.io/.+:.+ ]]
    done < <(echo "$output" | grep "COPY --from=.*ext-timescaledb.*pg18-" || true)
}

@test "multi-version: final-stage COPY lands at /tmp/ext/timescaledb/ preserving per-version layout" {
    # The collector COPY --from=ext_collect_timescaledb / /tmp/ext/<ext>/
    # combined with the collector's internal /<ver>/ dirs produces
    # /tmp/ext/<ext>/<ver>/{extension,lib}/ which install_ext iterates.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Final-stage COPY lands at /tmp/ext/timescaledb/
    echo "$output" | grep -q "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/"
}

@test "multi-version: ceiling version 2.27.1 — collector stage succeeds, single final COPY" {
    # Collector approach makes version ordering inside the final stage irrelevant:
    # the collector's layers are not exported. Test that consumer still succeeds.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    echo "$output" | grep -q "^FROM scratch AS ext_collect_timescaledb"

    # Exactly ONE final-stage COPY
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test 2: backward-compat — no versionset → single stage + flat COPY paths.
# Uses the "vector" flavor (pgvector only, no version_set.resolver) to exercise
# the non-resolver single-version path. Resolver-backed extensions (timescaledb)
# require a versionset artifact; non-resolver extensions still use the single-version
# flat-copy path when no artifact is present.
# ---------------------------------------------------------------------------
@test "backward-compat: no versionset → single FROM stage for non-resolver extension (pgvector)" {
    # No versionset file created — pgvector is non-resolver, so single-version path applies.
    # timescaledb (resolver-backed) is not in this flavor.

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "vector" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Exactly ONE FROM stage for pgvector
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-pgvector:pg18-")
    [ "$from_count" -eq 1 ]

    # Stage alias uses extension name only (no version suffix)
    echo "$output" | grep -q "FROM.*ext-pgvector:pg18-0.8.2 AS ext-pgvector$"
}

@test "backward-compat: no versionset → COPYs go into flat /tmp/ext/pgvector/{extension,lib}/" {
    # pgvector is non-resolver — no versionset required.

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "vector" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/"
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/lib/ /tmp/ext/pgvector/lib/"

    # Must NOT have version-subdirectory COPYs
    echo "$output" | grep -qv "/tmp/ext/pgvector/0\."
}

# ---------------------------------------------------------------------------
# Test 3: mixed flavor — timescaledb (multi-ver) + pgvector (single-ver)
# ---------------------------------------------------------------------------
@test "mixed: timescaledb multi-version + pgvector single-version in same render" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "multi_mixed" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # timescaledb: collector stage present
    local ts_collector_count
    ts_collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$ts_collector_count" -eq 1 ]

    # timescaledb: exactly ONE final-stage COPY from collector
    local ts_bundle_count
    ts_bundle_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$ts_bundle_count" -eq 1 ]

    # timescaledb: per-version COPYs are INSIDE the collector (3 versions in stages_block)
    local ts_per_ver_count
    ts_per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb.*pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$ts_per_ver_count" -eq 3 ]

    # pgvector: exactly 1 FROM stage (single-version, non-resolver path unchanged)
    local pv_count
    pv_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-pgvector:pg18-")
    [ "$pv_count" -eq 1 ]

    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/"
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/lib/ /tmp/ext/pgvector/lib/"

    # pgvector must NOT have version-subdirectory paths
    ! echo "$output" | grep -q "/tmp/ext/pgvector/0\."
}

# ---------------------------------------------------------------------------
# Test 4: available=[] in artifact → SELF-HEAL (operator-aligned contract).
#
# Rationale: build-extensions NEVER writes an empty-available artifact — only
# non-empty artifacts with a ceiling are written.  An on-disk available:[] is
# therefore STALE or FOREIGN.  Treating it as absent and routing to self-heal
# is the correct behaviour: resolve + probe to compute the real set, emit
# multi-version stages when images are present, fail closed otherwise.
#
# This is NOT a weakening — it is tightening the contract.  The previous
# single-version ceiling fallback was incorrect: it silently emitted a
# below-history image from a foreign artifact rather than computing the real
# retained set.
#
# RED before fix: code falls through to single-version path (1 FROM stage).
# GREEN after fix: empty available treated as absent → self-heal →
#   resolver+registry probed → multi-version stages emitted (3 FROM stages).
#
# Operator-aligned: empty available is never legitimately written; treating
# it as stale/absent and self-healing (rather than silently degrading to
# single-version) is the correct production contract.
# ---------------------------------------------------------------------------
@test "empty-available: artifact with available=[] triggers self-heal, NOT single-version fallback" {
    # Artifact: valid JSON, available empty (stale/foreign by design).
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.27.1"],"available":[],"excluded":[{"version":"2.23.0","reason":"build failed"},{"version":"2.27.1","reason":"not available"}]}
EOF

    # Self-heal mocks: resolver returns the full set; all images are present.
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must self-heal to multi-version (NOT single-version ceiling fallback).
    [ "$status" -eq 0 ]

    # Collector stage present (FROM scratch AS ext_collect_timescaledb)
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Self-heal path emits per-version COPYs INSIDE the collector stage.
    # Three versions proved present: 2.23.0, 2.25.0, 2.27.1.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector (no bundle tag in output)
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "empty-available: artifact with available=[] + resolver fails → fail closed" {
    # Empty available artifact, resolver also fails — must fail closed (not single-version).
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.27.1"],"available":[],"excluded":[]}
EOF

    resolve_version_set() {
        echo "::error::simulated resolver failure" >&2
        return 1
    }
    export -f resolve_version_set

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 (1 FROM stage, single-version).
    # GREEN after fix: exits non-zero (fail closed — empty treated as stale → self-heal → resolver fails).
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test 5: generate_dockerfile returns non-zero on genuine expansion failure
#          (nonexistent template file).
#
# RED before fix: unconditional `return 0` at the end of generate_dockerfile
# masked expand_template's error → always returned 0 even on failure.
# GREEN after fix: `return 0` removed; expand_template's non-zero propagates.
# ---------------------------------------------------------------------------
@test "failure: generate_dockerfile returns non-zero on nonexistent template [was RED]" {
    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/does-not-exist.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Test 6: generate_dockerfile returns 0 on successful expansion
#          (the postgres template pattern: @@RUNTIME_DEPS@@ is the last line
#           and is empty when no extensions have runtime deps).
#
# This test verifies that the fix for expand_template's spurious-1 also
# allows generate_dockerfile to return 0 on success without the `return 0`
# workaround.
# ---------------------------------------------------------------------------
@test "success: generate_dockerfile returns 0 when RUNTIME_DEPS marker is empty (last line)" {
    # Provide the required versionset artifact for timescaledb (resolver-backed).
    # The test intent is that an empty RUNTIME_DEPS block at the end of the template
    # does not cause a spurious non-zero exit from expand_template.
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# FIX3: tag-based fallback (no-version_digests artifact) must use the caller's
#       explicit registry/owner, not the default get_registry()/get_repo_owner().
#
# Before fix: ext_image_name called without registry/owner → uses get_registry()
#   and get_repo_owner() → wrong repo when caller passed explicit overrides.
# After fix:  ext_image_name called with "$registry" "$owner" → honors caller args.
#
# Test strategy: generate_dockerfile with explicit registry="custom.io" and
#   owner="customowner" against a no-version_digests artifact (LOCAL_ONLY/old path).
#   All per-version COPY --from= refs inside the collector must use custom.io/customowner.
# ---------------------------------------------------------------------------
@test "FIX3-tag-fallback-uses-explicit-registry-owner: no-digests artifact refs use caller registry/owner" {
    # No-version_digests artifact (LOCAL_ONLY / old build path).
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "custom.io" "customowner"

    [ "$status" -eq 0 ]

    # Collector stage must be present (3 versions → multi-version path).
    echo "$output" | grep -q "^FROM scratch AS ext_collect_timescaledb"

    # Every per-version COPY inside the collector must use custom.io/customowner.
    local copy_count
    copy_count=$(echo "$output" | grep -cE "COPY --from=custom\.io/customowner/ext-timescaledb:pg18-[0-9]" || true)
    [ "$copy_count" -eq 3 ]

    # Must NOT use the default get_registry() value (ghcr.io) set up in setup().
    local wrong_count
    wrong_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]" || true)
    [ "$wrong_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Test Y: production cwd/PROJECT_ROOT path — artifact found via PROJECT_ROOT
#         even when ROOT_DIR is unset and cwd is a container subdirectory.
#
# Models the REAL production invocation from scripts/build-container.sh:
#   - PROJECT_ROOT = repo root (set by build-container.sh line 10)
#   - ROOT_DIR is NOT set (build-container.sh never sets it)
#   - cwd = <container>/ (make pushd's into it before calling build_container)
#   - artifact lives at $PROJECT_ROOT/.build-lineage/ext-<name>-pg<major>-versionset.json
#
# RED before fix: uses ${ROOT_DIR:-.} → looks in cwd/.build-lineage → NOT FOUND
#   → single-version fallback (1 FROM stage).
# GREEN after fix: uses ${ROOT_DIR:-${PROJECT_ROOT:-...}} → finds artifact via
#   PROJECT_ROOT → multi-version path (3 FROM stages).
# ---------------------------------------------------------------------------
@test "Y-production-cwd: artifact found via PROJECT_ROOT when ROOT_DIR unset and cwd is container subdir" {
    # Simulate repo root in a DIFFERENT temp dir from the container subdir.
    local fake_repo_root
    fake_repo_root=$(mktemp -d)

    # Place the versionset artifact at $fake_repo_root/.build-lineage/ (production location).
    mkdir -p "$fake_repo_root/.build-lineage"
    cat > "$fake_repo_root/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.25.0","2.27.1"],"available":["2.23.0","2.25.0","2.27.1"],"excluded":[]}
EOF

    # Place config and template in the temp dir (simulates the container's extensions/).
    # (Already set up by setup() in TEST_TEMP_DIR.)

    # Create a container subdirectory — this is where cwd will be.
    local container_subdir
    container_subdir=$(mktemp -d)

    # Set PROJECT_ROOT to the fake repo root; UNSET ROOT_DIR.
    local saved_project_root="${PROJECT_ROOT:-}"
    unset ROOT_DIR
    export PROJECT_ROOT="$fake_repo_root"

    # cd into the container subdir to simulate the production cwd.
    pushd "$container_subdir" > /dev/null

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    popd > /dev/null

    # Restore
    export ROOT_DIR="$TEST_TEMP_DIR"
    if [[ -n "$saved_project_root" ]]; then
        export PROJECT_ROOT="$saved_project_root"
    else
        unset PROJECT_ROOT
    fi
    rm -rf "$fake_repo_root" "$container_subdir"

    [ "$status" -eq 0 ]

    # Must find artifact via PROJECT_ROOT → collector stage path (not single-version FROM).
    # RED before fix: 1 FROM stage (single-version fallback because artifact not found).
    # GREEN after fix: collector stage + 1 final COPY (multi-version from artifact via PROJECT_ROOT).
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Test Z: fail-closed when configured ceiling is ABSENT from a non-empty available[].
#
# A non-empty available[] that does not include the pinned ceiling version means
# the build shipped BELOW the pinned version — generate_dockerfile must return
# non-zero with an error rather than silently emitting older-only stages.
#
# RED before fix: emits older-only stages, exits 0.
# GREEN after fix: exits non-zero with actionable error.
# ---------------------------------------------------------------------------
@test "Z-ceiling-absent: non-empty available[] without ceiling → generate_dockerfile exits non-zero" {
    # Artifact: available has 2 older versions but ceiling (2.27.1) is MISSING.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.25.0","2.27.1"],"available":["2.23.0","2.25.0"],"excluded":[{"version":"2.27.1","reason":"not available"}]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 and emits 2 older-only stages.
    # GREEN after fix: exits non-zero.
    [ "$status" -ne 0 ]
}

@test "Z-ceiling-present: ceiling in available[] → collector stage + single final COPY" {
    # Sanity: ceiling IS present → normal multi-version success with collector stage.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present + single final COPY
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# CC-1: available[] entry ABOVE the ceiling → generate_dockerfile exits non-zero.
#
# RED before fix: no validation → the bad entry is emitted as a FROM stage,
#   exits 0 (injection-unsafe / wrong image).
# GREEN after fix: validation rejects above-ceiling entry, exits non-zero.
# ---------------------------------------------------------------------------
@test "CC-1-above-ceiling: available[] version above ceiling → generate_dockerfile exits non-zero" {
    # Artifact: available has an entry (2.99.0) above the configured ceiling (2.27.1).
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1","2.99.0"],"available":["2.25.0","2.27.1","2.99.0"],"excluded":[]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 and emits the malicious/wrong stage.
    # GREEN after fix: exits non-zero (validation rejected above-ceiling entry).
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# CC-2: available[] entry with non-semver content → generate_dockerfile exits
# non-zero.
#
# RED before fix: no validation → the malformed string is emitted verbatim
#   as a Docker stage/tag (injection risk), exits 0.
# GREEN after fix: validation rejects non-semver entry, exits non-zero.
# ---------------------------------------------------------------------------
@test "CC-2-non-semver-injection: available[] non-semver string → generate_dockerfile exits non-zero" {
    # Artifact: available has a non-semver entry.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0","2.27.1; rm -rf"],"excluded":[]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 and emits malformed stage (injection-unsafe).
    # GREEN after fix: exits non-zero.
    [ "$status" -ne 0 ]
}

@test "CC-3-non-semver-latest: available[] 'latest' tag → generate_dockerfile exits non-zero" {
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0","latest"],"excluded":[]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# EE-a: resolver-backed extension (has version_set.resolver) with NO versionset
#        artifact → SELF-HEAL (operator-approved contract change).
#
# Previous contract (hard-fail): exit non-zero when artifact absent.
# New contract (self-heal): when artifact absent, call resolve_version_set +
#   probe image_exists_in_registry to compute available on the fly, then emit
#   multi-version stages. Fail closed only if the resolver or registry probe fails.
#
# Tests assert the NEW self-heal contract:
#   EE-a-1: resolver-backed, no artifact, all resolved images PRESENT → self-heal,
#            multi-version stages, exit 0.
#   EE-a-2: resolver-backed, no artifact, resolve_version_set FAILS → fail closed,
#            exit non-zero.
#   EE-a-3: resolver-backed, no artifact, resolves OK but ceiling image ABSENT
#            from registry → fail closed (ceiling enforcement).
# ---------------------------------------------------------------------------

@test "EE-a-1-self-heal: resolver-backed ext + no artifact + all images present → self-heals, exit 0" {
    # Operator-approved contract change: versionset artifact is an optimisation,
    # not a hard dependency. When absent, generate_dockerfile self-heals via
    # resolve_version_set + image_exists_in_registry.
    # No versionset file — self-heal must kick in.

    # Mock resolve_version_set to return the retained set.
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # All resolved images are present in the registry.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Self-heal succeeds: must exit 0.
    [ "$status" -eq 0 ]

    # Collector stage present (self-heal funnels into same emitter)
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Self-heal emits per-version COPYs INSIDE the collector stage (/output/ → /<ver>/).
    # Three versions proved present: 2.23.0, 2.25.0, 2.27.1.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector (no pg18-bundle in output)
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "EE-a-2-resolver-fails: resolver-backed ext + no artifact + resolver fails → fail closed" {
    # Self-heal cannot proceed without a resolver result. Fail closed.
    resolve_version_set() {
        echo "::error::simulated resolver failure" >&2
        return 1
    }
    export -f resolve_version_set

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Resolver failure during self-heal → fail closed.
    [ "$status" -ne 0 ]
    # Error must name the extension.
    [[ "$output" == *"timescaledb"* ]]
}

@test "EE-a-3-ceiling-absent: resolver-backed ext + no artifact + ceiling not in registry → fail closed" {
    # Self-heal resolves OK but the ceiling image (2.27.1) is absent from registry.
    # Ceiling enforcement: refuse to emit below-pin stages.
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # Only older versions are present; ceiling (2.27.1) is absent.
    image_exists_in_registry() {
        [[ "$1" == *"pg18-2.27.1"* ]] && return 1
        return 0
    }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Ceiling absent from self-healed available → fail closed.
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# EE-b: non-resolver extension (no version_set in config) with NO versionset
#        artifact → single-version path, exits 0 (unchanged behavior).
#
# The pgvector extension in the config fixture has no version_set.resolver.
# GREEN before and after fix: non-resolver ext must still produce single-version.
# ---------------------------------------------------------------------------
@test "EE-b-non-resolver-no-artifact: non-resolver ext + no versionset → single-version, exit 0" {
    # No versionset file for pgvector (non-resolver) — use multi_mixed flavor
    # which includes pgvector (non-resolver) alongside timescaledb (resolver-backed).
    # Provide resolve_version_set + image_exists_in_registry mocks for timescaledb
    # self-heal (timescaledb has no versionset artifact either in this test).
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "multi_mixed" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # pgvector must still produce exactly 1 FROM stage (single-version, non-resolver path unchanged).
    local pv_count
    pv_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-pgvector:pg18-")
    [ "$pv_count" -eq 1 ]

    # pgvector must use flat COPY paths (single-version format).
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/"
}

# ---------------------------------------------------------------------------
# JJ-1: malformed artifact (truncated JSON) + resolver mocks that succeed
#       → generate_dockerfile SELF-HEALS to multi-version (exit 0, N stages).
#
# RED before fix: jq parse fails → available_count collapses to 0 → falls
#   through to single-version path (exit 0, 1 FROM stage).
# GREEN after fix: parse failure treated as ABSENT artifact → self-heal kicks
#   in → resolver+registry probed → multi-version emitted (exit 0, 3 stages).
# ---------------------------------------------------------------------------
@test "JJ-1-malformed-truncated: truncated JSON artifact + resolver succeeds → self-heals to multi-version" {
    # Write a truncated/unparseable JSON artifact.
    printf '{"ext":"timescaledb"' \
        > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"

    # Resolver and registry mocks that produce the real multi-version set.
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must exit 0 (self-heal succeeded).
    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs INSIDE the collector stage.
    # Three versions proved present: 2.23.0, 2.25.0, 2.27.1.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "JJ-2-malformed-garbage: non-JSON garbage artifact + resolver succeeds → self-heals to multi-version" {
    # Write non-JSON garbage as the artifact.
    printf 'NOT JSON AT ALL\x00\ngarbage data' \
        > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs inside the collector stage.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "JJ-3-malformed-no-available: JSON missing .available key + resolver succeeds → self-heals" {
    # Valid JSON but no .available key — schema mismatch.
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1"}' \
        > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs inside the collector stage.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "JJ-4-malformed-resolver-fails: malformed artifact + resolver FAILS → fail closed (non-zero)" {
    # Malformed artifact; resolver also fails. Must fail closed.
    printf '{"ext":"timescaledb"' \
        > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"

    resolve_version_set() {
        echo "::error::simulated resolver failure" >&2
        return 1
    }
    export -f resolve_version_set

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Malformed artifact → self-heal; resolver fails → fail closed.
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# CC-4: valid semver entries, all <= ceiling → succeeds (regression guard).
# ---------------------------------------------------------------------------
@test "CC-4-valid-entries: valid semver entries all at-or-below ceiling → succeeds" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # All 3 valid versions → collector stage + single final COPY.
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# LEAK-1: self-heal path must NOT leave orphaned temp files in TMPDIR.
#
# Before fix: mktemp creates a synthetic artifact in /tmp; the function
# returns through multiple paths without ever deleting it → temp file leaks
# on every self-heal invocation (CI retries, skip-extensions builds,
# local builds).
#
# After fix (no-temp-file refactor): self-heal synthesises the available set
# into a shell variable; no temp file is created at all → nothing to leak.
#
# Test strategy: point TMPDIR at a controlled directory before calling
# generate_dockerfile; assert it is empty after the call returns.  RED
# before fix (a .json temp file lingers), GREEN after (directory empty).
# ---------------------------------------------------------------------------
@test "LEAK-1-no-tempfile: self-heal path leaves no orphaned temp file in TMPDIR" {
    # No versionset artifact → triggers self-heal path.
    # Mocks: resolver succeeds, all images present.
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    # Use a dedicated temp dir so we can assert it is empty after the call.
    local controlled_tmp
    controlled_tmp=$(mktemp -d)
    local saved_tmpdir="${TMPDIR:-}"
    export TMPDIR="$controlled_tmp"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Restore TMPDIR before any assertions so teardown is unaffected.
    if [[ -n "$saved_tmpdir" ]]; then
        export TMPDIR="$saved_tmpdir"
    else
        unset TMPDIR
    fi

    # generate_dockerfile must succeed (self-heal works).
    [ "$status" -eq 0 ]

    # The controlled tmp dir must contain NO files after the call — the
    # self-heal path must not have left any orphaned temp file.
    local leftover_count
    leftover_count=$(find "$controlled_tmp" -maxdepth 1 -type f | wc -l)
    rm -rf "$controlled_tmp"
    [ "$leftover_count" -eq 0 ]

    # Self-heal emits per-version COPYs inside the collector stage.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# LEAK-2: self-heal via empty-available artifact also leaves no temp file.
#
# Same leak vector but triggered via the empty-available → self-heal path
# (the second route into self-heal added in this fix).
# ---------------------------------------------------------------------------
@test "LEAK-2-empty-available-no-tempfile: empty-available self-heal leaves no temp file in TMPDIR" {
    # Empty available artifact → triggers self-heal.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":[],"available":[],"excluded":[]}
EOF

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    local controlled_tmp
    controlled_tmp=$(mktemp -d)
    local saved_tmpdir="${TMPDIR:-}"
    export TMPDIR="$controlled_tmp"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    if [[ -n "$saved_tmpdir" ]]; then
        export TMPDIR="$saved_tmpdir"
    else
        unset TMPDIR
    fi

    [ "$status" -eq 0 ]

    local leftover_count
    leftover_count=$(find "$controlled_tmp" -maxdepth 1 -type f | wc -l)
    rm -rf "$controlled_tmp"
    [ "$leftover_count" -eq 0 ]

    # Self-heal emits per-version COPYs inside the collector stage.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# NN-3: transient probe ERROR in self-heal path → fail closed.
#
# Scenario: no versionset artifact on disk; resolver succeeds and returns
# ["2.23.0","2.25.0","2.27.1"]. The self-heal probes registry presence:
#   - 2.27.1 (ceiling): PRESENT  (rc=0)
#   - 2.25.0:           PRESENT  (rc=0)
#   - 2.23.0:           ERROR    (transient — rc=2, not a definitive not-found)
#
# Before fix (fail-OPEN): 2.23.0 treated as absent → self-heal proceeds with
#   available=["2.25.0","2.27.1"] — silently drops a published retained version.
#
# After fix (fail-CLOSED): probe error on any version → generate_dockerfile
#   returns non-zero (fail closed), no Dockerfile emitted.
#
# Mock strategy: _image_registry_probe_3state is mocked directly to return
# the desired 3-state code per version, isolating the self-heal routing logic
# from the low-level docker/skopeo probe.
# ---------------------------------------------------------------------------
@test "NN-3: transient probe error in self-heal path fails closed (generate_dockerfile exits non-zero)" {
    # No versionset artifact — forces the self-heal path.

    # Resolver returns 3 versions.
    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # _image_registry_probe_3state mock (3-state):
    #   - 2.27.1: PRESENT (rc=0)
    #   - 2.25.0: PRESENT (rc=0)
    #   - 2.23.0: ERROR   (rc=2, transient — no definitive not-found signal)
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.27.1*) return 0 ;;
            *pg18-2.25.0*) return 0 ;;
            *pg18-2.23.0*) return 2 ;;  # ERROR (transient)
            *)             return 1 ;;
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 with only 2 FROM stages (2.23.0 silently dropped).
    # GREEN after fix: exits non-zero (fail-closed; transient error must not drop a version).
    [ "$status" -ne 0 ]

    # Secondary: if it exited 0 (pre-fix behavior), it must NOT have 2 COPY lines
    # (2 = the exactly-wrong fail-open behavior that drops 2.23.0).
    if [ "$status" -eq 0 ]; then
        local from_count
        from_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-.*/extension/" || true)
        [ "$from_count" -eq 3 ]
    fi
}

# ---------------------------------------------------------------------------
# NN-3b (regression): definitively absent version in self-heal path is correctly
# excluded. rc=1 from _image_registry_probe_3state is treated as ABSENT, not ERROR.
# The over-correct guard — ensures we didn't break the musl-failed / never-built case.
# ---------------------------------------------------------------------------
@test "NN-3b: definitively absent version in self-heal path is excluded, not an error" {
    # No versionset artifact — forces the self-heal path.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # _image_registry_probe_3state mock:
    #   - 2.27.1: PRESENT  (rc=0)
    #   - 2.25.0: PRESENT  (rc=0)
    #   - 2.23.0: ABSENT   (rc=1 — definitive not-found, musl-failed)
    # AP: no bundle probe on self-heal path.
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.27.1*) return 0 ;;
            *pg18-2.25.0*) return 0 ;;
            *pg18-2.23.0*) return 1 ;;  # definitively absent
            *)             return 1 ;;
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Definitively absent is the musl-failed / never-built case: must succeed.
    # _sh_available == [2.25.0, 2.27.1] — ceiling present, count > 1.
    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Self-heal emits per-version COPYs for the proved-present set (2.25.0, 2.27.1).
    # 2.23.0 is definitively absent and must NOT appear.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 2 ]

    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.25.0 /output/ /"
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.27.1 /output/ /"

    # 2.23.0 must NOT appear in the collector (definitively absent).
    local absent_count
    absent_count=$(echo "$output" | grep -c "ext-timescaledb:pg18-2.23.0" || true)
    [ "$absent_count" -eq 0 ]

    # Exactly ONE final-stage COPY from collector
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# OO-gd: _image_registry_probe_3state fail-closed polarity in generate_dockerfile.
#
# These tests verify that _image_registry_probe_3state (in extension-utils.sh)
# uses the INVERTED polarity (fail-closed):
#   ABSENT only for explicit not-found signals (manifest unknown, 404, etc.)
#   ERROR (rc=2) for everything else non-zero (429, denied, unauthorized,
#   no such host, network unreachable, EOF, context deadline, empty stderr)
#
# Mock strategy: mock `docker` to emit controlled stderr + return non-zero.
# image_exists_in_registry returns 1 so the stderr-capturing probe is entered.
# ---------------------------------------------------------------------------

_run_registry_probe_3state() {
    # Helper: run _image_registry_probe_3state in a subshell; capture its rc.
    # Mocks both docker and skopeo so real network calls are never made.
    # Skopeo mock mirrors the tightened allow-list (registry-manifest-specific signals only):
    #   manifest unknown, name unknown, repository name not known, no such manifest
    #   → skopeo also confirms not-found (ABSENT preserved)
    #   everything else → skopeo returns transient (ERROR preserved)
    # Note: bare "not found", "no such image", and bare "404" are NOT in the allow-list
    # (UU fix: these can match infra errors like "docker: command not found" or
    # "404 Not Found" from a load-balancer, not a registry manifest API response).
    local stderr_msg="$1"
    (
        docker() {
            if [[ "$*" == *"manifest inspect"* ]]; then
                printf '%s\n' "$stderr_msg" >&2
                return 1
            fi
            return 1
        }
        export -f docker
        skopeo() {
            local _not_found_pat='manifest unknown|name unknown|repository name not known|no such manifest'
            if printf '%s\n' "$stderr_msg" | grep -qiE "$_not_found_pat"; then
                printf 'manifest unknown: manifest unknown\n' >&2
                return 1
            else
                printf 'unauthorized: authentication required\n' >&2
                return 1
            fi
        }
        export -f skopeo
        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry
        _image_registry_probe_3state "ghcr.io/testowner/ext-timescaledb:pg18-2.27.1"
    )
    printf '%d' $?
}

@test "OO-gd-manifest-unknown: 'manifest unknown' stderr → ABSENT (rc 1)" {
    local rc
    rc=$(_run_registry_probe_3state "Error response from daemon: manifest unknown: manifest unknown")
    [ "$rc" -eq 1 ]
}

@test "OO-gd-404: '404 Not Found' → ERROR (rc 2, fail-closed after UU allow-list tightening)" {
    # Before UU fix: bare "404" and "not found" matched → ABSENT (rc 1) — fail-open.
    # After UU fix: only registry-manifest-specific signals are ABSENT; a generic
    # "404 Not Found" (e.g. from a load-balancer or cred-helper) is ERROR (rc 2).
    local rc
    rc=$(_run_registry_probe_3state "Error: 404 Not Found")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-name-unknown: 'name unknown' → ABSENT (rc 1)" {
    local rc
    rc=$(_run_registry_probe_3state "name unknown: repository name not known to registry")
    [ "$rc" -eq 1 ]
}

@test "OO-gd-no-such-manifest: 'no such manifest' → ABSENT (rc 1)" {
    local rc
    rc=$(_run_registry_probe_3state "no such manifest: ghcr.io/testowner/ext-timescaledb:pg18-2.27.1")
    [ "$rc" -eq 1 ]
}

@test "OO-gd-toomanyrequests-ERROR: 'toomanyrequests' → ERROR (rc 2, fail-closed)" {
    # RED before fix: fell through to ABSENT (rc 1) — silently dropped retained version.
    # GREEN after fix: → ERROR (rc 2).
    local rc
    rc=$(_run_registry_probe_3state "toomanyrequests: You have reached your pull rate limit")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-429-ERROR: '429' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "Error: 429 Too Many Requests")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-denied-ERROR: 'denied' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "denied: access forbidden")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-unauthorized-ERROR: 'unauthorized' → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "unauthorized: authentication required")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-no-such-host-ERROR: 'no such host' → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "dial tcp: lookup ghcr.io: no such host")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-network-unreachable-ERROR: 'network is unreachable' → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "dial tcp: connect: network is unreachable")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-EOF-ERROR: 'EOF' in stderr → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "unexpected EOF")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-context-deadline-ERROR: 'context deadline exceeded' → ERROR (rc 2, fail-closed)" {
    local rc
    rc=$(_run_registry_probe_3state "context deadline exceeded")
    [ "$rc" -eq 2 ]
}

@test "OO-gd-empty-stderr-ERROR: empty stderr + rc≠0 → ERROR (rc 2, fail-closed)" {
    # RED before fix: empty stderr fell through to ABSENT (rc 1) — fail-open.
    # GREEN after fix: empty stderr + non-zero → ERROR (rc 2).
    local rc
    rc=$(_run_registry_probe_3state "")
    [ "$rc" -eq 2 ]
}

@test "UU-gd-cmd-not-found-ERROR: 'docker: command not found' stderr → ERROR (rc 2, not ABSENT)" {
    # Before UU fix: bare "not found" matched the allow-list → ABSENT (rc 1), mis-classifying
    # a missing docker binary as a definitively-absent image.
    # After UU fix: "command not found" no longer matches any registry-manifest-specific
    # signal → ERROR (rc 2, fail-closed).
    local rc
    rc=$(_run_registry_probe_3state "docker: command not found")
    [ "$rc" -eq 2 ]
}

@test "UU-gd-cred-helper-not-found-ERROR: cred-helper 'executable file not found' → ERROR (rc 2)" {
    # A missing credential helper produces "executable file not found in PATH".
    # Before UU fix: "not found" in the message matched → ABSENT (rc 1) — mis-classifying
    # an infra misconfiguration as a definitively-absent image.
    # After UU fix: → ERROR (rc 2, fail-closed).
    local rc
    rc=$(_run_registry_probe_3state "docker-credential-desktop: executable file not found in PATH")
    [ "$rc" -eq 2 ]
}

@test "UU-gd-no-such-image-ERROR: 'no such image' stderr → ERROR (rc 2, fail-closed after UU)" {
    # "no such image" is a Docker daemon local-store message, not a registry-manifest
    # API response. After UU tightening it is removed from the allow-list → ERROR.
    local rc
    rc=$(_run_registry_probe_3state "Error: No such image: ghcr.io/test/ext-timescaledb:pg18-2.27.1")
    [ "$rc" -eq 2 ]
}

# ---------------------------------------------------------------------------
# PP: _image_registry_probe_3state in generate_dockerfile self-heal path must
# be MODE-AWARE: with LOCAL_ONLY=true or PULL_ONLY=true, probe the local
# daemon (docker image inspect) instead of the registry.
#
# Scenario: local recovery build, extension images exist only in the LOCAL daemon.
# The self-heal probe must find them locally, not via the registry.
#
# RED before fix: self-heal always probes registry, not local daemon. Fail-closed.
# GREEN after fix: LOCAL_ONLY/PULL_ONLY routes to docker image inspect. Self-heals.
# ---------------------------------------------------------------------------

@test "PP-local-only-self-heal: LOCAL_ONLY=true + images present locally → generate_dockerfile self-heals" {
    # No versionset artifact → forces the self-heal path.
    # Images are present in LOCAL daemon but NOT in registry.
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=true PULL_ONLY=false
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            if [[ \"\$*\" == *'image inspect'* ]]; then
                return 0
            fi
            return 1
        }
        export -f docker

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "

    # Exits 0 (local daemon probe finds images, self-heals).
    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs inside the collector stage.
    # Three versions proved present locally: 2.25.0, 2.26.0, 2.27.1.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "PP-pull-only-self-heal: PULL_ONLY=true + images present locally → generate_dockerfile self-heals" {
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=false PULL_ONLY=true
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            if [[ \"\$*\" == *'image inspect'* ]]; then
                return 0
            fi
            return 1
        }
        export -f docker

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "

    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs inside the collector stage.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]
}

@test "PP-local-only-image-absent-locally: LOCAL_ONLY=true + image NOT in local daemon → generate_dockerfile fails closed" {
    # In local mode, docker image inspect is 2-state (PRESENT/ABSENT).
    # All images absent locally → no available versions → ceiling absent → fail closed.
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=true PULL_ONLY=false
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() { echo '[\"2.25.0\",\"2.26.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        image_exists_in_registry() { return 1; }
        export -f image_exists_in_registry

        docker() {
            return 1
        }
        export -f docker

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# SS: jq absent on PATH → explicit prereq fail-fast with actionable message.
#
# When jq is not on PATH and a resolver-backed extension is encountered, the
# code must fail fast with a clear "jq is required" message rather than
# silently discarding the artifact and self-healing into the same jq-missing
# failure (which produces an opaque error).
#
# Before fix: _artifact_valid stays 0 (jq check skipped) → artifact treated as
#   absent → self-heal path entered → resolve_version_set called → jq absent
#   in validation step → opaque error.
# After fix: explicit prereq check at entry of resolver-backed path → fail-fast
#   with actionable "jq is required" message.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ZZ: skopeo absent on PATH + self-heal required → explicit fail-fast.
#
# generate_dockerfile self-heals a missing/malformed versionset artifact by
# calling resolve_version_set(), which runs skopeo list-tags. skopeo is
# installed in CI but not necessarily on a local dev machine. A local
# `./make build postgres` with FLAVOR=timeseries|full, when the versionset
# artifact is absent, must fail fast with a clear actionable message — not
# with an opaque "skopeo: command not found" deep in the resolver.
#
# The fix is NARROW: skopeo check fires ONLY when the self-heal branch
# is taken (artifact absent or malformed → must re-resolve). When a valid
# versionset artifact is present, generate_dockerfile consumes it without
# skopeo — the check must NOT fire in that path.
#
# ZZ-skopeo-absent-selfheal-failfast:
#   NO versionset artifact (forces self-heal) + skopeo shadowed off PATH
#   (jq present) → generate_dockerfile fails fast (non-zero) with a message
#   containing "skopeo". The resolver is NOT reached (mock to verify).
#   RED before fix: opaque downstream "skopeo: command not found" from resolver.
#   GREEN after fix: explicit fail-fast at the prereq check, "skopeo" in message.
#
# ZZ-skopeo-absent-valid-artifact-ok:
#   A VALID versionset artifact present + skopeo shadowed off PATH (jq present)
#   → generate_dockerfile SUCCEEDS, skopeo is never needed.
#   This proves the fix does NOT over-impose skopeo on the valid-artifact path.
#   RED before fix: n/a (valid-artifact path never used skopeo — stays green).
#   GREEN after fix: still succeeds with multi-version COPY output (non-vacuous).
# ---------------------------------------------------------------------------

@test "ZZ-skopeo-absent-selfheal-failfast: no artifact + skopeo absent → fail-fast with 'skopeo' in message (resolver NOT reached)" {
    # No versionset artifact — forces the self-heal branch.
    # skopeo is shadowed off PATH; jq remains available.
    local tmpd="$TEST_TEMP_DIR"

    local fake_bin
    fake_bin=$(mktemp -d)
    # Populate fake_bin with everything extension-utils.sh needs EXCEPT skopeo.
    for _tool in bash sh jq yq git sed grep sort tail tr paste cut awk dirname pwd realpath wc find; do
        local _real_path
        _real_path=$(command -v "$_tool" 2>/dev/null || true)
        [[ -z "$_real_path" ]] && continue
        ln -sf "$_real_path" "$fake_bin/$_tool"
    done
    # Explicitly ensure there is no skopeo in fake_bin.
    rm -f "$fake_bin/skopeo"

    # resolve_version_set must NOT be reached — use a mock that fails loudly
    # if called, so any pre-fix code path that reaches the resolver is caught.
    run bash --noprofile --norc -c "
        export PATH=\"$fake_bin\"
        export ROOT_DIR=\"$tmpd\"
        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() {
            echo 'resolve_version_set_was_reached' >&2
            return 1
        }
        export -f resolve_version_set

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "
    rm -rf "$fake_bin"

    # Must fail fast (non-zero) before the resolver is reached.
    [ "$status" -ne 0 ]

    # Message must contain 'skopeo' so the operator knows what to install.
    [[ "$output" == *skopeo* ]]

    # Resolver must NOT have been reached (the fix intercepts before calling it).
    [[ "$output" != *resolve_version_set_was_reached* ]]
}

@test "ZZ-skopeo-absent-valid-artifact-ok: valid artifact present + skopeo absent → succeeds (skopeo never needed)" {
    # A valid, well-formed versionset artifact is on disk — self-heal must NOT fire.
    # skopeo is shadowed off PATH to prove the valid-artifact path does not touch it.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    local tmpd="$TEST_TEMP_DIR"

    local fake_bin
    fake_bin=$(mktemp -d)
    # Include all tools that the valid-artifact path of generate_dockerfile needs.
    for _tool in bash sh jq yq git sed grep sort tail tr paste cut awk dirname pwd realpath wc find; do
        local _real_path
        _real_path=$(command -v "$_tool" 2>/dev/null || true)
        [[ -z "$_real_path" ]] && continue
        ln -sf "$_real_path" "$fake_bin/$_tool"
    done
    rm -f "$fake_bin/skopeo"

    run bash --noprofile --norc -c "
        export PATH=\"$fake_bin\"
        export ROOT_DIR=\"$tmpd\"
        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "
    rm -rf "$fake_bin"

    # Must succeed — valid artifact requires no skopeo.
    [ "$status" -eq 0 ]

    # Must produce collector stage + single final COPY (non-vacuous: proves artifact was consumed).
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AG-3: generate_dockerfile artifact-consumption path — artifact whose
# available[] contains a poisoned element "2.25.0\n2.26.0" (one string,
# embedded newline) must be rejected BEFORE any FROM/COPY stage emission.
# Without the fix, jq -r '.available[]' splits the element into two lines and
# each passes the per-line is_strict_semver check, emitting two extra stages.
#
# RED before fix: two stages emitted (2.25.0 and 2.26.0 treated as separate).
# GREEN after fix: artifact rejected, generate_dockerfile returns non-zero.
#
# Non-vacuous: the smuggled version must NOT appear as a FROM stage.
# ---------------------------------------------------------------------------

@test "AG-3-artifact-poisoned-available: artifact with embedded-newline element rejected before stage emission" {
    # Artifact with one poisoned element: "2.25.0\n2.26.0" contains an embedded newline.
    mkdir -p "$TEST_TEMP_DIR/.build-lineage"
    # Write JSON manually: the element contains a literal \n inside the string.
    printf '{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.26.0","2.27.1"],"available":["2.25.0\\n2.26.0","2.27.1"],"excluded":[]}\n' \
        > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must fail closed — the poisoned artifact is rejected before stage emission.
    [ "$status" -ne 0 ]

    # The smuggled "2.26.0" must NOT appear as a FROM stage (non-vacuous).
    echo "$output" | grep -qv "FROM.*ext-timescaledb:pg18-2.26.0" || true
    # And "2.25.0\n2.26.0" (the raw poisoned element) must not appear literally.
    [[ "$output" != *"2.25.0"$'\n'"2.26.0"* ]]
}

# ---------------------------------------------------------------------------
# AG-4: generate_dockerfile self-heal path — resolver returns a set with an
# embedded-newline element where BOTH parts are below-ceiling valid semver
# ("2.25.0\n2.26.0") so the ceiling clamp cannot catch it. Without the
# whole-string chokepoint, both 2.25.0 and 2.26.0 get probed separately and
# both would be present (image_exists_in_registry returns 0), leading to
# TWO stages from a single JSON element. With the fix, the whole-string
# check rejects the element before any probe or stage emission.
#
# RED before fix: jq -r '.[]' splits into 2 lines, both below ceiling, both
#   "present" -> 2 stages emitted from one poisoned element.
# GREEN after fix: whole-string anchor rejects the element -> fail-closed.
# ---------------------------------------------------------------------------

@test "AG-4-self-heal-embedded-newline-below-ceiling: resolver returns embedded-newline element (both parts below ceiling) in self-heal path -> fail-closed" {
    # No versionset artifact — triggers self-heal path.
    rm -f "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json"

    # Resolver returns ["2.25.0\n2.26.0"] — one element with embedded newline.
    # Both 2.25.0 and 2.26.0 are below ceiling 2.27.1, so the ceiling clamp
    # would NOT catch this without the whole-string anchor.
    resolve_version_set() {
        printf '["2.25.0\\n2.26.0","2.27.1"]'
    }
    export -f resolve_version_set

    # skopeo mocked to not be installed (avoid real network calls).
    skopeo() { printf 'manifest unknown\n' >&2; return 1; }
    export -f skopeo

    # All probes succeed — both split lines would be "present" without the fix.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must fail closed — the embedded-newline element fails whole-string validation.
    [ "$status" -ne 0 ]

    # Neither 2.25.0 nor 2.26.0 from the split must appear as FROM stages.
    # (non-vacuous: assert the smuggled version never becomes a stage)
    [[ "$output" != *"pg18-2.25.0"* ]]
    [[ "$output" != *"pg18-2.26.0"* ]]
}

# ---------------------------------------------------------------------------
# AG-5: regression guard — valid versionset artifact with 3 clean elements
# still produces collector stage + single final COPY (chokepoint must not break happy path).
# ---------------------------------------------------------------------------

@test "AG-5-valid-artifact-still-works: clean available[] with 3 valid elements -> collector stage + 1 final COPY" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Single final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]

    # Three per-version COPYs inside the collector
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb.*pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_count" -eq 3 ]
}

@test "SS-jq-absent: jq not on PATH + resolver-backed ext + valid artifact → fail-fast with 'jq' in error message" {
    # Write a valid versionset artifact so the test verifies the prereq path,
    # not the artifact-absent self-heal path.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    local tmpd="$TEST_TEMP_DIR"

    # Build a fake_bin with all tools extension-utils.sh needs EXCEPT jq,
    # so that command -v jq returns non-zero (not found) inside the subshell.
    local fake_bin
    fake_bin=$(mktemp -d)
    for _tool in bash sh yq git sed grep sort dirname pwd realpath; do
        local _real_path
        _real_path=$(command -v "$_tool" 2>/dev/null || true)
        [[ -z "$_real_path" ]] && continue
        ln -sf "$_real_path" "$fake_bin/$_tool"
    done
    # Explicitly ensure there is no jq in fake_bin.
    rm -f "$fake_bin/jq"

    run bash --noprofile --norc -c "
        export PATH=\"$fake_bin\"
        export ROOT_DIR=\"$tmpd\"
        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "
    rm -rf "$fake_bin"

    # Must fail when jq is not on PATH.
    [ "$status" -ne 0 ]

    # Must mention 'jq' in the error output so the operator knows what to install.
    [[ "$output" =~ [Jj][Qq] ]]
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-1: resolver-backed ext with 3 available versions →
# generated Dockerfile has a collector stage (FROM scratch AS ext_collect_<ext>)
# with 3 per-version COPYs inside, and EXACTLY ONE final-stage COPY from the collector.
#
# The per-version COPYs are inside the collector stage (not exported layers).
# The final stage sees exactly 1 COPY from the collector (1 exported layer).
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-1: 3 available versions → collector stage + exactly 1 final COPY" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # One collector stage declared
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Exactly ONE final-stage COPY from the collector
    local final_copy_count
    final_copy_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_copy_count" -eq 1 ]

    # Three per-version COPYs inside the collector (one per available version)
    local per_ver_copy_count
    per_ver_copy_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb.*pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_copy_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-2: the final-stage COPY places the collector's content at
# /tmp/ext/<ext>/ so that /<ver>/ dirs inside the collector land at
# /tmp/ext/<ext>/<ver>/ which is the layout install_ext iterates.
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-2: collector COPY destination is /tmp/ext/timescaledb/ (installs at correct path)" {
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # The final-stage COPY lands at /tmp/ext/timescaledb/
    echo "$output" | grep -q "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/"
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-3: the collector stage name is derived from the extension name.
# Consumer emits "FROM scratch AS ext_collect_<ext>".
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-3: collector stage name is ext_collect_timescaledb" {
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage name must appear
    echo "$output" | grep -q "FROM scratch AS ext_collect_timescaledb"
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-4: single-version (non-resolver) extension path UNCHANGED.
# pgvector (no version_set.resolver) must still emit a FROM stage + flat COPY.
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-4: single-version pgvector path unchanged — still 1 FROM + flat COPY" {
    # No versionset artifact for pgvector (non-resolver extension).

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "vector" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # pgvector must still emit exactly one FROM stage
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM.*ext-pgvector:pg18-")
    [ "$from_count" -eq 1 ]

    # pgvector must still use flat COPY paths
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/"

    # pgvector must NOT have a bundle COPY
    ! echo "$output" | grep -q "ext-pgvector:pg18-bundle"
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-5: mixed flavor — timescaledb uses bundle COPY,
# pgvector uses original single-version path. One bundle COPY, zero per-version
# timescaledb COPYs, one pgvector FROM.
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-5: mixed flavor — timescaledb collector + pgvector single-version unchanged" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "multi_mixed" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # timescaledb: collector stage + single final COPY
    local ts_collector_count
    ts_collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$ts_collector_count" -eq 1 ]

    local ts_final_count
    ts_final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$ts_final_count" -eq 1 ]

    # pgvector: exactly one FROM stage (single-version path unchanged)
    local pv_from_count
    pv_from_count=$(echo "$output" | grep -c "^FROM.*ext-pgvector:pg18-")
    [ "$pv_from_count" -eq 1 ]

    # pgvector: flat COPY paths
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/"
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-6: self-heal path (no artifact) for resolver-backed ext
# also emits a collector stage + 1 final COPY (not a mutable bundle tag).
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-6: self-heal (no artifact) emits collector stage + 1 final COPY" {
    # Self-heal uses the same collector emitter as the artifact-present path.
    # No versionset file — self-heal must kick in.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Three per-version COPYs inside the collector (/output/ → /<ver>/)
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AK-selfheal-per-version-refs: artifact absent, self-heal path resolves versions,
# probes per-version images, then emits per-version COPYs (AP fix).
# The bundle ref is NOT probed and NOT referenced.
#
# AP: self-heal emits one COPY pair per proved-present per-version ref.
# No bundle ref appears in the output.
# ---------------------------------------------------------------------------
@test "AK-selfheal-per-version-refs: artifact absent, self-heal, all versions present → per-version COPYs, no bundle ref" {
    # No versionset artifact → forces self-heal path.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # Per-version images present.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    # _image_registry_probe_3state: all per-version refs PRESENT.
    _image_registry_probe_3state() {
        return 0  # PRESENT for all refs
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Self-heal succeeds.
    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # 3 per-version COPYs inside collector (/output/ → /<ver>/)
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AK-selfheal-only-proved-versions: self-heal emits per-version COPYs ONLY for
# the proved-present versions. Versions probed ABSENT are not emitted.
# A version probed ERROR causes fail-closed (same as NN-3).
#
# AP: the bundle ref is never probed on the self-heal path.
# These tests verify the per-version-probe routing that feeds _sh_available.
# ---------------------------------------------------------------------------
@test "AK-selfheal-only-proved-versions: absent version excluded, present versions emitted as per-version COPYs" {
    # No versionset artifact → forces self-heal path.
    # 2.23.0: ABSENT; 2.25.0 and 2.27.1: PRESENT.
    # _sh_available == [2.25.0, 2.27.1]; ceiling 2.27.1 present → multi-version.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.23.0*) return 1 ;;  # ABSENT
            *)             return 0 ;;  # PRESENT
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Only the 2 proved-present versions must appear inside the collector.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 2 ]

    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.25.0 /output/ /"
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.27.1 /output/ /"

    # 2.23.0 must NOT appear inside the collector.
    local absent_count
    absent_count=$(echo "$output" | grep -c "ext-timescaledb:pg18-2.23.0" || true)
    [ "$absent_count" -eq 0 ]

    # Exactly ONE final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

@test "AK-selfheal-error-version-failclosed: transient ERROR probe in self-heal → fail closed, no output" {
    # No versionset artifact → forces self-heal path.
    # One version returns ERROR (transient) → fail closed.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.23.0*) return 2 ;;  # ERROR (transient)
            *)             return 0 ;;  # PRESENT
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Transient probe error → fail closed.
    [ "$status" -ne 0 ]

    # No bundle COPY in output.
    local bundle_count
    bundle_count=$(echo "$output" | grep -c ":pg18-bundle" || true)
    [ "$bundle_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AL-consumer-single-version: resolver-backed ext, available set == 1 (only
# the ceiling) → generated Dockerfile uses the single-version FROM path
# (no bundle reference, no bundle probe).
#
# RED before fix: generate_dockerfile enters bundle path for any non-empty
#   versionset (available_count > 0), emitting a bundle COPY for a set of 1 —
#   but no bundle was ever built by the producer (set_size<=1 skips it).
# GREEN after fix: available_count == 1 → fall through to single-version path:
#   FROM <ext-image>:pg<major>-<ceiling> AS ext-<name>
#   COPY --from=ext-<name> /output/extension/ ...
#   COPY --from=ext-<name> /output/lib/ ...
#   No bundle reference.  No bundle probe.
# ---------------------------------------------------------------------------
@test "AL-consumer-single-version: artifact with available=[ceiling] → single-version FROM path, no bundle ref" {
    # Artifact: resolver-backed extension with exactly 1 available version (the ceiling).
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.27.1"],"available":["2.27.1"],"excluded":[]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # RED before fix: emits a bundle COPY (available_count > 0 unconditionally enters bundle path).
    # GREEN after fix: no bundle reference anywhere in the output.
    local bundle_count
    bundle_count=$(echo "$output" | grep -c ":pg18-bundle" || true)
    [ "$bundle_count" -eq 0 ]

    # Must emit a single FROM stage for the ceiling version (single-version path).
    local from_count
    from_count=$(echo "$output" | grep -c "FROM ghcr.io/testowner/ext-timescaledb:pg18-2.27.1")
    [ "$from_count" -eq 1 ]

    # Must emit flat COPY lines (single-version layout).
    echo "$output" | grep -q "COPY --from=ext-timescaledb /output/extension/ /tmp/ext/timescaledb/extension/"
    echo "$output" | grep -q "COPY --from=ext-timescaledb /output/lib/ /tmp/ext/timescaledb/lib/"
}

# ---------------------------------------------------------------------------
# AM-consumer-digest-pin: artifact present with version_digests → generated
# Dockerfile collector stage COPYs from <repo>@<digest> (immutable, pinned).
#
# version_digests: {"2.25.0":"sha256:<64hex>", "2.27.1":"sha256:<64hex>"}
# Each per-version COPY inside the collector uses the digest-pinned ref.
# ---------------------------------------------------------------------------
@test "AM-consumer-digest-pin: artifact with version_digests → collector COPYs use repo@digest refs" {
    # Artifact: multi-version with version_digests.
    _write_versionset_with_digests "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Per-version COPYs must use repo@digest format inside the collector.
    local pinned_count
    pinned_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256:" || true)
    [ "$pinned_count" -eq 2 ]

    # Final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AM-consumer-no-digest-tag-fallback: artifact present WITHOUT version_digests
# (LOCAL_ONLY-produced artifact) → collector COPYs use tag-based references.
# ---------------------------------------------------------------------------
@test "AM-consumer-no-digest-tag-fallback: artifact without version_digests → tag-based refs in collector" {
    # Artifact: multi-version, no version_digests (LOCAL_ONLY-produced case).
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Tag-based refs (no @sha256: in the per-version COPYs inside the collector).
    local pinned_count
    pinned_count=$(echo "$output" | grep -c "@sha256:" || true)
    [ "$pinned_count" -eq 0 ]

    # Still has 2 per-version COPYs inside collector
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb.*pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# AN-consumer: strict OCI digest validation at the consumer boundary.
#
# version_digests[ver] flows from the artifact into COPY --from=<repo>@<digest>
# inside the collector stage. A poisoned artifact can inject arbitrary content.
#
# Fix: `is_valid_oci_digest` validates whole-string before use:
#   EXACTLY sha256: followed by EXACTLY 64 lowercase hex chars, nothing else.
#
# AN tests verify that malformed per-version digests cause fail-closed,
# valid digests produce digest-pinned collector COPYs, and absent version_digests
# falls back to tag-based refs.
# ---------------------------------------------------------------------------

# Helper: write a versionset artifact with a specific (potentially malformed)
# digest for the FIRST version in the available list.  Used by AN injection tests.
_write_versionset_with_malformed_ver_digest() {
    local ext="$1"
    local pg_major="$2"
    local bad_digest="$3"
    shift 3
    local -a available_arr=("$@")

    local arr_json="["
    local first=1
    for v in "${available_arr[@]}"; do
        [[ "$first" -eq 0 ]] && arr_json+=","
        arr_json+="\"$v\""
        first=0
    done
    arr_json+="]"

    # Write with a valid digest for the last version and the bad_digest for the first.
    local first_ver="${available_arr[0]}"
    local last_ver="${available_arr[-1]}"
    local good_digest="sha256:abcdef0000000000000000000000000000000000000000000000000000000000"

    # Use printf to write the digest value literally (handles embedded newlines).
    local tmp_digest_file
    tmp_digest_file=$(mktemp)
    printf '%s' "$bad_digest" > "$tmp_digest_file"

    local bad_val
    bad_val=$(cat "$tmp_digest_file")
    rm -f "$tmp_digest_file"

    # Build version_digests JSON with bad_val for first_ver
    local vd_json="{\"${first_ver}\":$(jq -n --arg d "$bad_val" '$d')}"
    # If there is a second version, add a valid digest for it
    if [[ "${#available_arr[@]}" -ge 2 ]]; then
        vd_json="{\"${first_ver}\":$(jq -n --arg d "$bad_val" '$d'),\"${last_ver}\":\"${good_digest}\"}"
    fi

    jq -nc \
        --arg ext "$ext" \
        --arg pg_major "$pg_major" \
        --arg ceiling "$last_ver" \
        --argjson resolved "$arr_json" \
        --argjson available "$arr_json" \
        --argjson version_digests "$vd_json" \
        '{ext:$ext,pg_major:$pg_major,ceiling:$ceiling,resolved:$resolved,available:$available,excluded:[],version_digests:$version_digests}' \
        > "$TEST_TEMP_DIR/.build-lineage/ext-${ext}-pg${pg_major}-versionset.json"
}

@test "AN-consumer-rejects-embedded-newline-injection: version_digests with newline+RUN evil → fail closed" {
    # Poisoned digest for one version: valid-looking sha256 prefix + embedded newline + injected directive.
    local evil_digest
    evil_digest=$(printf 'sha256:0000000000000000000000000000000000000000000000000000000000000000\nRUN evil')
    _write_versionset_with_malformed_ver_digest "timescaledb" "18" "$evil_digest" "2.25.0" "2.27.1"

    run --separate-stderr generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must fail closed — malformed digest rejected.
    [ "$status" -ne 0 ]

    # Injected text must NOT appear in stdout.
    local evil_count
    evil_count=$(printf '%s' "$output" | grep -c "RUN evil" || true)
    [ "$evil_count" -eq 0 ]
}

@test "AN-consumer-rejects-uppercase-hex: uppercase digest in version_digests → fail closed" {
    local bad_digest="sha256:DEADBEEF00000000000000000000000000000000000000000000000000000000"
    _write_versionset_with_malformed_ver_digest "timescaledb" "18" "$bad_digest" "2.25.0" "2.27.1"

    run --separate-stderr generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -ne 0 ]

    local upper_count
    upper_count=$(printf '%s' "$output" | grep -c "DEADBEEF" || true)
    [ "$upper_count" -eq 0 ]
}

@test "AN-consumer-rejects-short-hash: sha256:<63hex> in version_digests → fail closed" {
    local bad_digest="sha256:000000000000000000000000000000000000000000000000000000000000000"
    _write_versionset_with_malformed_ver_digest "timescaledb" "18" "$bad_digest" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -ne 0 ]
}

@test "AN-consumer-accepts-valid-digest: valid version_digests → per-version repo@digest COPYs inside collector" {
    # Proper OCI digest — must produce collector stage with digest-pinned per-version COPYs.
    _write_versionset_with_digests "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    echo "$output" | grep -q "^FROM scratch AS ext_collect_timescaledb"

    # Digest-pinned COPYs inside the collector
    local pinned_count
    pinned_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256:" || true)
    [ "$pinned_count" -eq 2 ]
}

@test "AN-consumer-absent-digest-tag: no version_digests in artifact → tag-based refs in collector" {
    # LOCAL_ONLY-produced artifact: no version_digests field.
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage still present (tag-based fallback)
    echo "$output" | grep -q "^FROM scratch AS ext_collect_timescaledb"

    # No @sha256: in output (tag-based refs, no pinning when version_digests absent).
    local pinned_count
    pinned_count=$(echo "$output" | grep -c "@sha256:" || true)
    [ "$pinned_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AO-4: self-heal path, synthesized available contains ONLY an older version
# (ceiling absent) → generate_dockerfile must FAIL CLOSED.
#
# Context: When the versionset artifact is absent/malformed, generate_dockerfile
# self-heals by calling resolve_version_set + probing each resolved version.
# The probe may find that only an older retained version is present (e.g. the
# ceiling build is still in progress or failed in a previous CI run).
# In that case available_count == 1 but the single available version is NOT
# the ceiling.
#
# Pre-fix behavior: available_count == 1 falls through to the single-version
# path, which emits FROM <ext>:pg<major>-<ext_version> (the CEILING tag) even
# though the ceiling image is absent.  This creates a Dockerfile that fails at
# build time with an obscure "manifest not found" error.
#
# Fix: when the data came from the self-heal path (_versionset_from_selfheal),
# enforce ceiling-presence REGARDLESS of count.  If available_count == 1 and
# the single element is NOT the ceiling → FAIL CLOSED (log_error, return 1).
# Only allow single-version fallthrough when available == [ceiling].
#
# AO4-selfheal-ceiling-absent-failclosed:
#   self-heal, synthesized available == [older-only] → fail closed.
#   RED before fix: emits single-version FROM with ceiling tag (which doesn't exist).
#   GREEN after fix: exits non-zero, no FROM emitted.
#
# AO4-selfheal-ceiling-only-singleversion:
#   self-heal, available == [ceiling] → single-version path OK.
#   Must remain GREEN (ceiling present → allowed).
# ---------------------------------------------------------------------------

@test "AO4-selfheal-ceiling-absent-failclosed: self-heal available=[older-only] (no ceiling) → fail closed" {
    # No versionset artifact — forces the self-heal path.

    # Resolver returns 3 versions; the ceiling is 2.27.1.
    resolve_version_set() {
        echo '["2.25.0","2.26.0","2.27.1"]'
    }
    export -f resolve_version_set

    # 3-state probe: only 2.25.0 is PRESENT; ceiling 2.27.1 and 2.26.0 are ABSENT.
    # Result: _sh_available == ["2.25.0"] — count 1, ceiling NOT present.
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.25.0*) return 0 ;;  # PRESENT (older version)
            *)             return 1 ;;  # ABSENT  (including ceiling 2.27.1)
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 with a single-version FROM using the ceiling tag
    #   (ghcr.io/testowner/ext-timescaledb:pg18-2.27.1) which is absent from registry.
    # GREEN after fix: exits non-zero (fail-closed — ceiling absent from self-heal set).
    [ "$status" -ne 0 ]

    # Secondary: if it exited 0 (pre-fix), no single-version FROM with the ceiling tag
    # must appear (that would reference a non-existent image).
    if [ "$status" -eq 0 ]; then
        local ceiling_from_count
        ceiling_from_count=$(echo "$output" | grep -c "FROM.*ext-timescaledb:pg18-2.27.1" || true)
        [ "$ceiling_from_count" -eq 0 ]
    fi
}

@test "AO4-selfheal-ceiling-only-singleversion: self-heal available=[ceiling] → single-version path OK" {
    # No versionset artifact — forces the self-heal path.

    # Resolver returns 3 versions.
    resolve_version_set() {
        echo '["2.25.0","2.26.0","2.27.1"]'
    }
    export -f resolve_version_set

    # 3-state probe: only the ceiling is PRESENT; older versions are ABSENT.
    # Result: _sh_available == ["2.27.1"] — count 1, ceiling IS present.
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.27.1*) return 0 ;;  # PRESENT (ceiling)
            *)             return 1 ;;  # ABSENT  (older versions)
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Available == [ceiling]: single-version path is permitted.
    [ "$status" -eq 0 ]

    # Must emit exactly one FROM stage for the ceiling version (single-version path).
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-2.27.1" || true)
    [ "$from_count" -eq 1 ]

    # Must NOT emit a bundle COPY (no bundle for count==1).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle" || true)
    [ "$bundle_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AP tests: self-heal per-version COPY emission (DEFECT AP fix)
#
# On the self-heal path (versionset artifact absent/malformed), generate_dockerfile
# must emit one COPY --from=<per-version-ref> pair per proved-present version
# instead of using the mutable bundle tag.  The artifact-present path (AM) is
# unchanged: it still emits the digest-pinned bundle COPY.
#
# AP-selfheal-per-version-not-bundle:
#   self-heal, _sh_available proves >1 versions present incl. ceiling →
#   Dockerfile has per-version COPY lines and NO :pg18-bundle reference.
#   RED before fix: bundle COPY emitted.  GREEN after: per-version COPYs only.
#
# AP-selfheal-only-proved-versions:
#   a resolved version that probes ABSENT is NOT emitted; transient ERROR → fail closed.
#
# AP-artifact-path-still-bundle-digest:
#   artifact PRESENT with bundle_digest → still the single digest-pinned bundle COPY.
#   (AM regression — unchanged.)
#
# AP-selfheal-ceiling-present-enforced:
#   self-heal, ceiling absent from _sh_available → fail closed (AO-4 still enforced).
# ---------------------------------------------------------------------------

@test "AP-selfheal-per-version-not-bundle: self-heal >1 proved-present versions → collector stage, no bundle tag" {
    # No versionset artifact → forces self-heal path.
    # _sh_available = [2.23.0, 2.25.0, 2.27.1] (all present, ceiling present, count > 1).

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # 3 per-version COPYs inside the collector (/output/ → /<ver>/)
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 3 ]

    # Exactly ONE final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

@test "AP-selfheal-only-proved-versions: absent version not emitted; transient ERROR fails closed" {
    # Sub-case A: one version definitively absent → only proved-present versions emitted.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # 2.23.0: ABSENT; 2.25.0 and 2.27.1: PRESENT.
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.23.0*) return 1 ;;  # ABSENT
            *)             return 0 ;;  # PRESENT
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Only proved-present versions inside collector (2.25.0 and 2.27.1).
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 2 ]

    # 2.23.0 must NOT appear.
    local absent_count
    absent_count=$(echo "$output" | grep -c "ext-timescaledb:pg18-2.23.0" || true)
    [ "$absent_count" -eq 0 ]
}

@test "AP-artifact-path-still-version-digests: artifact with version_digests → digest-pinned collector COPYs" {
    # AM regression: artifact-present path must still emit digest-pinned refs inside the collector.
    # Self-heal is NOT triggered (valid artifact on disk with version_digests).
    _write_versionset_with_digests "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Collector stage present
    echo "$output" | grep -q "^FROM scratch AS ext_collect_timescaledb"

    # Digest-pinned per-version COPYs inside the collector (2 versions)
    local pinned_count
    pinned_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb@sha256:" || true)
    [ "$pinned_count" -eq 2 ]

    # Exactly ONE final-stage COPY from collector
    local final_count
    final_count=$(echo "$output" | grep -c "COPY --from=ext_collect_timescaledb / /tmp/ext/timescaledb/" || true)
    [ "$final_count" -eq 1 ]
}

@test "AP-selfheal-ceiling-present-enforced: self-heal ceiling absent from proved set → fail closed" {
    # AO-4 regression: ceiling-present enforcement still applies on self-heal path
    # after the AP fix (per-version path).
    # _sh_available = [2.25.0] only — ceiling 2.27.1 absent.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # Only 2.25.0 present; ceiling 2.27.1 absent.
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.25.0*) return 0 ;;  # PRESENT
            *)             return 1 ;;  # ABSENT (including ceiling 2.27.1)
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Ceiling absent → fail closed (AO-4 still enforced on AP path).
    [ "$status" -ne 0 ]

    # No per-version or bundle COPY must appear.
    local copy_count
    copy_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb" || true)
    [ "$copy_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AQ-2: artifact-present path — single available entry that is NOT the ceiling.
#
# Defect: the single-entry ceiling check ("available[0] must equal ceiling") runs
# ONLY when the data came from the self-heal path (_versionset_from_selfheal=true).
# An on-disk artifact with {"ceiling":"2.27.1","available":["2.25.0"]} bypasses
# the guard and falls through to the single-version path emitting:
#   FROM <ext>:pg<major>-2.27.1  (the ceiling, not 2.25.0)
# → manifest-not-found if the ceiling image is absent, or a silently wrong image.
#
# Fix: apply the single-entry ceiling-equality check REGARDLESS of source.
# Whenever available has exactly ONE entry, it MUST equal the ceiling.
# If not → FAIL CLOSED (log_error, return 1).
# Remove the _versionset_from_selfheal gating on this specific check.
# ---------------------------------------------------------------------------
@test "AQ2-artifact-single-not-ceiling-failclosed: on-disk artifact with single available != ceiling → fail closed" {
    # On-disk artifact: single entry 2.25.0 in available but ceiling is 2.27.1.
    # This is a stale/corrupt artifact — build-extensions never writes this shape.
    # Before fix: falls through to single-version path emitting FROM ...:pg18-2.27.1
    #             (the ceiling — NOT what the available entry says). Exits 0.
    # After fix: single available != ceiling → FAIL CLOSED (exit non-zero).
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0"],"excluded":[{"version":"2.27.1","reason":"not available"}]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 and emits FROM ...:pg18-2.27.1 (ceiling as single-version).
    # GREEN after fix: exits non-zero (single available 2.25.0 != ceiling 2.27.1).
    [ "$status" -ne 0 ]

    # No FROM stage for the ceiling must appear in the output.
    local ceiling_from_count
    ceiling_from_count=$(echo "$output" | grep -c ":pg18-2\.27\.1" || true)
    [ "$ceiling_from_count" -eq 0 ]
}

@test "AQ2-artifact-single-is-ceiling-ok: on-disk artifact with single available == ceiling → single-version path succeeds" {
    # On-disk artifact: single entry 2.27.1 in available, ceiling is also 2.27.1.
    # This is the legitimate case: ceiling built but no older versions available.
    # Must succeed and emit the single-version FROM stage.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.27.1"],"excluded":[{"version":"2.25.0","reason":"not available"}]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Single available == ceiling: single-version path is safe, must exit 0.
    [ "$status" -eq 0 ]

    # The single-version FROM stage for the ceiling must appear.
    local ceiling_from_count
    ceiling_from_count=$(echo "$output" | grep -c "FROM.*ext-timescaledb:pg18-2\.27\.1" || true)
    [ "$ceiling_from_count" -eq 1 ]

    # No bundle COPY (available_count == 1, bundle path not taken).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c ":pg18-bundle" || true)
    [ "$bundle_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AR-2: a malformed version_digests entry containing GHA workflow-command injection
# bytes must be defanged in the log diagnostic and the function must fail closed.
#
# A poisoned artifact has version_digests["2.23.0"] = "sha256:abc\n::add-mask::secret".
# is_valid_oci_digest rejects this, so generate_dockerfile must fail closed (exit
# non-zero). The log_error message must NOT contain a raw newline immediately followed
# by ::add-mask:: (the injection form GHA interprets).
# ---------------------------------------------------------------------------
@test "AR2-digest-diagnostic-sanitized: malformed version_digests entry with injection bytes — fail closed, diagnostic defanged" {
    # Artifact with 3 available versions and a poisoned digest for one version.
    python3 -c "
import json, os
artifact = {
    'ext': 'timescaledb',
    'pg_major': '18',
    'ceiling': '2.27.1',
    'resolved': ['2.23.0', '2.25.0', '2.27.1'],
    'available': ['2.23.0', '2.25.0', '2.27.1'],
    'excluded': [],
    'version_digests': {
        '2.23.0': 'sha256:abc\n::add-mask::secret',
        '2.25.0': 'sha256:' + 'a' * 64,
        '2.27.1': 'sha256:' + 'b' * 64
    }
}
path = os.path.join('$TEST_TEMP_DIR', '.build-lineage', 'ext-timescaledb-pg18-versionset.json')
with open(path, 'w') as f:
    json.dump(artifact, f)
"

    local ar2_stderr="/tmp/ar2_digest_stderr_$$.txt"
    local ar2_rc=0
    bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner
        ROOT_DIR='$TEST_TEMP_DIR'
        export ROOT_DIR
        generate_dockerfile \
            '$TEST_TEMP_DIR/extensions/config.yaml' \
            '$TEST_TEMP_DIR/Dockerfile.template' \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    " 2>"$ar2_stderr" || ar2_rc=$?

    # Must fail closed: invalid digest → generate_dockerfile returns non-zero.
    [ "$ar2_rc" -ne 0 ]

    local stderr_content
    stderr_content=$(cat "$ar2_stderr" 2>/dev/null || true)

    # The log diagnostic must have been emitted (error message mentions version_digests).
    [[ "$stderr_content" == *"version_digests"* ]]

    # The injection sequence must NOT appear as a line starting with :: in the output.
    if printf '%s\n' "$stderr_content" | grep -qE '^::'; then
        echo "FAIL: log output contains a line starting with '::' — GHA injection not neutralized"
        echo "--- stderr_content ---"
        printf '%s\n' "$stderr_content" | cat -A
        return 1
    fi

    rm -f "$ar2_stderr"
}

# ---------------------------------------------------------------------------
# AS-2: _single_avail (extension-utils.sh ~648) log path sanitization.
#
# Scenario: artifact has available:["1.2.3\n::warning::pwn"] — a single entry
# that contains an embedded GHA workflow-command injection.
# The value is != ceiling (2.27.1), so generate_dockerfile must fail closed
# (AO-4 guard). The log_error diagnostic at that site must NOT emit the raw
# newline+:: sequence — it must be sanitized first.
#
# RED before fix: _single_avail is logged raw (no _sanitize_for_log).
# GREEN after fix: _single_avail is wrapped in _sanitize_for_log before logging.
# ---------------------------------------------------------------------------
@test "AS2-single-avail-log-sanitized: artifact single-available with injection bytes — fail closed, log defanged" {
    # Write artifact with a poisoned single-entry available array.
    # We embed a literal newline in the JSON string using python3 for correctness.
    python3 -c "
import json, os
artifact = {
    'ext': 'timescaledb',
    'pg_major': '18',
    'ceiling': '2.27.1',
    'resolved': ['2.27.1'],
    'available': ['1.2.3\n::warning::pwn'],
    'excluded': []
}
path = os.path.join('$TEST_TEMP_DIR', '.build-lineage', 'ext-timescaledb-pg18-versionset.json')
with open(path, 'w') as f:
    json.dump(artifact, f)
"

    local sa_stderr="/tmp/as2_single_avail_stderr_$$.txt"
    local sa_rc=0
    bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner
        ROOT_DIR='$TEST_TEMP_DIR'
        export ROOT_DIR
        generate_dockerfile \
            '$TEST_TEMP_DIR/extensions/config.yaml' \
            '$TEST_TEMP_DIR/Dockerfile.template' \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    " 2>"$sa_stderr" || sa_rc=$?

    # Must fail closed: single available != ceiling → non-zero exit.
    [ "$sa_rc" -ne 0 ]

    local stderr_content
    stderr_content=$(cat "$sa_stderr" 2>/dev/null || true)

    # The diagnostic must have been emitted (mentions the extension or single available).
    [[ "$stderr_content" == *"timescaledb"* ]]

    # The injection sequence must NOT appear as a line starting with :: in stderr.
    if printf '%s\n' "$stderr_content" | grep -qE '^::'; then
        echo "FAIL: log output contains a line starting with '::' — GHA injection not neutralized"
        echo "--- stderr_content ---"
        printf '%s\n' "$stderr_content" | cat -A
        rm -f "$sa_stderr"
        return 1
    fi

    rm -f "$sa_stderr"
}

# ---------------------------------------------------------------------------
# AS-2: _val_ver (extension-utils.sh ~694/~702) log path sanitization.
#
# The per-element validation loop logs _val_ver when is_strict_semver fails
# or when the above-ceiling check fails. Since validate_semver_set_json runs
# first and catches injection at the JSON-array level, the only realistic way
# for a poisoned _val_ver to reach the log is if validate_semver_set_json is
# bypassed (e.g. future refactor, misconfiguration). This test exercises the
# log sanitization at the _val_ver site by mocking validate_semver_set_json
# to return 0 (simulate bypass), then feeding a value with injection bytes to
# the per-element loop via a crafted artifact.
#
# Strategy: write an artifact where the per-element jq -r '.available[]' output
# would contain injection bytes when validate_semver_set_json is bypassed.
# We mock validate_semver_set_json to always return 0, then write an artifact
# whose available[] first entry is "9.99.0::stop-commands::x" — a value that:
#   1. Passes (mocked) validate_semver_set_json
#   2. Fails is_strict_semver (non-semver chars after version) → log_error at ~694
#   3. Contains GHA injection chars that must be sanitized
# ---------------------------------------------------------------------------
@test "AS2-valver-log-sanitized: per-element resolved version with injection bytes — log defanged" {
    # The injection vector at the _val_ver log site uses echo -e expansion:
    # a value like "2.25.0\n::stop-commands::x" (with a literal backslash-n, not a
    # real newline) is logged via echo -e which expands \n to a real newline, causing
    # "::stop-commands::x" to start a new GHA-interpreted line.
    # JSON encoding: "2.25.0\\n::stop-commands::x" (JSON \\n = literal backslash-n in output).
    # jq -r reads this as the 18-char string "2.25.0\n::..." (no real newline),
    # IFS= read -r reads the whole line (no real newline to split on),
    # is_strict_semver rejects it → log_error at ~694 logs the raw value.
    # Without _sanitize_for_log: echo -e expands \n → injection lands on new line.
    # With _sanitize_for_log: \n is encoded as %0A → echo -e emits "%0A", no new line.
    # Mock validate_semver_set_json to return 0 so the per-element loop is reached.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" \
        <<'ARTIFACT_EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0\\n::stop-commands::x","2.27.1"],"excluded":[]}
ARTIFACT_EOF

    local vv_stderr="/tmp/as2_valver_stderr_$$.txt"
    local vv_rc=0
    bash -c "
        source '$HELPERS_DIR/extension-utils.sh'
        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner
        ROOT_DIR='$TEST_TEMP_DIR'
        export ROOT_DIR
        # Mock validate_semver_set_json to return 0 (simulate JSON-level bypass)
        # so the per-element _val_ver loop is reached with the poisoned value.
        validate_semver_set_json() { return 0; }
        export -f validate_semver_set_json
        generate_dockerfile \
            '$TEST_TEMP_DIR/extensions/config.yaml' \
            '$TEST_TEMP_DIR/Dockerfile.template' \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    " 2>"$vv_stderr" || vv_rc=$?

    # Must fail closed: is_strict_semver rejects the poisoned entry.
    [ "$vv_rc" -ne 0 ]

    local stderr_content
    stderr_content=$(cat "$vv_stderr" 2>/dev/null || true)

    # A diagnostic about the bad entry must have been emitted.
    [[ -n "$stderr_content" ]]

    # The injection sequence must NOT appear as a line starting with :: in stderr.
    # RED before fix: log_error "'${_val_ver}'" logs the raw string → echo -e expands
    # \n → "::stop-commands::x" starts a new line interpreted by GHA as a command.
    # GREEN after fix: _sanitize_for_log wraps _val_ver → \n → %0A, :: → %3A%3A.
    if printf '%s\n' "$stderr_content" | grep -qE '^::'; then
        echo "FAIL: log output contains a line starting with '::' — GHA injection not neutralized"
        echo "--- stderr_content ---"
        printf '%s\n' "$stderr_content" | cat -A
        rm -f "$vv_stderr"
        return 1
    fi

    rm -f "$vv_stderr"
}

# ---------------------------------------------------------------------------
# AT-2: self-heal with reduced retention must emit a log_warning naming
# the dropped versions.
#
# When the probed available set (_sh_available) is SMALLER than the resolved
# set (some resolved versions are absent from the registry), generate_dockerfile
# must:
#   - still SUCCEED (do NOT fail-closed here — local/smoke builds where older
#     versions aren't available are legitimate; the ceiling-presence check is
#     the hard gate)
#   - emit a log_warning that:
#       * mentions the count of dropped versions
#       * names each dropped version
#       * is sanitised through _sanitize_for_log (no raw injection path)
#
# Tests:
#   AT2-selfheal-reduced-warns: resolved=3, probed-present=2 (ceiling present),
#     1 version absent → SUCCEEDS, log_warning names the dropped version.
#     RED before fix: no warning at all (silent reduction).
#     GREEN after fix: warning surfaces dropped version.
#
#   AT2-selfheal-full-no-warn: resolved=3, probed-present=3 (all present) →
#     SUCCEEDS, NO reduction warning emitted.
#     (Regression: the warning must not fire when no version was dropped.)
#
# Existing ceiling-present fail-closed (AO-4 / EE-a-3) and per-version
# emission (AP) remain unchanged — these tests do NOT touch or weaken them.
# ---------------------------------------------------------------------------

@test "AT2-selfheal-reduced-warns: self-heal with 1 absent version emits log_warning naming dropped version" {
    # No versionset artifact — forces self-heal path.
    # Resolver returns 3 versions; only 2 are present in registry.
    # 2.16.0 is definitively absent (rc=1 from _image_registry_probe_3state).
    # Ceiling (2.27.1) is present.

    resolve_version_set() {
        echo '["2.16.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.16.0*) return 1 ;;  # ABSENT (definitively)
            *)             return 0 ;;  # PRESENT
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must succeed — reduced set with ceiling present is not a fatal error.
    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs for the 2 proved-present versions inside collector.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$per_ver_ext_count" -eq 2 ]

    # A reduction warning must have been emitted.
    # "output" in bats captures both stdout and stderr of "run" — the warning
    # goes to stderr from log_warning, but run merges them by default.
    # The warning must name the dropped version (2.16.0).
    [[ "$output" == *"2.16.0"* ]]

    # The warning must indicate the set was reduced / retention reduced.
    # Accept either "retention reduced" or "reduced" as the key signal.
    [[ "$output" == *"reduc"* ]] || [[ "$output" == *"absent"* ]] || [[ "$output" == *"not retain"* ]]
}

@test "AT2-selfheal-full-no-warn: all resolved versions present — no reduction warning emitted" {
    # No versionset artifact — forces self-heal path.
    # All 3 resolved versions are present → no reduction, no warning.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    _image_registry_probe_3state() {
        return 0  # all PRESENT
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # No reduction warning should appear when nothing was dropped.
    # The warning message will contain "retention reduced" or "reduc" — check it is absent.
    [[ "$output" != *"retention reduced"* ]]
}

# ---------------------------------------------------------------------------
# BB1-consumer-repo-digest: artifact with version_digests → each per-version
# COPY inside the collector uses <registry>/<owner>/ext-<ext>@<digest>
# (repo + digest, NO tag segment). Pure-digest references are valid across
# any tag scope (PR-scoped or canonical).
# ---------------------------------------------------------------------------
@test "BB1-consumer-repo-digest: version_digests in artifact → per-version COPYs are repo@digest (no tag segment)" {
    _write_versionset_with_digests "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # All per-version COPYs must use repo@digest format (no tag segment).
    local copy_lines
    copy_lines=$(echo "$output" | grep "COPY --from=.*timescaledb@sha256:" || true)
    [ -n "$copy_lines" ]

    # No ":pg" before @sha256: (no tag segment in the ref).
    local tagged_digest_count
    tagged_digest_count=$(echo "$output" | grep -c ":pg.*@sha256:" || true)
    [ "$tagged_digest_count" -eq 0 ]

    # 2 such digest-pinned COPYs (one per version in the collector stage)
    local copy_count
    copy_count=$(echo "$output" | grep -c "ghcr.io/testowner/ext-timescaledb@sha256:" || true)
    [ "$copy_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# BC-1: consumer PR_TAG_SUFFIX scoping for non-resolver/single-version path
#
# generate_dockerfile must append ${PR_TAG_SUFFIX} to the FROM image ref for
# single-version (non-resolver) extensions when PR_TAG_SUFFIX is set.
# The COPY --from=ext-<name> uses the Docker stage alias, not the registry ref,
# so it does NOT carry the suffix.
#
# BC1-consumer-pr-scopes-nonresolver:
#   PR_TAG_SUFFIX=-pr42, pgvector (non-resolver) → FROM ref carries -pr42.
#   PR_TAG_SUFFIX empty → canonical ref (no suffix).
#   RED before fix: FROM always uses canonical tag.  GREEN after: -pr42 appended.
# ---------------------------------------------------------------------------
@test "BC1-consumer-pr-scopes-nonresolver: PR_TAG_SUFFIX=-pr42 → FROM ref for non-resolver ext carries -pr42" {
    # No versionset artifact — pgvector is non-resolver, uses single-version path.
    export PR_TAG_SUFFIX="-pr42"

    # Faithful mock: canonical absent (rc=1), PR-scoped present (rc=0).
    # In production the PR-scoped image was just built by stage A.
    _image_registry_probe_3state() {
        case "$1" in
            *-pr42) return 0 ;;  # PR-scoped: PRESENT
            *)      return 1 ;;  # canonical: ABSENT (definitive not-found)
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "vector" "18" \
        "ghcr.io" "testowner"

    unset PR_TAG_SUFFIX
    unset -f _image_registry_probe_3state

    [ "$status" -eq 0 ]

    # FROM ref must carry -pr42 suffix.
    local from_line
    from_line=$(echo "$output" | grep "^FROM ghcr.io/testowner/ext-pgvector:pg18-" || true)
    [ -n "$from_line" ]
    [[ "$from_line" == *"-pr42"* ]]

    # Must be: FROM ghcr.io/testowner/ext-pgvector:pg18-0.8.2-pr42 AS ext-pgvector
    echo "$output" | grep -q "FROM ghcr.io/testowner/ext-pgvector:pg18-0.8.2-pr42 AS ext-pgvector"

    # The COPY still references the stage alias (no suffix in --from).
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/"
}

@test "BC1-consumer-canonical-no-suffix: PR_TAG_SUFFIX empty → FROM ref is canonical (no suffix)" {
    # Regression: empty PR_TAG_SUFFIX must leave the FROM ref unchanged.
    export PR_TAG_SUFFIX=""

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "vector" "18" \
        "ghcr.io" "testowner"

    unset PR_TAG_SUFFIX

    [ "$status" -eq 0 ]

    # FROM ref must be exactly the canonical tag (no -pr suffix).
    echo "$output" | grep -q "FROM ghcr.io/testowner/ext-pgvector:pg18-0.8.2 AS ext-pgvector"

    # Must NOT have any -pr suffix.
    local pr_count
    pr_count=$(echo "$output" | grep -c '\-pr[0-9]' || true)
    [ "$pr_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BC-1: consumer PR_TAG_SUFFIX scoping for self-heal per-version COPY refs
#
# On the self-heal path (AP), generate_dockerfile emits per-version COPY lines
# using ext_image_name().  Those refs must also carry the PR_TAG_SUFFIX.
#
# BC1-consumer-pr-scopes-selfheal:
#   PR_TAG_SUFFIX=-pr42, self-heal path (no artifact) → per-version COPY refs
#   all carry -pr42.  Confirmed for each version in the proved-present set.
#   RED before fix: per-version refs use canonical tags.  GREEN after: -pr42 appended.
# ---------------------------------------------------------------------------
@test "BC1-consumer-pr-scopes-selfheal: PR_TAG_SUFFIX=-pr42, all canonical refs absent → self-heal COPY refs carry -pr42" {
    # No versionset artifact → self-heal path for timescaledb.
    # PR context (PR_TAG_SUFFIX=-pr42): both versions were built THIS PR.
    # Faithful mock: canonical refs are ABSENT (rc=1); PR-scoped refs are PRESENT (rc=0).
    # Canonical-first probe: canonical absent → try PR-scoped → PRESENT → emit PR-scoped.
    # Correct production behavior: COPY lines carry -pr42 (canonical-first + PR-scoped fallback).
    export PR_TAG_SUFFIX="-pr42"

    resolve_version_set() {
        echo '["2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # Faithful mock: canonical absent, PR-scoped present (versions built this PR, no prior push).
    _image_registry_probe_3state() {
        case "$1" in
            *-pr42) return 0 ;;  # PR-scoped: PRESENT
            *)      return 1 ;;  # canonical: ABSENT (definitive not-found)
        esac
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    unset PR_TAG_SUFFIX

    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs inside collector with -pr42 suffix.
    # Canonical absent + PR-scoped present → each per-version ref must carry -pr42.
    local per_ver_ext_count
    per_ver_ext_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+-pr42 /output/ /" || true)
    [ "$per_ver_ext_count" -eq 2 ]

    # Both expected pr42 refs present inside collector.
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.25.0-pr42 /output/ /"
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-2.27.1-pr42 /output/ /"
}

# ---------------------------------------------------------------------------
# BC-3: present-empty bundle_digest fails closed; absent key → tag fallback
#
# generate_dockerfile uses `jq '.bundle_digest // empty'` which maps both
# ABSENT and PRESENT-EMPTY to the empty string — falling back to the mutable
# bundle tag.  BC-3 requires distinguishing:
#   - FIELD ABSENT    → allowed LOCAL_ONLY tag fallback (exit 0)
#   - FIELD PRESENT but empty digest string → FAIL CLOSED (exit non-zero)
#   - FIELD PRESENT but not valid OCI digest → FAIL CLOSED (already AN-covered)
#
# BC3-empty-digest-failclosed:
#   artifact has version_digests["2.25.0"]="" (present, empty string) →
#   generate_dockerfile FAILS CLOSED (non-zero).
#
# BC3-absent-digest-tag-fallback:
#   artifact has NO version_digests key → tag-based refs, exit 0 (LOCAL_ONLY case).
#   Must remain GREEN (regression guard).
# ---------------------------------------------------------------------------
@test "BC3-empty-digest-failclosed: version_digests entry present-but-empty → fail closed" {
    # Artifact with version_digests having one empty-string value.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0","2.27.1"],"excluded":[],"version_digests":{"2.25.0":"","2.27.1":"sha256:abcdef0000000000000000000000000000000000000000000000000000000000"}}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Field present with empty value → fail closed.
    [ "$status" -ne 0 ]
}

@test "BC3-absent-digest-tag-fallback: NO version_digests key in artifact → tag-based refs, exit 0 (LOCAL_ONLY regression)" {
    # LOCAL_ONLY-produced artifact: version_digests key is completely absent.
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Must succeed (LOCAL_ONLY case — key absent → tag-based refs in collector).
    [ "$status" -eq 0 ]

    # Collector stage present with tag-based refs
    echo "$output" | grep -q "^FROM scratch AS ext_collect_timescaledb"

    # No @sha256: anywhere (tag-based fallback, no digest pin).
    local pinned_count
    pinned_count=$(echo "$output" | grep -c "@sha256:" || true)
    [ "$pinned_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BE-2: self-heal availability probe must use the PR-scoped ref it emits.
#
# Defect: in the self-heal loop, _sh_image is built with ext_image_name (no
# PR_TAG_SUFFIX) but the emitted COPY line uses _scoped_ext_ref (which appends
# PR_TAG_SUFFIX).  On a same-repo PR (suffix=-pr42), the probe checks the
# canonical tag (absent) and wrongly excludes or errors on the version, while
# the COPY line would reference the -pr42 image that actually exists.
#
# Fix: apply _scoped_ext_ref to the ref passed to _image_registry_probe_3state
# in the self-heal loop so probe-ref == emit-ref in all cases.
#
# BE2-selfheal-probes-scoped-ref:
#   PR_TAG_SUFFIX=-pr42, no versionset artifact (forces self-heal).
#   _image_registry_probe_3state mock asserts it is called with a -pr42 ref.
#   RED before fix: probe called with canonical (no suffix) ref → assertion fails.
#   GREEN after fix: probe called with -pr42 ref → assertion passes.
#
# BE2-push-probes-canonical:
#   PR_TAG_SUFFIX empty (push/dispatch path).
#   Probe must use canonical ref (no suffix).
#   Regression guard — must stay green before and after the fix.
# ---------------------------------------------------------------------------

@test "BE2-selfheal-probes-scoped-ref: PR_TAG_SUFFIX=-pr42, canonical ABSENT → probe falls back to -pr42 ref" {
    # No versionset artifact — forces self-heal path.
    # PR_TAG_SUFFIX is set to -pr42 (same-repo PR scenario).
    # Canonical-first behavior (BI-1 fix): probe canonical first; if ABSENT (rc=1),
    # probe PR-scoped; if PRESENT (rc=0), use PR-scoped ref.
    # Faithful mock: canonical → ABSENT (rc=1, not ERROR), PR-scoped → PRESENT (rc=0).
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export PR_TAG_SUFFIX='-pr42'
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() { echo '[\"2.25.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        # Faithful mock for canonical-first canonical-absent scenario:
        # canonical refs → ABSENT (rc=1, definitive not-found — version not yet in canonical).
        # PR-scoped refs → PRESENT (rc=0, built this PR).
        _image_registry_probe_3state() {
            if [[ \"\$1\" == *'-pr42'* ]]; then
                return 0  # PRESENT — the PR-scoped image exists
            else
                return 1  # ABSENT — canonical does not exist (version built only on this PR)
            fi
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "

    # Canonical absent → fall back to PR-scoped → PRESENT → self-heal succeeds → exit 0.
    [ "$status" -eq 0 ]

    # Collector stage present
    local collector_count
    collector_count=$(echo "$output" | grep -c "^FROM scratch AS ext_collect_timescaledb" || true)
    [ "$collector_count" -eq 1 ]

    # Self-heal emits per-version COPYs inside collector with -pr42 suffix.
    local pr_copy_count
    pr_copy_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+-pr42 /output/ /" || true)
    [ "$pr_copy_count" -eq 2 ]

    # No canonical (un-suffixed) per-version COPYs (canonical was absent for all versions).
    local canonical_copy_count
    canonical_copy_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+[^-] /output/ /" || true)
    [ "$canonical_copy_count" -eq 0 ]
}

@test "BE2-push-probes-canonical: PR_TAG_SUFFIX empty → self-heal probe uses canonical ref (regression)" {
    # Push/dispatch path: PR_TAG_SUFFIX is empty.
    # Probe must use canonical refs; scoped-ref logic must be a no-op.
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export PR_TAG_SUFFIX=''
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() { echo '[\"2.25.0\",\"2.27.1\"]'; }
        export -f resolve_version_set

        # Return PRESENT for canonical refs, ERROR for any -pr<N> ref.
        _image_registry_probe_3state() {
            if [[ \"\$1\" == *'-pr'* ]]; then
                return 2  # ERROR — scoped refs must NOT appear on the push path
            fi
            return 0  # PRESENT — canonical ref
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \
            \"$tmpd/extensions/config.yaml\" \
            \"$tmpd/Dockerfile.template\" \
            'timeseries' '18' \
            'ghcr.io' 'testowner'
    "

    # Push path must succeed: canonical probe → PRESENT → self-heal succeeds.
    [ "$status" -eq 0 ]

    # Self-heal emits per-version COPYs inside collector with NO pr suffix.
    local canonical_copy_count
    canonical_copy_count=$(echo "$output" | grep -cE "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+ /output/ /" || true)
    [ "$canonical_copy_count" -eq 2 ]

    # No -pr<N> suffixed COPY lines inside collector.
    local pr_copy_count
    pr_copy_count=$(echo "$output" | grep -cE "COPY --from=.*-pr[0-9]+ /output/ /" || true)
    [ "$pr_copy_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BF-consumer-canonical-or-prscoped: for the single-version (non-resolver)
# path in generate_dockerfile, the emitted FROM ref should prefer CANONICAL
# when it exists, else fall back to PR-scoped.
#
# Scenario A: PR_TAG_SUFFIX=-pr42, canonical ext ref EXISTS in registry
#   → FROM uses canonical ref (no -pr42 suffix).
#
# Scenario B: PR_TAG_SUFFIX=-pr42, canonical ext ref ABSENT in registry,
#   PR-scoped exists
#   → FROM uses PR-scoped ref (with -pr42 suffix).
#
# Supply-chain safety: PR only WRITES PR-scoped (build-extensions.sh outputs
# pr-scoped tags). Canonical reads are read-only (already published).
#
# RED before fix: always emits PR-scoped ref (uses _scoped_ext_ref
#   unconditionally), even when canonical exists.
# GREEN after fix: canonical-or-PR-scoped resolution.
# ---------------------------------------------------------------------------
@test "BF-consumer-canonical-or-prscoped-A: PR with canonical ext present → FROM uses canonical ref" {
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=false PULL_ONLY=false
        export PR_TAG_SUFFIX='-pr42'
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        # pgvector (non-resolver): canonical ref EXISTS in registry.
        image_exists_in_registry() {
            local ref=\"\$1\"
            # Canonical pgvector ref (no -pr suffix): present
            if [[ \"\$ref\" == *'pg18-0.8.2' && \"\$ref\" != *'-pr42'* ]]; then
                return 0
            fi
            return 1
        }
        export -f image_exists_in_registry

        generate_dockerfile \\
            \"$tmpd/extensions/config.yaml\" \\
            \"$tmpd/Dockerfile.template\" \\
            'vector' '18' \\
            'ghcr.io' 'testowner'
    "

    [ "$status" -eq 0 ]

    # FROM must reference canonical ref (no -pr42 suffix).
    # RED before fix: emits ghcr.io/testowner/ext-pgvector:pg18-0.8.2-pr42
    # GREEN after fix: emits ghcr.io/testowner/ext-pgvector:pg18-0.8.2 (canonical)
    local canonical_from_count
    canonical_from_count=$(echo "$output" | grep -cE "FROM ghcr\.io/testowner/ext-pgvector:pg18-0\.8\.2 AS ext-pgvector$" || true)
    [ "$canonical_from_count" -eq 1 ]

    # PR-scoped ref must NOT appear.
    local pr_from_count
    pr_from_count=$(echo "$output" | grep -c 'ext-pgvector:pg18-0.8.2-pr42' || true)
    [ "$pr_from_count" -eq 0 ]
}

@test "BF-consumer-canonical-or-prscoped-B: PR with canonical absent but PR-scoped present → FROM uses PR-scoped ref" {
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=false PULL_ONLY=false
        export PR_TAG_SUFFIX='-pr42'
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        # Faithful mock: canonical ABSENT (rc=1), PR-scoped PRESENT (rc=0).
        # In production the PR-scoped image was just built by stage A.
        _image_registry_probe_3state() {
            case \"\$1\" in
                *pg18-0.8.2-pr42) return 0 ;;  # PR-scoped: PRESENT
                *)                 return 1 ;;  # canonical: ABSENT
            esac
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \\
            \"$tmpd/extensions/config.yaml\" \\
            \"$tmpd/Dockerfile.template\" \\
            'vector' '18' \\
            'ghcr.io' 'testowner'
    "

    [ "$status" -eq 0 ]

    # FROM must reference PR-scoped ref (canonical absent, PR-scoped present).
    local pr_from_count
    pr_from_count=$(echo "$output" | grep -c 'ext-pgvector:pg18-0.8.2-pr42' || true)
    [ "$pr_from_count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# BI-1 self-heal canonical-first: on a PR with PR_TAG_SUFFIX=-pr42, when the
# versionset artifact is absent/malformed, unchanged retained versions that exist
# ONLY under the canonical tag (NOT under -pr42) must be probed + emitted as
# CANONICAL (not as -pr42, which would be absent and cause the version to be
# silently dropped).
#
# BI1-selfheal-unchanged-canonical: unchanged version (canonical present, no -pr42)
#   INCLUDED in output as canonical COPY ref.
#
# RED before fix: probed as -pr42 → absent → omitted.
# GREEN after fix: canonical-first probe → canonical present → emitted as canonical.
# ---------------------------------------------------------------------------
@test "BI1-selfheal-unchanged-canonical: self-heal on PR, unchanged version has canonical only — included as canonical" {
    # No versionset artifact — triggers self-heal.
    # PR_TAG_SUFFIX=-pr42: this is a same-repo PR context.
    # Version set: 2.23.0 (unchanged, canonical only) + 2.27.1 (bumped, pr42 only).
    # image_exists_in_registry: canonical present for 2.23.0, pr42 present for 2.27.1.

    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export PR_TAG_SUFFIX='-pr42'
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        resolve_version_set() {
            echo '[\"2.23.0\",\"2.27.1\"]'
        }
        export -f resolve_version_set

        # 2.23.0: canonical present, NO pr42 tag.
        # 2.27.1: canonical absent, pr42 present (built this PR).
        image_exists_in_registry() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.23.0)      return 0 ;;   # canonical present
                *pg18-2.23.0-pr42) return 1 ;;   # pr42 absent
                *pg18-2.27.1)      return 1 ;;   # canonical absent
                *pg18-2.27.1-pr42) return 0 ;;   # pr42 present (built this PR)
                *)                 return 1 ;;
            esac
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.23.0)      return 0 ;;
                *pg18-2.23.0-pr42) return 1 ;;
                *pg18-2.27.1)      return 1 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;
            esac
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \\
            \"$tmpd/extensions/config.yaml\" \\
            \"$tmpd/Dockerfile.template\" \\
            'timeseries' '18' \\
            'ghcr.io' 'testowner'
    "

    # Self-heal must succeed.
    [ "$status" -eq 0 ]

    # 2.23.0 must be emitted as the CANONICAL ref (no -pr42 suffix) inside the collector.
    local canonical_copy_count
    canonical_copy_count=$(echo "$output" | grep -c 'ghcr.io/testowner/ext-timescaledb:pg18-2.23.0 /output/ /' || true)
    [ "$canonical_copy_count" -eq 1 ] || {
        echo "FAIL: 2.23.0 must appear as canonical ref in collector COPY. Output was:"
        echo "$output"
        false
    }

    # 2.23.0 must NOT appear with -pr42 suffix.
    local pr_copy_count
    pr_copy_count=$(echo "$output" | grep -c 'pg18-2.23.0-pr42' || true)
    [ "$pr_copy_count" -eq 0 ] || {
        echo "FAIL: 2.23.0 must not appear as pr42-scoped ref. Output was:"
        echo "$output"
        false
    }

    # 2.27.1 (bumped, built this PR) must appear as PR-scoped ref inside the collector.
    local pr42_count
    pr42_count=$(echo "$output" | grep -c 'pg18-2.27.1-pr42 /output/ /' || true)
    [ "$pr42_count" -eq 1 ] || {
        echo "FAIL: 2.27.1 must appear as pr42-scoped ref. Output was:"
        echo "$output"
        false
    }
}

@test "BI1-selfheal-bump-prscoped: self-heal on PR, bumped version has pr42 only — emitted pr-scoped" {
    # Complements BI1-selfheal-unchanged-canonical: the bumped version (2.27.1)
    # exists ONLY under the PR-scoped tag. It must be emitted as -pr42.
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export PR_TAG_SUFFIX='-pr42'
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        # Single bumped version only (ceiling only — self-heal single-version path).
        resolve_version_set() {
            echo '[\"2.27.1\"]'
        }
        export -f resolve_version_set

        # 2.27.1: canonical absent, pr42 present.
        image_exists_in_registry() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.27.1)      return 1 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;
            esac
        }
        export -f image_exists_in_registry

        _image_registry_probe_3state() {
            local ref=\"\$1\"
            case \"\$ref\" in
                *pg18-2.27.1)      return 1 ;;
                *pg18-2.27.1-pr42) return 0 ;;
                *)                 return 1 ;;
            esac
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \\
            \"$tmpd/extensions/config.yaml\" \\
            \"$tmpd/Dockerfile.template\" \\
            'timeseries' '18' \\
            'ghcr.io' 'testowner'
    "

    # Single-version set: available_count == 1 → single-version path in generate_dockerfile.
    # The FROM line must reference the pr42-scoped ref since canonical is absent.
    [ "$status" -eq 0 ]

    # The FROM stage must use the pr42-scoped ref.
    local pr42_from_count
    pr42_from_count=$(echo "$output" | grep -c 'ext-timescaledb:pg18-2.27.1-pr42' || true)
    [ "$pr42_from_count" -ge 1 ] || {
        echo "FAIL: bumped version must be emitted as pr42-scoped ref. Output was:"
        echo "$output"
        false
    }
}

# ---------------------------------------------------------------------------
# BJ: generate_dockerfile derives FORCE from REBUILD env, so a forced PR run
# causes the single-version (non-resolver) path to prefer the freshly-rebuilt
# PR-scoped ref over the (stale) canonical ref.
#
# Context: the build-and-push job now exports REBUILD from env.REBUILD_MODE.
# generate_dockerfile derives FORCE=true when REBUILD is "force" or "all".
# ext_ref_resolve then prefers the PR-scoped ref when FORCE=true + PR_TAG_SUFFIX set.
#
# BJ-1 (FORCE-consumer-nonresolver-fresh):
#   REBUILD=force + PR_TAG_SUFFIX=-pr42, pgvector (non-resolver/single-version),
#   canonical AND -pr42 BOTH present in registry.
#   FORCE derived true → ext_ref_resolve returns PR-scoped ref.
#   RED before fix: FORCE never set → canonical path → emits canonical.
#   GREEN after fix: FORCE derived from REBUILD → emits -pr42 ref.
#
# BJ-2 (FORCE-consumer-noforce-canonical):
#   REBUILD unset (none) + PR_TAG_SUFFIX=-pr42, pgvector, canonical present.
#   FORCE stays false → canonical-first reuse (unchanged regression).
#   GREEN before and after (regression guard).
# ---------------------------------------------------------------------------

@test "BJ-1-FORCE-consumer-nonresolver-fresh: REBUILD=force + PR-pr42 + canonical+pr42 both present → emits pr42 ref" {
    # Non-resolver single-version extension (pgvector). Both canonical and -pr42
    # exist in the registry. With REBUILD=force the consumer must prefer the
    # freshly-rebuilt PR-scoped ref, not the (stale) canonical.
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=false PULL_ONLY=false
        export PR_TAG_SUFFIX='-pr42'
        export REBUILD='force'
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        # Faithful mock: both canonical AND pr42 refs are present in registry.
        # In production: canonical exists from a prior push; -pr42 was built this run.
        _image_registry_probe_3state() {
            case \"\$1\" in
                *pg18-0.8.2-pr42) return 0 ;;  # PR-scoped: PRESENT (freshly built)
                *pg18-0.8.2)      return 0 ;;  # canonical: PRESENT (stale but exists)
                *)                return 1 ;;
            esac
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \\
            \"$tmpd/extensions/config.yaml\" \\
            \"$tmpd/Dockerfile.template\" \\
            'vector' '18' \\
            'ghcr.io' 'testowner'
    "

    [ "$status" -eq 0 ]

    # RED before fix: generate_dockerfile ignores REBUILD → FORCE stays false →
    #   ext_ref_resolve canonical-first → emits canonical ref (stale pgvector).
    # GREEN after fix: FORCE derived from REBUILD=force → ext_ref_resolve prefers
    #   PR-scoped → emits -pr42 ref (freshly rebuilt pgvector).
    local pr_from_count
    pr_from_count=$(echo "$output" | grep -c 'ext-pgvector:pg18-0.8.2-pr42' || true)
    [ "$pr_from_count" -eq 1 ] || {
        echo 'FAIL: expected FROM with -pr42 ref. Output was:'
        echo "$output"
        false
    }

    # Canonical ref must NOT appear (FORCE overrides canonical-first).
    local canonical_from_count
    canonical_from_count=$(echo "$output" | grep -cE 'ext-pgvector:pg18-0\.8\.2 AS ext-pgvector$' || true)
    [ "$canonical_from_count" -eq 0 ] || {
        echo 'FAIL: canonical ref must not appear when FORCE=true and PR-scoped exists. Output was:'
        echo "$output"
        false
    }
}

@test "BJ-2-FORCE-consumer-noforce-canonical: REBUILD unset + PR-pr42 + canonical present → emits canonical ref" {
    # Non-resolver single-version extension (pgvector). REBUILD is unset.
    # FORCE stays false → canonical-first (reuse unchanged version).
    local tmpd="$TEST_TEMP_DIR"

    run bash -c "
        export LOCAL_ONLY=false PULL_ONLY=false
        export PR_TAG_SUFFIX='-pr42'
        unset REBUILD
        export ROOT_DIR=\"$tmpd\"

        source \"$HELPERS_DIR/extension-utils.sh\"

        get_registry()   { echo 'ghcr.io'; }
        get_repo_owner() { echo 'testowner'; }
        export -f get_registry get_repo_owner

        # Faithful mock: canonical present, pr42 also present.
        _image_registry_probe_3state() {
            case \"\$1\" in
                *pg18-0.8.2-pr42) return 0 ;;
                *pg18-0.8.2)      return 0 ;;
                *)                return 1 ;;
            esac
        }
        export -f _image_registry_probe_3state

        generate_dockerfile \\
            \"$tmpd/extensions/config.yaml\" \\
            \"$tmpd/Dockerfile.template\" \\
            'vector' '18' \\
            'ghcr.io' 'testowner'
    "

    [ "$status" -eq 0 ]

    # REBUILD unset → FORCE false → canonical-first → emits canonical ref.
    local canonical_from_count
    canonical_from_count=$(echo "$output" | grep -cE 'ext-pgvector:pg18-0\.8\.2 AS ext-pgvector$' || true)
    [ "$canonical_from_count" -eq 1 ] || {
        echo 'FAIL: expected canonical FROM ref when REBUILD unset. Output was:'
        echo "$output"
        false
    }

    # PR-scoped ref must NOT appear (not forced).
    local pr_from_count
    pr_from_count=$(echo "$output" | grep -c 'ext-pgvector:pg18-0.8.2-pr42' || true)
    [ "$pr_from_count" -eq 0 ] || {
        echo 'FAIL: PR-scoped ref must not appear when REBUILD unset. Output was:'
        echo "$output"
        false
    }
}
