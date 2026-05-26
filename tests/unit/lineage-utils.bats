#!/usr/bin/env bats

# Unit tests for helpers/lineage-utils.sh
# Tests is_lineage_sidecar() — single source of truth for sidecar identification.

load "../test_helper"

setup() {
    setup_temp_dir
    # shellcheck source=../../helpers/lineage-utils.sh
    source "${HELPERS_DIR}/lineage-utils.sh"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# is_lineage_sidecar: true (return 0) cases
# ---------------------------------------------------------------------------

@test "is_lineage_sidecar: *.sbom.json returns 0 (sidecar)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'foo-1.0-alpine.sbom.json'"
    [ "$status" -eq 0 ]
}

@test "is_lineage_sidecar: *.changelog.json returns 0 (sidecar)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'foo-1.0-alpine.changelog.json'"
    [ "$status" -eq 0 ]
}

@test "is_lineage_sidecar: *.history.json returns 0 (sidecar)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'bar-2.0-ubuntu.history.json'"
    [ "$status" -eq 0 ]
}

@test "is_lineage_sidecar: ext-*.json returns 0 (sidecar)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'ext-php-1.0-alpine.json'"
    [ "$status" -eq 0 ]
}

@test "is_lineage_sidecar: ext-anything.json returns 0 (sidecar)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'ext-whatever-here.json'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# is_lineage_sidecar: false (return 1) cases — real lineage files
# ---------------------------------------------------------------------------

@test "is_lineage_sidecar: plain *.json returns 1 (lineage file)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'foo-1.0-alpine.json'"
    [ "$status" -eq 1 ]
}

@test "is_lineage_sidecar: versioned plain *.json returns 1" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'postgres-17.2-alpine.json'"
    [ "$status" -eq 1 ]
}

@test "is_lineage_sidecar: container with dots in tag returns 1" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'php-8.4-fpm-alpine.json'"
    [ "$status" -eq 1 ]
}

@test "is_lineage_sidecar: empty string returns 1 (not a sidecar)" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar ''"
    [ "$status" -eq 1 ]
}

@test "is_lineage_sidecar: file without .json extension returns 1" {
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'foo-1.0.sbom'"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Mutation guard: sidecar suffix must be a full compound suffix
# A file like "foo.json" (plain) must NOT match *.sbom.json
# ---------------------------------------------------------------------------

@test "is_lineage_sidecar: file named just 'sbom.json' is NOT a sidecar (no leading dot)" {
    # The pattern *.sbom.json requires at least one char before .sbom.json
    # "sbom.json" does NOT match "*.sbom.json" in bash case
    run bash -c "source '${HELPERS_DIR}/lineage-utils.sh'; is_lineage_sidecar 'sbom.json'"
    # sbom.json does not have a dot before sbom — it's "sbom.json" not "*.sbom.json"
    # bash case: *.sbom.json matches "anything.sbom.json", so "sbom.json" has no .sbom suffix → 1
    [ "$status" -eq 1 ]
}
