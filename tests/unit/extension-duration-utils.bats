#!/usr/bin/env bats

# Unit tests for sum_flavor_extension_durations() in helpers/extension-duration-utils.sh
#
# 6-case truth table:
#   1. flavor with 3 extensions, all 3 lineage files present → sum of durations
#   2. flavor with 3 extensions, 2 lineage files present (1 skipped) → sum of 2
#   3. flavor with 0 extensions (e.g. "base" flavor with no entries) → "null"
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

# Case 3: "base" flavor has no extensions → "null"
@test "3: flavor=base with no extensions → null" {
    _mock_flavor_base_empty

    run sum_flavor_extension_durations "postgres" "base" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
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

# Case 6: ext_config returns empty version for all → all skipped, returns 0
# (get_flavor_extensions still returns the 3 extensions, but ext_config yields no version)
@test "6: ext_config returns empty version → all extensions skipped, returns 0" {
    _mock_ext_config_no_version
    # Even with lineage files present, they can't be looked up without a version
    _write_ext_lineage "pgvector"  "$MAJOR_VER" "" 100  # wrong name, won't match
    _write_ext_lineage "paradedb"  "$MAJOR_VER" "" 200

    run sum_flavor_extension_durations "postgres" "full" "$MAJOR_VER"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}
