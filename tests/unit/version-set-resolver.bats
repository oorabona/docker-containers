#!/usr/bin/env bats

# Unit tests for helpers/version-set-resolver.sh
# All tests are fixture-driven (no network).

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    HELPER="${PROJECT_ROOT}/helpers/version-set-resolver.sh"
    HA_FIXTURE="${PROJECT_ROOT}/tests/fixtures/resolver/ha-tags.txt"
}

# ── timescaledb has version_set: returns resolver output ─────────────────────

@test "resolve_version_set timescaledb 18 returns the resolver JSON array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '["2.23.0","2.23.1","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.0","2.27.1"]' ]]
}

@test "resolve_version_set timescaledb 18 output is valid JSON array" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
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
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -ne 0 ]]
}

@test "resolver failure produces empty stdout" {
    result=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18" 2>/dev/null || true)
    [[ -z "$result" ]]
}

# ── Different pg_major values produce different arrays via helper ─────────────

@test "timescaledb pg17 floor differs from pg18 floor" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 17"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    # pg17 floor is 2.17.2 (first TS version shipped with pg17 in the HA registry)
    [[ "$first" == "2.17.2" ]]
}

# ── CEILING_VERSION clamps resolver output ────────────────────────────────────

@test "above-ceiling version excluded when CEILING_VERSION is set" {
    # The HA fixture only contains tags up to 2.27.1.
    # The resolver ceiling (from config) is 2.27.1 — so the output must not exceed it.
    # This test uses a synthetic fixture that adds a hypothetical 2.28.0 HA tag
    # to verify the ceiling filter works.
    local above_fixture
    above_fixture="$(mktemp)"
    # Copy the real fixture and append a hypothetical pg18.99-ts2.28.0 tag
    cat "$HA_FIXTURE" > "$above_fixture"
    printf 'pg18.99-ts2.28.0\n' >> "$above_fixture"

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$above_fixture" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    rm -f "$above_fixture"
    [[ "$status" -eq 0 ]]
    # 2.28.0 must NOT appear in the output (ceiling is 2.27.1 from config)
    [[ "$output" != *'"2.28.0"'* ]]
    # The ceiling version itself (2.27.1) must be the last element
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.1" ]]
}

# ── XX: config_file parameter — resolver reads from caller-supplied config ────

@test "XX-temp-config: resolve_version_set uses caller-supplied config, not hard-coded default" {
    # Write a temp config with a DIFFERENT extension at a DIFFERENT ceiling,
    # using the same resolver path (timescaledb-ha.sh).
    # Before fix: reads postgres/extensions/config.yaml → returns real timescaledb set.
    # After fix:  reads temp config → returns single-version fallback (no resolver path
    #             configured under "myext") or uses the ceiling from the temp config.
    #
    # We use a minimal config with ext "myext" at version "9.9.9" and no resolver.
    # resolve_version_set with the temp config must return ["9.9.9"], NOT the
    # timescaledb array from the default config.

    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  myext:
    version: "9.9.9"
    repo: "https://example.com/myext"
YAMLEOF

    run bash -c "source \"$HELPER\"; resolve_version_set myext 18 \"$tmp_config\""
    rm -f "$tmp_config"

    [[ "$status" -eq 0 ]]
    # Must return single-version array from the temp config ceiling
    local ver
    ver=$(echo "$output" | jq -r '.[0]')
    [[ "$ver" == "9.9.9" ]]
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 1 ]]
}

@test "XX-temp-config-ceiling: resolver ceiling is read from caller-supplied config" {
    # Write a temp config with timescaledb at ceiling 2.25.0 (below the real default 2.27.1).
    # Use a resolver path pointing to the real timescaledb-ha.sh resolver.
    # After fix: the ceiling passed to the resolver must be 2.25.0 (from temp config),
    # so 2.26.x and 2.27.x must be absent from the output.

    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    # Point at the real resolver path (relative to project root) with a lower ceiling.
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.25.0"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18 \"$tmp_config\""
    rm -f "$tmp_config"

    [[ "$status" -eq 0 ]]
    # The ceiling from the temp config is 2.25.0, so 2.26.0+ must be absent.
    [[ "$output" != *'"2.26.0"'* ]]
    [[ "$output" != *'"2.27.1"'* ]]
    # The ceiling itself (2.25.0) must be the last element.
    local last
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.25.0" ]]
}

@test "XX-default-fallback: no config_file arg still resolves correctly via default" {
    # Regression: direct invocation without a config_file must still work correctly
    # using the implicit default (postgres/extensions/config.yaml).
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -eq 0 ]]
    # Must return the full timescaledb set from the default config
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -gt 1 ]]
    # The default ceiling 2.27.1 must be the last element
    local last
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.1" ]]
}
