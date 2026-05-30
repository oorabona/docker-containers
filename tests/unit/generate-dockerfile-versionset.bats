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
# Test 1: multi-version — 3 available → 3 FROM stages + per-version COPYs
# ---------------------------------------------------------------------------
@test "multi-version: 3 available versions produce 3 FROM stages in ascending order" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Three FROM stages must be present
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]

    # All three versions appear as stage aliases
    echo "$output" | grep -q "AS ext-timescaledb-2_23_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_25_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_27_1"
}

@test "multi-version: COPYs go into per-version subdirs /tmp/ext/timescaledb/<ver>/" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    echo "$output" | grep -q "/tmp/ext/timescaledb/2.23.0/extension/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.23.0/lib/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.25.0/extension/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.25.0/lib/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.27.1/extension/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.27.1/lib/"
}

@test "multi-version: ceiling version 2.27.1 appears LAST (ascending order)" {
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Extract line numbers for the three FROM lines and verify ascending order
    local line_2_23 line_2_25 line_2_27
    line_2_23=$(echo "$output" | grep -n "pg18-2.23.0" | head -1 | cut -d: -f1)
    line_2_25=$(echo "$output" | grep -n "pg18-2.25.0" | head -1 | cut -d: -f1)
    line_2_27=$(echo "$output" | grep -n "pg18-2.27.1" | head -1 | cut -d: -f1)

    # Ceiling (2.27.1) line must be after both earlier versions
    [ "$line_2_27" -gt "$line_2_25" ]
    [ "$line_2_27" -gt "$line_2_23" ]
    [ "$line_2_25" -gt "$line_2_23" ]
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

    # timescaledb: 3 stages
    local ts_count
    ts_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$ts_count" -eq 3 ]

    # pgvector: exactly 1 stage, flat COPYs
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
    # GREEN after fix: exits 0 with 3 FROM stages (multi-version from self-heal).
    [ "$status" -eq 0 ]

    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]

    echo "$output" | grep -q "AS ext-timescaledb-2_23_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_25_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_27_1"
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

    # Must find artifact via PROJECT_ROOT → 3 FROM stages (multi-version path).
    # RED before fix: 1 FROM stage (single-version fallback because artifact not found).
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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
    # Sanity: ceiling IS present → normal multi-version success, no error.
    _write_versionset "timescaledb" "18" "2.23.0" "2.25.0" "2.27.1"

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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

    # Must produce multi-version stages (3 FROM stages from self-healed available set).
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]

    echo "$output" | grep -q "AS ext-timescaledb-2_23_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_25_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_27_1"
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

    # pgvector must still produce exactly 1 FROM stage (single-version).
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

    # Must produce 3 multi-version FROM stages — NOT a single-version fallback.
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]

    echo "$output" | grep -q "AS ext-timescaledb-2_23_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_25_0"
    echo "$output" | grep -q "AS ext-timescaledb-2_27_1"
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

    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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

    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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

    # All 3 valid versions produce 3 FROM stages.
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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

    # Secondary: if it exited 0 (pre-fix behavior), it must NOT have 2 stages
    # (2 = the exactly-wrong fail-open behavior that drops 2.23.0).
    if [ "$status" -eq 0 ]; then
        local from_count
        from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-" || true)
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
    [ "$status" -eq 0 ]

    # Must produce 2 FROM stages (2.25.0 and 2.27.1 — 2.23.0 correctly excluded).
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 2 ]

    # Ceiling 2.27.1 must be present
    echo "$output" | grep -q "AS ext-timescaledb-2_27_1"
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

    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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

    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]
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

    # Must produce 3 multi-version FROM stages (non-vacuous: proves artifact was consumed).
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 3 ]

    # All three version-specific COPY pairs must be present.
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.23.0/extension/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.25.0/extension/"
    echo "$output" | grep -q "/tmp/ext/timescaledb/2.27.1/extension/"
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
