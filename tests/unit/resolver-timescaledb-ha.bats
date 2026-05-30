#!/usr/bin/env bats

# Unit tests for scripts/resolvers/timescaledb-ha.sh
# All tests are fixture-driven (no network).

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    RESOLVER="${PROJECT_ROOT}/scripts/resolvers/timescaledb-ha.sh"
    HA_FIXTURE="${PROJECT_ROOT}/tests/fixtures/resolver/ha-tags.txt"
    TS_FIXTURE="${PROJECT_ROOT}/tests/fixtures/resolver/ts-tags.txt"
}

# ── pg18: exact 13-version array ─────────────────────────────────────────────

@test "pg18 produces exactly the 13-version array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '["2.23.0","2.23.1","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.0","2.27.1"]' ]]
}

@test "pg18 array has 13 elements" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 13 ]]
}

# ── pg17: floor 2.17 ──────────────────────────────────────────────────────────

@test "pg17 floor is 2.17.0" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=17 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    [[ "$first" == "2.17.0" ]]
}

@test "pg17 array starts at 2.17 and ends at 2.27.1" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=17 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.1" ]]
}

# ── pg16: floor 2.13 ──────────────────────────────────────────────────────────

@test "pg16 floor is 2.13.0" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=16 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    [[ "$first" == "2.13.0" ]]
}

# ── Filtering: -p0, v-prefix, pre-release must be excluded ───────────────────

@test "output contains no -p0 suffixed versions" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    # None of the entries contain a dash
    ! echo "$output" | jq -e '.[] | select(contains("-"))' > /dev/null 2>&1
}

@test "output contains no v-prefixed versions" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    ! echo "$output" | jq -e '.[] | select(startswith("v"))' > /dev/null 2>&1
}

@test "output is sorted oldest to newest" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    # Verify array equals itself sorted by sort -V
    sorted=$(echo "$output" | jq -r '.[]' | sort -V | jq -Rsc 'split("\n") | map(select(length > 0))')
    [[ "$output" == "$sorted" ]]
}

# ── Output is valid JSON array ────────────────────────────────────────────────

@test "output is valid JSON array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
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
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}

@test "missing HA fixture produces empty stdout" {
    result=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>/dev/null || true)
    [[ -z "$result" ]]
}

# ── Fail-closed: missing TS fixture → non-zero + empty stdout ────────────────

@test "missing TS fixture exits non-zero" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="/nonexistent/ts.txt" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}

@test "missing TS fixture produces empty stdout" {
    result=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="/nonexistent/ts.txt" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>/dev/null || true)
    [[ -z "$result" ]]
}

# ── Fail-closed: unknown PG_MAJOR → non-zero ────────────────────────────────

@test "unknown PG_MAJOR exits non-zero" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=99 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}

# ── CEILING_VERSION respected ────────────────────────────────────────────────

@test "CEILING_VERSION clamps output" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.24.0 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.24.0" ]]
    # 2.27.x should not appear
    ! echo "$output" | jq -e '.[] | select(startswith("2.25"))' > /dev/null 2>&1
}

# ── -all / -oss variants in HA tags are tolerated (not counted as separate floors) ──

@test "-all and -oss HA tag variants do not affect floor detection" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    # Floor must still be 2.23.0 despite -all/-oss variants being present
    [[ "$first" == "2.23.0" ]]
}

# ── H: actionable error messages reach stderr ─────────────────────────────────

@test "H-unsupported-pg: unknown PG_MAJOR exits non-zero and emits 'no HA tags' on stderr" {
    # HA fixture has no tags for PG_MAJOR=99 so the grep for pg99-ts* returns
    # nothing. Before the fix: grep exits 1, set -e aborts before _error fires
    # → stderr is empty. After the fix: empty capture then explicit _error.
    local combined
    combined=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=99 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>&1 || true)
    [[ "$combined" == *"no HA tags"* ]]
}

@test "H-no-semver-tags: TS fixture with only non-semver tags exits non-zero and emits 'no valid semver' on stderr" {
    # A TS fixture that contains only v-prefixed / pre-release tags means the
    # bare-semver grep returns nothing. Before the fix: set -e aborts silently.
    # After the fix: empty capture then explicit _error with actionable message.
    local no_semver_fixture
    no_semver_fixture="$(mktemp)"
    printf 'v2.27.1\n2.27.1-rc1\n2.27.0-beta\n' > "$no_semver_fixture"
    local combined
    combined=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$no_semver_fixture" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>&1 || true)
    rm -f "$no_semver_fixture"
    [[ "$combined" == *"no valid semver"* ]]
}
