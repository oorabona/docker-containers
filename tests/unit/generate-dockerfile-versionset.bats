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
# Test 2: backward-compat — no versionset → single stage + flat COPY paths
# ---------------------------------------------------------------------------
@test "backward-compat: no versionset → single FROM stage for timescaledb" {
    # No versionset file created — backward-compat path

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Exactly ONE FROM stage for timescaledb
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 1 ]

    # Stage alias uses extension name only (no version suffix)
    echo "$output" | grep -q "FROM.*ext-timescaledb:pg18-2.27.1 AS ext-timescaledb$"
}

@test "backward-compat: no versionset → COPYs go into flat /tmp/ext/timescaledb/{extension,lib}/" {
    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    echo "$output" | grep -q "COPY --from=ext-timescaledb /output/extension/ /tmp/ext/timescaledb/extension/"
    echo "$output" | grep -q "COPY --from=ext-timescaledb /output/lib/ /tmp/ext/timescaledb/lib/"

    # Must NOT have version-subdirectory COPYs
    echo "$output" | grep -qv "/tmp/ext/timescaledb/2\."
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
# Test 4: available=[] in artifact → falls back to SINGLE ceiling version
# (NOT to .resolved[]).
#
# Rationale: .resolved[] may contain versions that were never built (musl-failed
# or simply absent from the registry); COPYing from nonexistent images causes
# the final build to fail. The ONLY version guaranteed to exist is the ceiling
# (ceiling-fatal: build aborts if ceiling fails). So the correct fallback when
# available=[] is the single pinned/ceiling version from config, NOT resolved[].
#
# RED before fix: code falls back to .resolved[] → 2 FROM stages.
# GREEN after fix: code falls back to single ceiling → 1 FROM stage.
# ---------------------------------------------------------------------------
@test "empty-available: artifact with available=[] falls back to single ceiling version, NOT resolved[]" {
    # Artifact: available empty, resolved has 2 entries (2.23.0 never built, 2.27.1 = ceiling)
    cat > "$TEST_TEMP_DIR/.build-lineage/ext-timescaledb-pg18-versionset.json" <<'EOF'
{"ext":"timescaledb","pg_major":"18","ceiling":"2.27.1","resolved":["2.23.0","2.27.1"],"available":[],"excluded":[{"version":"2.23.0","reason":"build failed"},{"version":"2.27.1","reason":"not available"}]}
EOF

    run generate_dockerfile \
        "$TEST_TEMP_DIR/extensions/config.yaml" \
        "$TEST_TEMP_DIR/Dockerfile.template" \
        "timeseries" "18" \
        "ghcr.io" "testowner"

    [ "$status" -eq 0 ]

    # Must fall back to the SINGLE ceiling version (2.27.1), NOT the full resolved[].
    # Before fix: falls back to resolved[] → 2 stages (RED).
    # After fix:  falls back to ceiling config version → 1 stage, flat COPYs (GREEN).
    local from_count
    from_count=$(echo "$output" | grep -c "^FROM ghcr.io/testowner/ext-timescaledb:pg18-")
    [ "$from_count" -eq 1 ]

    # Must use the ceiling version tag (2.27.1 from config .version)
    echo "$output" | grep -q "ext-timescaledb:pg18-2.27.1"

    # Must NOT produce a versioned-subdir COPY path (falls back to single-version flat path)
    ! echo "$output" | grep -q "/tmp/ext/timescaledb/2\."
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
    # No versionset → backward-compat single-version path; no runtime_deps in config
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
