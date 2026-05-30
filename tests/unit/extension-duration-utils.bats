#!/usr/bin/env bats

# Unit tests for sum_flavor_extension_durations() in helpers/extension-duration-utils.sh
#
# 6-case truth table:
#   1. flavor with 3 extensions, all 3 lineage files present → sum of durations
#   2. flavor with 3 extensions, 2 lineage files present (1 skipped) → sum of 2
#   3. flavor with 0 extensions (e.g. "base" flavor with no entries) → 0
#   4. flavor with 3 extensions, 0 lineage files (all skipped) → 0
#   5. config.yaml missing → "null"
#   6. ext_config returns empty version (version unset) → skipped, no error

load "../test_helper"

# ---------------------------------------------------------------------------
# Source helper: push to helpers/ so _EXT_DUR_HELPERS_DIR resolves correctly.
# ---------------------------------------------------------------------------
_source_ext_dur_utils() {
    pushd "$HELPERS_DIR" > /dev/null 2>&1
    # shellcheck disable=SC1091
    source "./extension-duration-utils.sh"
    popd > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir

    # Create a minimal postgres container directory tree
    CONTAINER_DIR="$TEST_TEMP_DIR/postgres"
    EXT_DIR="$CONTAINER_DIR/extensions"
    LINEAGE_DIR="$TEST_TEMP_DIR/.build-lineage"
    mkdir -p "$EXT_DIR" "$LINEAGE_DIR"

    MAJOR_VER="17"

    # Default config: three extensions for flavor "full", none for "base"
    cat > "$EXT_DIR/config.yaml" <<'EOF'
flavors:
  full:
    - pgvector
    - paradedb
    - pg_cron
  base: []
extensions:
  pgvector:
    version: "0.8.0"
    priority: 1
  paradedb:
    version: "0.15.0"
    priority: 2
  pg_cron:
    version: "1.6.4"
    priority: 3
EOF

    # Point ROOT_DIR at our temp tree so extension-duration-utils.sh resolves paths correctly
    export ROOT_DIR="$TEST_TEMP_DIR"
    export PROJECT_ROOT="$TEST_TEMP_DIR"

    _source_ext_dur_utils

    # Install mocks AFTER sourcing — extension-utils.sh defines the real functions;
    # mocks declared before sourcing would be overwritten.
    _setup_default_mocks
}

teardown() {
    teardown_temp_dir
    unset ROOT_DIR PROJECT_ROOT
}

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

# Override get_flavor_extensions to return deterministic extension lists
# for "full" and "base" flavors — avoids yq dependency in tests
_mock_flavor_full() {
    get_flavor_extensions() {
        # config_file=$1, flavor=$2, pg_major=$3
        if [[ "$2" == "full" ]]; then
            printf '%s\n' pgvector paradedb pg_cron
        fi
    }
    export -f get_flavor_extensions
}

_mock_flavor_base_empty() {
    get_flavor_extensions() {
        # "base" flavor has no extensions — return nothing
        true
    }
    export -f get_flavor_extensions
}

# Override ext_config to return deterministic versions
_mock_ext_config_default() {
    ext_config() {
        local ext="$1" key="$2"
        # Only version key matters for our function
        if [[ "$key" == "version" ]]; then
            case "$ext" in
                pgvector)  echo "0.8.0"  ;;
                paradedb)  echo "0.15.0" ;;
                pg_cron)   echo "1.6.4"  ;;
                *)         echo ""       ;;
            esac
        fi
    }
    export -f ext_config
}

# ext_config returns empty version for all extensions
_mock_ext_config_no_version() {
    ext_config() { echo ""; }
    export -f ext_config
}

_setup_default_mocks() {
    _mock_flavor_full
    _mock_ext_config_default
}

# Write a per-extension lineage JSON file to the temp .build-lineage directory
_write_ext_lineage() {
    local ext="$1" pg_major="$2" version="$3" duration="$4"
    local file="$LINEAGE_DIR/ext-${ext}-pg${pg_major}-${version}.json"
    jq -nc \
        --arg ext "$ext" \
        --arg version "$version" \
        --arg pg_major "$pg_major" \
        --argjson duration "$duration" \
        --arg built_at "2026-01-01T00:00:00Z" \
        '{ext:$ext, version:$version, pg_major:$pg_major, duration_seconds:$duration, built_at:$built_at}' \
        > "$file"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Case 1: all 3 lineage files present → sum = 100 + 200 + 50 = 350
@test "1: flavor=full, all 3 lineage files present → sum of durations" {
    _write_ext_lineage "pgvector"  "$MAJOR_VER" "0.8.0"  100
    _write_ext_lineage "paradedb"  "$MAJOR_VER" "0.15.0" 200
    _write_ext_lineage "pg_cron"   "$MAJOR_VER" "1.6.4"  50

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 350 ]
}

# Case 2: 2 lineage files present, 1 skipped (pg_cron absent) → 100 + 200 = 300
@test "2: flavor=full, 2 of 3 lineage files present (1 skipped) → sum of 2" {
    _write_ext_lineage "pgvector"  "$MAJOR_VER" "0.8.0"  100
    _write_ext_lineage "paradedb"  "$MAJOR_VER" "0.15.0" 200
    # pg_cron lineage NOT written (cached, skipped)

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 300 ]
}

# Case 3: "base" flavor has no extensions → 0 (flavor exists, just no compiled extensions)
@test "3: flavor=base with no extensions → 0" {
    _mock_flavor_base_empty

    run sum_flavor_extension_durations "postgres" "base" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

# Case 4: all 3 lineage files absent (all extensions cached/skipped) → 0
@test "4: flavor=full, 0 lineage files (all skipped) → 0" {
    # No lineage files written

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

# Case 5: config.yaml missing → "null"
@test "5: config.yaml missing → null" {
    rm -f "$EXT_DIR/config.yaml"

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

# Case 7: backfill scenario — ceiling lineage file absent, older-version files present
# Before the fix: function only looks up ext-<ext>-pg<major>-<ceiling>.json → 0
# After the fix: function sums all ext-<ext>-pg<major>-*.json present → non-zero
@test "7: backfill — ceiling absent, two older-version lineage files present → sum of older files" {
    # pgvector's ceiling (0.8.0) was already in registry — no lineage written this run.
    # But two older retained versions were backfilled and DID produce lineage files.
    _write_ext_lineage "pgvector"  "$MAJOR_VER" "0.7.0"  120
    _write_ext_lineage "pgvector"  "$MAJOR_VER" "0.7.4"  80
    # NO ext-pgvector-pg17-0.8.0.json (ceiling skipped — already in registry)

    # paradedb and pg_cron also absent (all cached)

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    # Must sum the two older-version files (120+80=200), NOT return 0
    [ "$output" -eq 200 ]
}

# Case 8: versionset artifact file is excluded from duration sum (no duration_seconds field)
@test "8: versionset artifact not counted in duration sum" {
    # Write a normal lineage file and also a versionset artifact (no duration_seconds)
    _write_ext_lineage "pgvector"  "$MAJOR_VER" "0.8.0"  150
    # Write a versionset artifact (the kind written by build-extensions.sh for multi-version)
    jq -nc \
        --arg ext "pgvector" \
        --arg pg_major "$MAJOR_VER" \
        --arg ceiling "0.8.0" \
        '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:["0.8.0"], available:["0.8.0"], excluded:[]}' \
        > "$LINEAGE_DIR/ext-pgvector-pg${MAJOR_VER}-versionset.json"

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    # Must include the 150s lineage file, must NOT crash on versionset (no duration field)
    [ "$output" -eq 150 ]
}

# Case 6: ext_config returns empty version for all → no lineage files exist → returns 0
# (get_flavor_extensions still returns the 3 extensions, but no builds ran for them)
@test "6: ext_config returns empty version → no lineage files → returns 0" {
    _mock_ext_config_no_version
    # No lineage files written — in practice, build-extensions.sh only writes
    # ext-<ext>-pg<major>-<version>.json with a concrete version; empty-version
    # extensions produce no lineage files at all.

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

# Case FF-dur: stale per-version duration files from a previous run that are NOT
# cleaned before invoking sum_flavor_extension_durations would be counted incorrectly.
# After FF fix: build-extensions.sh cleans stale duration files on all success paths
# (including all-cached), so by the time sum_flavor_extension_durations is called
# only current-run files exist. This test verifies the utility returns 0 when
# only stale-but-cleaned (absent) files remain — i.e., an all-cached no-op run
# produces 0 duration, not a stale non-zero from previous runs.
#
# RED before fix (caller side): stale files from previous run survive an all-cached
#   run → sum_flavor_extension_durations returns non-zero (counts stale durations).
# GREEN after fix (caller side): build-extensions.sh cleaned the stale files before
#   calling sum_flavor_extension_durations → no files → sum returns 0.
# This test asserts the behavior of the utility with no files present (as produced
# by a fully-cleaned all-cached run).
@test "FF-dur: no per-version files (cleaned by caller) → sum returns 0 for no-op run" {
    # Simulate the post-cleanup state: no per-version duration files exist.
    # (build-extensions.sh removed them; sum_flavor_extension_durations should return 0.)

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}
