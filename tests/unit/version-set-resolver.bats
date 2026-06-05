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

@test "resolve_version_set timescaledb 18 returns the capped resolver JSON array" {
    # Default retain_count=12 from config.yaml: pg18 fixture has 13 versions (2.23.0..2.27.1)
    # plus the ceiling (2.27.2) injected by the resolver = 14 total; capped to 12.
    # The two oldest (2.23.0, 2.23.1) are dropped; result is 2.24.0..2.27.2 (12 elements).
    # _COMMITTED_VERSIONSET_FILE=/nonexistent forces the live resolver path.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _COMMITTED_VERSIONSET_FILE=/nonexistent \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -eq 0 ]]
    [[ "$output" == '["2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.0","2.27.1","2.27.2"]' ]]
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
# When the committed version-set file is absent/misses the major, the live resolver
# is the only path.  A live resolver failure must propagate non-zero exit (fail-closed).
# (When the committed file covers the major, the fast path succeeds without the
# live resolver — see CV-hit-no-live below.)

@test "resolver failure propagates non-zero exit when committed file absent" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "
            source \"$HELPER\"
            _COMMITTED_VERSIONSET_FILE='/nonexistent/timescaledb-version-set.json'
            resolve_version_set timescaledb 18
        "
    [[ "$status" -ne 0 ]]
}

@test "resolver failure produces empty stdout when committed file absent" {
    result=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "
            source \"$HELPER\"
            _COMMITTED_VERSIONSET_FILE='/nonexistent/timescaledb-version-set.json'
            resolve_version_set timescaledb 18
        " 2>/dev/null || true)
    [[ -z "$result" ]]
}

# ── Different pg_major values produce different arrays via helper ─────────────

@test "timescaledb pg17 floor differs from pg18 floor" {
    # With default retain_count=12 and ceiling=2.27.2, pg17 fixture has versions up to
    # 2.27.1 + injected ceiling 2.27.2 = many total; tail-12 starts at 2.24.0.
    # _COMMITTED_VERSIONSET_FILE=/nonexistent forces the live resolver path.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _COMMITTED_VERSIONSET_FILE=/nonexistent \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 17"
    [[ "$status" -eq 0 ]]
    first=$(echo "$output" | jq -r '.[0]')
    [[ "$first" == "2.24.0" ]]
}

# ── CEILING_VERSION clamps resolver output ────────────────────────────────────

@test "above-ceiling version excluded when CEILING_VERSION is set" {
    # The HA fixture contains tags up to 2.27.1; config ceiling is 2.27.2.
    # This test uses a synthetic fixture that adds a hypothetical 2.28.0 HA tag
    # to verify the ceiling filter excludes it.
    # _COMMITTED_VERSIONSET_FILE=/nonexistent forces the live resolver path.
    local above_fixture
    above_fixture="$(mktemp)"
    # Copy the real fixture and append a hypothetical pg18.99-ts2.28.0 tag
    cat "$HA_FIXTURE" > "$above_fixture"
    printf 'pg18.99-ts2.28.0\n' >> "$above_fixture"

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$above_fixture" \
        _COMMITTED_VERSIONSET_FILE=/nonexistent \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    rm -f "$above_fixture"
    [[ "$status" -eq 0 ]]
    # 2.28.0 must NOT appear in the output (ceiling is 2.27.2 from config)
    [[ "$output" != *'"2.28.0"'* ]]
    # The ceiling version itself (2.27.2) must be the last element
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.2" ]]
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
    # Default retain_count=12 in config.yaml so count must be exactly 12.
    # _COMMITTED_VERSIONSET_FILE=/nonexistent forces the live resolver path.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        _COMMITTED_VERSIONSET_FILE=/nonexistent \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 18"
    [[ "$status" -eq 0 ]]
    # Must return the capped timescaledb set from the default config (retain_count=12)
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 12 ]]
    # The default ceiling 2.27.2 must be the last element
    local last
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.2" ]]
}

# ── RC: retain_count config key threading ────────────────────────────────────

@test "RC-config-retain5: retain_count=5 in config threads through to resolver" {
    # A temp config with retain_count=5 must produce <=5 versions, ceiling last.
    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 5
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 16 \"$tmp_config\""
    rm -f "$tmp_config"

    [[ "$status" -eq 0 ]]
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 5 ]]
    local last
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.1" ]]
}

@test "RC-config-no-retain: absent retain_count in config defaults to 12" {
    # A temp config without retain_count must apply the default of 12.
    # pg16 has 45 versions in the fixture; result must be 12.
    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.27.1"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        bash -c "source \"$HELPER\"; resolve_version_set timescaledb 16 \"$tmp_config\""
    rm -f "$tmp_config"

    [[ "$status" -eq 0 ]]
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 12 ]]
    local last
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.1" ]]
}

# ── BA-4: missing version in non-resolver ext → fail fast, NOT ["null"] ──────

@test "BA4-null-version-failclosed: non-resolver ext with no version field → non-zero exit, no null in output" {
    # Before fix: yq returns "null" for missing field → emit ["null"] → bogus set.
    # After fix:  detect null/empty version → fail fast with non-zero exit.

    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    # Config with an extension that has NO version field at all.
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  myext:
    repo: "https://example.com/myext"
YAMLEOF

    run bash -c "source \"$HELPER\"; resolve_version_set myext 18 \"$tmp_config\""
    rm -f "$tmp_config"

    # Must fail (non-zero) — missing version is invalid config.
    [[ "$status" -ne 0 ]]

    # Output must NOT contain the string "null" as a version value.
    [[ "$output" != *'"null"'* ]]
    [[ "$output" != *'["null"]'* ]]
}

@test "BA4-empty-version-failclosed: non-resolver ext with empty version string → non-zero exit" {
    # An extension with version: "" (empty string) must also fail fast, not emit [""].

    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  myext:
    version: ""
    repo: "https://example.com/myext"
YAMLEOF

    run bash -c "source \"$HELPER\"; resolve_version_set myext 18 \"$tmp_config\""
    rm -f "$tmp_config"

    # Must fail — empty version is invalid config.
    [[ "$status" -ne 0 ]]

    # Output must not be a valid non-empty array with empty or null element.
    [[ "$output" != *'[""]'* ]]
}

# ── CV: _read_committed_versionset — committed file fast path ─────────────────

@test "CV-hit: _read_committed_versionset returns committed slice when file+major present" {
    # Write a minimal committed file with a pg18 entry.
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.24.0","2.25.0","2.27.2"],"pg17":["2.24.0","2.27.2"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _read_committed_versionset timescaledb 18
    "
    rm -f "$tmp_committed"

    [[ "$status" -eq 0 ]]
    # Must return the committed pg18 slice exactly
    [[ "$output" == '["2.24.0","2.25.0","2.27.2"]' ]]
}

@test "CV-miss-absent: _read_committed_versionset exits non-zero when file is absent" {
    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"/nonexistent/timescaledb-version-set.json\"
        _read_committed_versionset timescaledb 18
    "
    [[ "$status" -ne 0 ]]
    [[ -z "$output" ]]
}

@test "CV-miss-major: _read_committed_versionset exits non-zero when major key missing" {
    # File present but pg15 key absent.
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.27.2"],"pg17":["2.27.2"],"pg16":["2.27.2"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _read_committed_versionset timescaledb 15
    "
    rm -f "$tmp_committed"

    [[ "$status" -ne 0 ]]
    [[ -z "$output" ]]
}

@test "CV-miss-ext: _read_committed_versionset exits non-zero when ext key missing" {
    # File present but pgvector key absent (only timescaledb in file).
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.27.2"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _read_committed_versionset pgvector 18
    "
    rm -f "$tmp_committed"

    [[ "$status" -ne 0 ]]
    [[ -z "$output" ]]
}

@test "CV-hit-no-live: resolve_version_set uses committed slice, live resolver NOT called" {
    # Wire: committed file has a pg18 entry with ceiling=2.27.2 (matches config ceiling)
    # AND committed_len (12) >= retain_count (12) — both acceptance conditions satisfied.
    # The live resolver (timescaledb-ha.sh) is pointed at a nonexistent fixture so any
    # live-path invocation would fail.  The fast path must return the committed slice
    # without invoking the live resolver (observable: exit 0 despite bad fixture).
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.22.0","2.23.0","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.2"]}}
JSONEOF

    # Temp config: real resolver path, ceiling=2.27.2 (matches committed ceiling),
    # retain_count=12 (committed_len=12 >= retain_count=12 → fast path accepted).
    # Any live invocation of timescaledb-ha.sh would fail because fixture is absent.
    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.27.2"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 12
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "
            source \"$HELPER\"
            _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
            resolve_version_set timescaledb 18 \"$tmp_config\"
        "

    rm -f "$tmp_committed" "$tmp_config"

    # Must succeed: committed slice returned (trimmed to 12), live resolver never reached
    [[ "$status" -eq 0 ]]
    [[ "$output" == '["2.22.0","2.23.0","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.2"]' ]]
}

@test "CV-miss-fallback: resolve_version_set falls through to live resolver on committed miss" {
    # Committed file exists but covers only pg18 (not pg19 → miss).
    # The live resolver is timescaledb-ha.sh pointed at a nonexistent fixture → fails.
    # Proof: overall exit is non-zero (live resolver was invoked and failed on miss,
    # not the committed fast path returning successfully).
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.27.2"]}}
JSONEOF

    # Temp config uses the real resolver with a nonexistent fixture, ceiling=2.27.2.
    # pg19 is not in the committed file (miss) and the fixture is nonexistent (resolver fails).
    # Version must match committed ceiling so the ceiling-mismatch guard doesn't interfere;
    # the miss is on pg19 (key absent), not on version mismatch.
    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.27.2"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 12
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "
            source \"$HELPER\"
            _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
            resolve_version_set timescaledb 19 \"$tmp_config\" 2>/dev/null
        "

    rm -f "$tmp_committed" "$tmp_config"

    # Must fail: committed miss for pg19, live resolver also fails (bad fixture) → non-zero
    [[ "$status" -ne 0 ]]
    # Must produce no stdout (live resolver failed, fail-closed; stderr suppressed)
    [[ -z "$output" ]]
}

# ── CV-trim: committed fast path respects retain_count ───────────────────────

@test "CV-trim-retain5: committed fast path trims to retain_count when slice is larger" {
    # Committed file has 12 versions for pg18, caller config has retain_count=5.
    # Fast path must return only the last 5 (newest, ceiling-inclusive), not all 12.
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.22.0","2.23.0","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.2"]}}
JSONEOF

    # Config with retain_count=5 and ceiling=2.27.2 (matches committed ceiling).
    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.27.2"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 5
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "
            source \"$HELPER\"
            _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
            resolve_version_set timescaledb 18 \"$tmp_config\"
        "

    rm -f "$tmp_committed" "$tmp_config"

    # Must succeed: committed fast path used (live resolver fixture absent but never reached)
    [[ "$status" -eq 0 ]]
    # Result must be exactly the last 5 elements (newest, ceiling-inclusive)
    local count
    count=$(echo "$output" | jq 'length')
    [[ "$count" -eq 5 ]]
    # The last element must be the ceiling
    local last
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.2" ]]
    # The first element must be the 8th of the 12 (index 7: 2.26.1)
    local first
    first=$(echo "$output" | jq -r '.[0]')
    [[ "$first" == "2.26.1" ]]
}

@test "CV-under-retain-fallthrough: committed fast path bypassed when committed_len < retain_count" {
    # Finding 1 fix: when committed_len (2) < retain_count (5), the fast path must NOT
    # serve the committed slice (would silently under-retain). It must fall through to
    # the live resolver. Observable: exit non-zero because the live resolver's fixture
    # is absent (nonexistent) — proving the live resolver was invoked, not the fast path.
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.25.0","2.27.2"]}}
JSONEOF

    # Config with retain_count=5 and ceiling=2.27.2 (matches committed ceiling).
    # committed_len=2 < retain_count=5 → fast path rejected → live resolver invoked.
    local tmp_config
    tmp_config="$(mktemp --suffix=.yaml)"
    cat > "$tmp_config" <<'YAMLEOF'
extensions:
  timescaledb:
    version: "2.27.2"
    repo: "https://github.com/timescale/timescaledb"
    version_set:
      resolver: "scripts/resolvers/timescaledb-ha.sh"
      retain_count: 5
YAMLEOF

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="/nonexistent/ha.txt" \
        bash -c "
            source \"$HELPER\"
            _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
            resolve_version_set timescaledb 18 \"$tmp_config\" 2>/dev/null
        "

    rm -f "$tmp_committed" "$tmp_config"

    # Must fail: committed slice has only 2 entries but retain_count=5, so the fast
    # path falls through to the live resolver, which fails because the fixture is absent.
    [[ "$status" -ne 0 ]]
    # No stdout (live resolver failed, fail-closed)
    [[ -z "$output" ]]
}

# ── CVS: _committed_versionset_satisfies — shared acceptance predicate ────────

@test "CVS-hit: _committed_versionset_satisfies returns 0 when ceiling+len match" {
    local tmp_committed
    tmp_committed="$(mktemp)"
    # 12-entry pg18 slice with ceiling 2.27.2 matches config ceiling and retain_count=12.
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.22.0","2.23.0","2.24.0","2.25.0","2.25.1","2.25.2","2.26.0","2.26.1","2.26.2","2.26.3","2.26.4","2.27.2"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _committed_versionset_satisfies timescaledb 18 2.27.2 12
    "
    rm -f "$tmp_committed"
    [[ "$status" -eq 0 ]]
}

@test "CVS-miss-ceiling: _committed_versionset_satisfies returns 1 on ceiling mismatch" {
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.26.0","2.27.1"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _committed_versionset_satisfies timescaledb 18 2.27.2 1
    "
    rm -f "$tmp_committed"
    [[ "$status" -ne 0 ]]
}

@test "CVS-miss-len: _committed_versionset_satisfies returns 1 when committed_len < retain_count" {
    local tmp_committed
    tmp_committed="$(mktemp)"
    # 2-entry slice, ceiling matches, but retain_count=5 requires at least 5 entries.
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.25.0","2.27.2"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _committed_versionset_satisfies timescaledb 18 2.27.2 5
    "
    rm -f "$tmp_committed"
    [[ "$status" -ne 0 ]]
}

@test "CVS-miss-absent: _committed_versionset_satisfies returns 1 when file absent" {
    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"/nonexistent/timescaledb-version-set.json\"
        _committed_versionset_satisfies timescaledb 18 2.27.2 12
    "
    [[ "$status" -ne 0 ]]
}

@test "CVS-miss-major: _committed_versionset_satisfies returns 1 when major key missing" {
    local tmp_committed
    tmp_committed="$(mktemp)"
    cat > "$tmp_committed" <<'JSONEOF'
{"timescaledb":{"pg18":["2.27.2"]}}
JSONEOF

    run bash -c "
        source \"$HELPER\"
        _COMMITTED_VERSIONSET_FILE=\"$tmp_committed\"
        _committed_versionset_satisfies timescaledb 15 2.27.2 1
    "
    rm -f "$tmp_committed"
    [[ "$status" -ne 0 ]]
}
