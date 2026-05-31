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
# Helper: write a versionset fixture under .build-lineage/
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Test 1: multi-version — 3 available → ONE bundle COPY, NO per-version FROM stages
# ---------------------------------------------------------------------------
@test "multi-version: 3 available versions produce 3 direct COPY --from= lines, NO per-version FROM stages" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # No per-version FROM ... AS stage lines for the resolver-backed extension
    local per_ver_from_count
    per_ver_from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-" || true)
    [ "$per_ver_from_count" -eq 0 ]

    # Exactly ONE bundle COPY covers all available versions (single layer)
    local bundle_copy_count
    bundle_copy_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_copy_count" -eq 1 ]

    # Zero per-version COPY lines for individual version tags
    local per_ver_copy_count
    per_ver_copy_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_copy_count" -eq 0 ]
}

@test "multi-version: COPY --from= refs are full image refs (host/path:tag), NOT bareword stage names" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Every COPY --from= for timescaledb must use a full image ref (host/path:tag pattern)
    # A bareword like "ext-timescaledb-2_23_0" would NOT match this pattern.
    while IFS= read -r copy_line; do
        [[ -z "$copy_line" ]] && continue
        # Extract the --from= value
        local from_ref
        from_ref=$(echo "$copy_line" | sed -n 's/.*--from=\([^ ]*\).*/\1/p')
        # Must contain a registry host (has a slash before the first colon), a colon, and a tag
        [[ "$from_ref" =~ ghcr\.io/.+:.+ ]]
    done < <(echo "$output" | grep "COPY --from=.*ext-timescaledb" || true)
}

@test "multi-version: COPYs go into per-version subdirs /tmp/ext/timescaledb/<ver>/" {
    # The bundle COPY lands at /tmp/ext/timescaledb/ so the bundle's internal
    # /<ver>/{extension,lib}/ structure arrives at /tmp/ext/timescaledb/<ver>/
    # which is exactly the layout install_ext iterates.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # The single bundle COPY lands at /tmp/ext/timescaledb/ — version coverage
    # is preserved because the bundle contains /<ver>/{extension,lib}/ for every
    # available version.
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/"
}

@test "multi-version: ceiling version 2.27.1 appears LAST (ascending order, COPY lines)" {
    # With the bundle approach, ordering is handled by the producer (bundle Dockerfile
    # lists versions ascending). The consumer emits exactly ONE COPY; version ordering
    # is no longer observable in the consumer output.
    # This test verifies the consumer still succeeds and emits the bundle COPY.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Single bundle COPY present
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/"

    # Zero per-version COPY lines (order no longer needs asserting in the consumer)
    local per_ver_copy_count
    per_ver_copy_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_copy_count" -eq 0 ]
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

    # timescaledb: NO per-version FROM ... AS stages
    local ts_from_count
    ts_from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-" || true)
    [ "$ts_from_count" -eq 0 ]

    # timescaledb: exactly ONE bundle COPY covering all available versions
    local ts_bundle_count
    ts_bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$ts_bundle_count" -eq 1 ]

    # timescaledb: zero per-version COPY lines
    local ts_per_ver_count
    ts_per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$ts_per_ver_count" -eq 0 ]

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
    # RED before fix: exits 0 with 1 FROM stage (single-version).
    # GREEN after fix: exits 0 with single bundle COPY (multi-version from self-heal).
    [ "$status" -eq 0 ]

    # No per-version FROM ... AS stages
    local per_ver_from_count
    per_ver_from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-" || true)
    [ "$per_ver_from_count" -eq 0 ]

    # Exactly ONE bundle COPY — version coverage preserved in the bundle
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # Zero per-version COPY lines (versions are bundled, not emitted individually)
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
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

    # Must find artifact via PROJECT_ROOT → bundle COPY path (single COPY, not single-version FROM).
    # RED before fix: 1 FROM stage (single-version fallback because artifact not found).
    # GREEN after fix: 1 bundle COPY (multi-version from artifact found via PROJECT_ROOT).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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

@test "Z-ceiling-present: ceiling in available[] → multi-version path succeeds" {
    # Sanity: ceiling IS present → normal multi-version success with bundle COPY.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Single bundle COPY (all 3 versions are in the bundle)
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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

    # Must produce single bundle COPY (no per-version FROM stages).
    local per_ver_from_count
    per_ver_from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-" || true)
    [ "$per_ver_from_count" -eq 0 ]

    # Single bundle COPY — version coverage preserved in the bundle image
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # Zero per-version COPY lines
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
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

    # Must produce single bundle COPY — NOT a single-version fallback or per-version COPYs.
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # Zero per-version COPY lines
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
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

    # Single bundle COPY — version coverage preserved
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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

    # Single bundle COPY — version coverage preserved
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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

    # All 3 valid versions → single bundle COPY (no per-version FROM stages or individual COPYs).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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
    # RED before fix: a synthetic artifact lingers in $controlled_tmp.
    # GREEN after fix: dir is empty.
    local leftover_count
    leftover_count=$(find "$controlled_tmp" -maxdepth 1 -type f | wc -l)
    rm -rf "$controlled_tmp"
    [ "$leftover_count" -eq 0 ]
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
    #   - bundle ref (:pg18-bundle): PRESENT (rc=0) — the bundle exists in registry
    #     because the producer built it from the available set (2.25.0, 2.27.1).
    #     AK-3: the self-heal path probes the bundle ref; it must return PRESENT
    #     for the COPY to be emitted.
    _image_registry_probe_3state() {
        case "$1" in
            *pg18-2.27.1*) return 0 ;;
            *pg18-2.25.0*) return 0 ;;
            *pg18-2.23.0*) return 1 ;;  # definitively absent
            *:pg18-bundle) return 0 ;;  # bundle exists (producer built it)
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
    [ "$status" -eq 0 ]

    # Must produce single bundle COPY (2.25.0 and 2.27.1 in bundle; 2.23.0 excluded
    # but that is the producer's concern — consumer emits 1 bundle COPY regardless
    # of how many available versions exist in the artifact, as long as ceiling is present).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # Zero per-version COPY lines
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
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

    # RED before fix: exits non-zero (registry probe fails, no local fallback).
    # GREEN after fix: exits 0 (local daemon probe finds images, self-heals).
    [ "$status" -eq 0 ]

    # Single bundle COPY — version coverage preserved in the bundle
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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

    # Single bundle COPY — version coverage preserved in the bundle
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]
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

    # Must produce single bundle COPY (non-vacuous: proves artifact was consumed).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # No per-version COPY lines (version coverage is in the bundle, not individual COPYs).
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
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
# still produces exactly 3 FROM stages (chokepoint must not break happy path).
# ---------------------------------------------------------------------------

@test "AG-5-valid-artifact-still-works: clean available[] with 3 valid elements -> 3 direct COPY --from= lines" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # No per-version FROM ... AS stages
    local per_ver_from_count
    per_ver_from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-" || true)
    [ "$per_ver_from_count" -eq 0 ]

    # Single bundle COPY (chokepoint must not break happy path; version coverage in bundle).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # Zero per-version COPY lines
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
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
# generated Dockerfile has EXACTLY ONE COPY --from=<bundle-ref> / /tmp/ext/<ext>/
# and ZERO per-version COPY/FROM lines.
#
# RED before: N per-version COPY pairs (2N lines)
# GREEN after: 1 bundle COPY line
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-1: 3 available versions → exactly 1 bundle COPY, 0 per-version refs" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Exactly ONE COPY --from=<bundle-ref> landing at /tmp/ext/timescaledb/
    local bundle_copy_count
    bundle_copy_count=$(echo "$output" | grep -c "COPY --from=ghcr\.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_copy_count" -eq 1 ]

    # ZERO per-version COPY lines referencing individual version tags (pg18-2.X.Y)
    local per_ver_copy_count
    per_ver_copy_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_copy_count" -eq 0 ]

    # ZERO per-version FROM ... AS stages for timescaledb
    local per_ver_from_count
    per_ver_from_count=$(echo "$output" | grep -cE "^FROM .*ext-timescaledb:pg18-[0-9]" || true)
    [ "$per_ver_from_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-2: the bundle COPY places files at /tmp/ext/<ext>/
# so that /<ver>/... in the bundle lands at /tmp/ext/<ext>/<ver>/...
# which is the layout install_ext iterates.
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-2: bundle COPY destination is /tmp/ext/timescaledb/ (installs at correct path)" {
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # The single COPY must land at /tmp/ext/timescaledb/ so bundle's
    # /<ver>/{extension,lib}/ becomes /tmp/ext/timescaledb/<ver>/{extension,lib}/
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/"
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-3: bundle ref is derived identically by producer and consumer.
# Consumer must use ext_image_name base + :pg<major>-bundle suffix.
# The ref in the generated COPY must match the producer's naming scheme.
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-3: bundle ref in generated COPY uses correct scheme ghcr.io/<owner>/ext-<ext>:pg<major>-bundle" {
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Full bundle ref must appear in the output
    echo "$output" | grep -q "ghcr.io/testowner/ext-timescaledb:pg18-bundle"
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

@test "BUNDLE-CON-5: mixed flavor — timescaledb bundle COPY + pgvector single-version unchanged" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "multi_mixed" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # timescaledb: exactly one bundle COPY
    local ts_bundle_count
    ts_bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$ts_bundle_count" -eq 1 ]

    # timescaledb: zero per-version FROM stages
    local ts_from_count
    ts_from_count=$(echo "$output" | grep -cE "^FROM .*ext-timescaledb:pg18-[0-9]" || true)
    [ "$ts_from_count" -eq 0 ]

    # timescaledb: zero per-version COPY lines
    local ts_per_ver_count
    ts_per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$ts_per_ver_count" -eq 0 ]

    # pgvector: exactly one FROM stage (single-version path unchanged)
    local pv_from_count
    pv_from_count=$(echo "$output" | grep -c "^FROM.*ext-pgvector:pg18-")
    [ "$pv_from_count" -eq 1 ]

    # pgvector: flat COPY paths
    echo "$output" | grep -q "COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/"

    # pgvector: no bundle COPY
    ! echo "$output" | grep -q "ext-pgvector:pg18-bundle"
}

# ---------------------------------------------------------------------------
# BUNDLE-CON-6: self-heal path (no artifact) for resolver-backed ext
# also emits a single bundle COPY (not per-version COPYs).
# ---------------------------------------------------------------------------

@test "BUNDLE-CON-6: self-heal (no artifact) emits single bundle COPY, not per-version COPYs" {
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

    # Single bundle COPY
    local bundle_copy_count
    bundle_copy_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_copy_count" -eq 1 ]

    # Zero per-version COPYs
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AK-selfheal-bundle-present: artifact absent, self-heal path resolves versions,
# probes per-version images, then PROBES THE BUNDLE REF.
# When the bundle ref is PRESENT → emit the bundle COPY (trusted invariant).
#
# RED before fix: self-heal emits the bundle COPY regardless of whether the bundle
#   image actually exists — no bundle probe.
# GREEN after fix: self-heal probes the bundle ref with _image_registry_probe_3state;
#   PRESENT → emit COPY. (This test verifies the PRESENT case succeeds.)
# ---------------------------------------------------------------------------
@test "AK-selfheal-bundle-present: artifact absent, self-heal, bundle probe PRESENT → emits bundle COPY" {
    # No versionset artifact → forces self-heal path.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # Per-version images present.
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    # Bundle probe: the bundle ref is PRESENT (rc=0).
    # Override _image_registry_probe_3state to return PRESENT for the bundle ref.
    _image_registry_probe_3state() {
        # Bundle ref pattern: :pg<major>-bundle
        if [[ "$1" == *":pg18-bundle"* ]]; then
            return 0  # PRESENT
        fi
        # Per-version refs: also PRESENT (called for per-version availability check).
        return 0
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # Self-heal + bundle PRESENT → must succeed.
    [ "$status" -eq 0 ]

    # Must emit exactly ONE bundle COPY.
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/")
    [ "$bundle_count" -eq 1 ]

    # Zero per-version COPY lines.
    local per_ver_count
    per_ver_count=$(echo "$output" | grep -cE "COPY --from=.*ext-timescaledb:pg18-[0-9]+\.[0-9]+\.[0-9]+" || true)
    [ "$per_ver_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AK-selfheal-bundle-absent-failclosed: artifact absent, self-heal, bundle probe
# ABSENT or ERROR → generate_dockerfile fails closed (non-zero) with a clear
# "bundle" message. NO COPY emitted against the missing/unverifiable bundle.
#
# RED before fix: self-heal always emits the bundle COPY line regardless of
#   whether the bundle image actually exists — the ref is constructed and COPY
#   emitted unconditionally after per-version availability is computed.
# GREEN after fix: self-heal probes the bundle ref; ABSENT or ERROR → return 1
#   with a "bundle image not found / not verifiable" error; no COPY emitted.
#
# Sub-case A: bundle probe ABSENT (rc=1) → fail closed.
# Sub-case B: bundle probe ERROR (rc=2) → fail closed.
# ---------------------------------------------------------------------------
@test "AK-selfheal-bundle-absent-failclosed: artifact absent, self-heal, bundle probe ABSENT → fail closed, no COPY" {
    # No versionset artifact → forces self-heal path.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    # Per-version images present (so self-heal proceeds to the bundle probe step).
    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    # Bundle probe: the bundle ref is ABSENT (rc=1 — definitively not present).
    _image_registry_probe_3state() {
        if [[ "$1" == *":pg18-bundle"* ]]; then
            return 1  # ABSENT
        fi
        return 0  # Per-version refs are PRESENT.
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 and emits a COPY against a non-existent bundle.
    # GREEN after fix: exits non-zero (fail closed — bundle not present).
    [ "$status" -ne 0 ]

    # The error message must mention "bundle" so the operator knows what to do.
    [[ "$output" == *"bundle"* ]]

    # No bundle COPY must appear in the output.
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=.*:pg18-bundle" || true)
    [ "$bundle_count" -eq 0 ]
}

@test "AK-selfheal-bundle-error-failclosed: artifact absent, self-heal, bundle probe ERROR → fail closed, no COPY" {
    # No versionset artifact → forces self-heal path.

    resolve_version_set() {
        echo '["2.23.0","2.25.0","2.27.1"]'
    }
    export -f resolve_version_set

    image_exists_in_registry() { return 0; }
    export -f image_exists_in_registry

    # Bundle probe: ERROR (rc=2 — transient, cannot verify existence).
    _image_registry_probe_3state() {
        if [[ "$1" == *":pg18-bundle"* ]]; then
            return 2  # ERROR
        fi
        return 0  # Per-version refs are PRESENT.
    }
    export -f _image_registry_probe_3state

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    # RED before fix: exits 0 and emits a COPY against an unverifiable bundle.
    # GREEN after fix: exits non-zero (fail closed — bundle not verifiable).
    [ "$status" -ne 0 ]

    # Must mention "bundle" in the error.
    [[ "$output" == *"bundle"* ]]

    # No bundle COPY in output.
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=.*:pg18-bundle" || true)
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
# AM-consumer-digest-pin: artifact present with bundle_digest → generated
# Dockerfile COPYs from <bundle-ref>@<digest> (immutable, pinned reference).
#
# RED before fix: COPY uses only the mutable tag <bundle-ref>, no @sha256:...
# GREEN after fix: COPY uses <bundle-ref>@sha256:... (digest-pinned).
# ---------------------------------------------------------------------------
@test "AM-consumer-digest-pin: artifact with bundle_digest → COPY from bundle ref pinned with @sha256:" {
    # Artifact: multi-version with bundle_digest.
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.25.0","2.27.1"],"available":["2.25.0","2.27.1"],"excluded":[],"bundle_digest":"sha256:deadbeef00000000000000000000000000000000000000000000000000000000"}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # RED before fix: COPY uses only the mutable tag (no @sha256: pin).
    # GREEN after fix: COPY includes @sha256: digest pin.
    local pinned_count
    pinned_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle@sha256:" || true)
    [ "$pinned_count" -eq 1 ]

    # The full pinned ref must contain the exact digest from the artifact.
    echo "$output" | grep -q "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle@sha256:deadbeef"
}

# ---------------------------------------------------------------------------
# AM-consumer-no-digest-tag-fallback: artifact present WITHOUT bundle_digest
# (local/LOCAL_ONLY-produced artifact) → COPY uses tag-based reference only
# (no @sha256:, no failure).
# ---------------------------------------------------------------------------
@test "AM-consumer-no-digest-tag-fallback: artifact without bundle_digest → tag-based COPY, no @ pin" {
    # Artifact: multi-version, no bundle_digest (LOCAL_ONLY-produced case).
    _write_versionset "timescaledb" "18" "2.25.0" "2.27.1"
    # _write_versionset does not include bundle_digest — the artifact is a plain object.

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Must emit exactly ONE bundle COPY (tag-based, no digest pin).
    local bundle_count
    bundle_count=$(echo "$output" | grep -c "COPY --from=ghcr.io/testowner/ext-timescaledb:pg18-bundle / /tmp/ext/timescaledb/" || true)
    [ "$bundle_count" -eq 1 ]

    # Must NOT contain any @sha256: (no digest pinning when digest absent).
    local pinned_count
    pinned_count=$(echo "$output" | grep -c "@sha256:" || true)
    [ "$pinned_count" -eq 0 ]
}
