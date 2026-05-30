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

# ── RR: ceiling injected even when absent from HA tags ─────────────────────
# The ceiling is the version we compile from source; it does NOT depend on
# whether timescale/timescaledb-ha has published a matching HA image.
# When the ceiling is absent from HA tags, the resolver must INJECT it and
# return a non-empty set (at least [ceiling]), not hard-fail.

@test "RR-ceiling-not-in-HA: ceiling absent from HA tags → injected into output, exit 0" {
    # CEILING_VERSION=2.27.2 is NOT in the fixture (max is 2.27.1).
    # Before fix: hard-fails (exits non-zero). After fix: exits 0, includes 2.27.2.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.2 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    # The injected ceiling must be present in the output.
    echo "$output" | jq -e 'map(select(. == "2.27.2")) | length > 0' > /dev/null
    # Older HA-discovered versions (e.g. 2.27.1) must also be present.
    echo "$output" | jq -e 'map(select(. == "2.27.1")) | length > 0' > /dev/null
}

@test "RR-ceiling-injected-is-last: injected ceiling appears as last (highest) element" {
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.2 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    last=$(echo "$output" | jq -r '.[-1]')
    [[ "$last" == "2.27.2" ]]
}

@test "RR-HA-newer-excluded: HA tag above ceiling is dropped; ceiling present in output" {
    # Fixture contains tags up to 2.27.1. Append a hypothetical 2.28.0 above ceiling 2.27.1.
    local above_fixture
    above_fixture="$(mktemp)"
    cat "$HA_FIXTURE" > "$above_fixture"
    printf 'pg18.99-ts2.28.0\n' >> "$above_fixture"

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$above_fixture" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    rm -f "$above_fixture"
    [[ "$status" -eq 0 ]]
    # 2.28.0 must be excluded (above ceiling).
    ! echo "$output" | jq -e 'map(select(. == "2.28.0")) | length > 0' > /dev/null
    # Ceiling 2.27.1 must be present.
    echo "$output" | jq -e 'map(select(. == "2.27.1")) | length > 0' > /dev/null
}

@test "RR-empty-HA-degrade: empty HA response + valid CEILING_VERSION → exits non-zero (fail-closed)" {
    # When HA returns no tags at all the resolver has lost its discovery basis.
    # On the publish path this must be fatal (fail-closed): a transient HA-metadata
    # outage must not silently emit [ceiling] and drop every retained older version.
    # The ceiling-only degrade belongs to the CALLER under LOCAL_ONLY/PULL_ONLY,
    # not to the resolver itself.
    # (This test corrects the fail-open oracle introduced in a prior commit.)
    local empty_fixture
    empty_fixture="$(mktemp)"
    > "$empty_fixture"

    # Check exit code via run.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$empty_fixture" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    local exit_status="$status"

    # Check stdout only (capture independently, suppressing stderr).
    local stdout_only
    stdout_only=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$empty_fixture" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>/dev/null || true)

    rm -f "$empty_fixture"
    [[ "$exit_status" -ne 0 ]]
    [[ -z "$stdout_only" ]]
}

@test "RR-garbled-HA-degrade: garbled HA response (no valid ts tags) + valid CEILING_VERSION → exits non-zero (fail-closed)" {
    # A garbled registry response that contains lines but no recognisable HA tags
    # is indistinguishable from a network corruption — fail-closed.
    local garbled_fixture
    garbled_fixture="$(mktemp)"
    printf 'html><body>503 Service Unavailable</body>\n' > "$garbled_fixture"

    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$garbled_fixture" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    local exit_status="$status"

    local stdout_only
    stdout_only=$(env \
        _RESOLVER_HA_TAGS_FIXTURE="$garbled_fixture" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER" 2>/dev/null || true)

    rm -f "$garbled_fixture"
    [[ "$exit_status" -ne 0 ]]
    [[ -z "$stdout_only" ]]
}

@test "RR-ceiling-already-in-HA-idempotent: ceiling present in HA tags is not duplicated" {
    # When ceiling IS in HA tags, injecting it must be idempotent (no duplicate).
    # The standard fixture has pg18 up to 2.27.1, so ceiling=2.27.1 is present.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION=2.27.1 \
        "$RESOLVER"
    [[ "$status" -eq 0 ]]
    # 2.27.1 must appear exactly once.
    count=$(echo "$output" | jq '[.[] | select(. == "2.27.1")] | length')
    [[ "$count" -eq 1 ]]
}

@test "RR-empty-CEILING_VERSION: empty CEILING_VERSION is a configuration error (non-zero exit)" {
    # CEILING_VERSION="" means the caller has no pinned version — which is a real
    # misconfig. The resolver must exit non-zero rather than silently returning an
    # unbounded set that could include versions never validated for build.
    run env \
        _RESOLVER_HA_TAGS_FIXTURE="$HA_FIXTURE" \
        EXT_NAME=timescaledb PG_MAJOR=18 CEILING_VERSION="" \
        "$RESOLVER"
    [[ "$status" -ne 0 ]]
}
