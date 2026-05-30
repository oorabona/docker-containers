#!/usr/bin/env bats

# Unit tests for scripts/resolvers/timescaledb-ha.sh
# All tests are fixture-driven (no network).
# Fixture: tests/fixtures/resolver/ha-tags.txt
# Real HA tag format: pg<MAJOR>.<pgminor>-ts<X.Y.Z>[-suffix]

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    RESOLVER="${PROJECT_ROOT}/scripts/resolvers/timescaledb-ha.sh"
    HA_FIXTURE="${PROJECT_ROOT}/tests/fixtures/resolver/ha-tags.txt"
}

# ── pg18: exact 13-version array ─────────────────────────────────────────────

@test "pg18 produces exactly the 13-version array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '["2.23.0","2.23.1","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.0","2.27.1"]' ]]
}

@test "pg18 array has 13 elements" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 13 ]]
}

# ── pg17: floor 2.17.2 ────────────────────────────────────────────────────────

@test "pg17 floor is 2.17.2" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=17 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    [[ "$first" == "2.17.2" ]]
}

@test "pg17 array has 32 elements" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=17 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 32 ]]
}

@test "pg17 array ends at 2.27.1" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=17 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.1" ]]
}

# ── pg16: floor 2.13.0, 45 versions ──────────────────────────────────────────

@test "pg16 floor is 2.13.0" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=16 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    [[ "$first" == "2.13.0" ]]
}

@test "pg16 array has 45 elements" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=16 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 45 ]]
}

# ── Suffix variants do not create extra versions or affect results ─────────────

@test "suffix variants (-oss/-all/-all-oss) do not create extra versions" {
    # The fixture contains -all, -all-oss, and -oss suffixed variants.
    # The resolver must de-duplicate and produce only clean X.Y.Z versions.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 13 ]]
}

@test "output contains no -oss suffixed versions" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    ! echo "$output" | jq -e '.[] | select(contains("-"))' > /dev/null 2>&1
}

@test "output contains no v-prefixed versions" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    ! echo "$output" | jq -e '.[] | select(startswith("v"))' > /dev/null 2>&1
}

@test "output is sorted oldest to newest" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    sorted=$(echo "$output" | jq -r '.[]' | sort -V | jq -Rsc 'split("\n") | map(select(length > 0))')
    [[ "$output" == "$sorted" ]]
}

# ── Output is valid JSON array ────────────────────────────────────────────────

@test "output is valid JSON array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    type=$(echo "$output" | jq -r 'type')
    [[ "$type" == "array" ]]
}

# ── Fail-closed: missing HA fixture → non-zero + empty stdout ─────────────────

@test "missing HA fixture exits non-zero" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}

@test "missing HA fixture produces empty stdout" {
    result=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>/dev/null || true)
    [[ -z "$result" ]]
}

# ── Fail-closed: unknown PG_MAJOR → non-zero ────────────────────────────────

@test "unknown PG_MAJOR exits non-zero" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=99 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}

# ── CEILING_VERSION respected ────────────────────────────────────────────────

@test "CEILING_VERSION clamps output" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.24.0 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.24.0" ]]
    ! echo "$output" | jq -e '.[] | select(startswith("2.25"))' > /dev/null 2>&1
}

# ── H: actionable error messages reach stderr ─────────────────────────────────

@test "H-unsupported-pg: unknown PG_MAJOR exits non-zero and emits 'no HA tags' on stderr" {
    local combined
    combined=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=99 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>&1 || true)
    [[ "$combined" == *"no HA tags"* ]]
}

# ── I: configured CEILING_VERSION absent from upstream tags → non-zero + actionable error ──

@test "I-ceiling-absent: configured CEILING_VERSION not in upstream tags exits non-zero" {
    # ceiling 2.28.0 is NOT present in the fixture (tops out at 2.27.1).
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.28.0 \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}

@test "I-ceiling-absent: configured CEILING_VERSION not in upstream tags emits actionable error" {
    local combined
    combined=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.28.0 \
        "$RESOLVER" 2>&1 || true)
    # Must mention the configured version so the operator knows what to fix
    [[ "$combined" == *"2.28.0"* ]]
}
