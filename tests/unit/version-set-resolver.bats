#!/usr/bin/env bats

# Unit tests for helpers/version-set-resolver.sh
# All tests are fixture-driven (no network).

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    HELPER="${PROJECT_ROOT}/helpers/version-set-resolver.sh"
    HA_FIXTURE="${PROJECT_ROOT}/tests/fixtures/resolver/ha-tags.txt"
    TS_FIXTURE="${PROJECT_ROOT}/tests/fixtures/resolver/ts-tags.txt"
}

# ── timescaledb has version_set: returns resolver output ─────────────────────

@test "resolve_version_set timescaledb 18 returns the resolver JSON array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '["2.23.0","2.23.1","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.0","2.27.1"]' ]]
}

@test "resolve_version_set timescaledb 18 output is valid JSON array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -eq 0 ]]
    type=$(echo "$output" | jq -r 'type')
    [[ "$type" == "array" ]]
}

# ── Extension without version_set: returns single-version array ──────────────

@test "ext without version_set returns single-version JSON array" {
    run bash -c "source \"$HELPER\"; resolve_version_set pgvector 18"
    [[ "$status" -eq 0 ]]
    type=$(echo "$output" | jq -r 'type')
    [[ "$type" == "array" ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 1 ]]
}

@test "ext without version_set returns the configured version string" {
    run bash -c "source \"$HELPER\"; resolve_version_set pgvector 18"
    [[ "$status" -eq 0 ]]
    ver=$(echo "$output" | jq -r '.[0]')
    [[ "$ver" == "0.8.2" ]]
}

@test "pg_partman without version_set returns single-version array" {
    run bash -c "source \"$HELPER\"; resolve_version_set pg_partman 17"
    [[ "$status" -eq 0 ]]
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 1 ]]
}

# ── Resolver failure propagates non-zero exit ─────────────────────────────────

@test "resolver failure propagates non-zero exit" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -ne 0 ]]
}

@test "resolver failure produces empty stdout" {
    result=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18" 2>/dev/null || true)
    [[ -z "$result" ]]
}

# ── Different pg_major values produce different arrays via helper ─────────────

@test "timescaledb pg17 floor differs from pg18 floor" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _RESOLVER_TS_TAGS_FIXTURE="$TS_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 17"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    # pg17 floor is 2.17.0, not 2.23.0
    [[ "$first" == "2.17.0" ]]
}
