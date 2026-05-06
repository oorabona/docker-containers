#!/usr/bin/env bats

# Unit tests for variant_deps_for_flavor() in generate-dashboard.sh
#
# Uses the real postgres flavor files and config.yaml — no fixtures needed.
# generate-dashboard.sh is sourceable (BASH_SOURCE guard prevents generate_data
# from running), so we source it and call variant_deps_for_flavor directly.
#
# Array comparisons use sorted order (jq 'sort') because the intersection
# preserves dependency_sources YAML key order, not flavor extension list order.
#
# NOTE: We explicitly source extension-utils.sh before generate-dashboard.sh.
# When bats sources generate-dashboard.sh, SCRIPT_DIR is initially set to the
# bats binary directory (not the repo root), so generate-dashboard.sh's
# internal `source "$SCRIPT_DIR/helpers/..."` calls fail silently.
# By sourcing extension-utils.sh explicitly first, get_flavor_extensions_yaml
# is available when variant_deps_for_flavor calls it.
# SCRIPT_DIR is then overridden AFTER sourcing to point to the real repo root
# so that variant_deps_for_flavor resolves config.yaml files correctly.

setup() {
    ORIG_DIR="$PWD"
    # Stay in the repo root so relative paths in get_flavor_extensions_yaml
    # (uses "postgres/flavors/<f>.yaml") resolve correctly.

    source "$ORIG_DIR/helpers/logging.sh"           2>/dev/null || true
    source "$ORIG_DIR/helpers/variant-utils.sh"     2>/dev/null || true
    # Source extension-utils.sh explicitly — generate-dashboard.sh's internal
    # source of this file uses SCRIPT_DIR which is wrong at source time.
    source "$ORIG_DIR/helpers/extension-utils.sh"   2>/dev/null || true
    source "$ORIG_DIR/generate-dashboard.sh"        2>/dev/null || true

    # Override SCRIPT_DIR to the real repo root AFTER sourcing.
    # generate-dashboard.sh sets SCRIPT_DIR="$(dirname "$0")" which resolves
    # to the bats binary directory when sourced — this corrects it.
    export SCRIPT_DIR="$ORIG_DIR"
}

teardown() {
    cd "$ORIG_DIR" || true
}

# ---------------------------------------------------------------------------
# postgres: per-flavor extension mapping
# ---------------------------------------------------------------------------

@test "postgres base flavor has 0 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "base")
    [ "$result" = "[]" ]
}

@test "postgres vector flavor has 4 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "vector")
    [ "$(echo "$result" | jq 'length')" = "4" ]
    expected='["pgvector","paradedb","pg_cron","pg_ivm"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

@test "postgres analytics flavor has 6 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "analytics")
    [ "$(echo "$result" | jq 'length')" = "6" ]
    expected='["pg_partman","hypopg","pg_qualstats","postgis","pg_cron","pg_ivm"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

@test "postgres timeseries flavor has 5 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "timeseries")
    [ "$(echo "$result" | jq 'length')" = "5" ]
    expected='["timescaledb","pg_partman","postgis","pg_cron","pg_ivm"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

@test "postgres spatial flavor has 3 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "spatial")
    [ "$(echo "$result" | jq 'length')" = "3" ]
    expected='["postgis","pg_cron","pg_ivm"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

@test "postgres distributed flavor has 3 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "distributed")
    [ "$(echo "$result" | jq 'length')" = "3" ]
    expected='["citus","pg_cron","pg_ivm"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

@test "postgres full flavor has all 10 monitored extensions" {
    result=$(variant_deps_for_flavor "postgres" "full")
    [ "$(echo "$result" | jq 'length')" = "10" ]
    expected='["pgvector","paradedb","pg_partman","hypopg","pg_qualstats","postgis","citus","timescaledb","pg_cron","pg_ivm"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

# ---------------------------------------------------------------------------
# Non-postgres: container-wide monitored deps (no flavor filtering)
# ---------------------------------------------------------------------------

@test "web-shell alpine variant falls back to container-wide deps" {
    # web-shell has no flavor concept — variant name is ignored,
    # returns container-wide monitored dep names.
    result=$(variant_deps_for_flavor "web-shell" "alpine")
    expected='["TTYD_VERSION"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

@test "web-shell with empty flavor returns container-wide deps" {
    result=$(variant_deps_for_flavor "web-shell" "")
    expected='["TTYD_VERSION"]'
    [ "$(echo "$result" | jq -c 'sort')" = "$(echo "$expected" | jq -c 'sort')" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "unknown container returns empty array" {
    result=$(variant_deps_for_flavor "nonexistent-container-xyz" "base")
    [ "$result" = "[]" ]
}

@test "postgres unknown flavor returns []" {
    result=$(variant_deps_for_flavor "postgres" "totally-fake-flavor-xyz")
    [ "$result" = "[]" ]
}

@test "postgres empty flavor returns []" {
    result=$(variant_deps_for_flavor "postgres" "")
    [ "$result" = "[]" ]
}

@test "postgres 'null' flavor returns []" {
    result=$(variant_deps_for_flavor "postgres" "null")
    [ "$result" = "[]" ]
}

@test "container without dependency_sources returns []" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/no-deps"
    printf 'name: no-deps\n' > "$tmpdir/no-deps/config.yaml"
    local saved_script_dir="$SCRIPT_DIR"
    SCRIPT_DIR="$tmpdir"
    result=$(variant_deps_for_flavor "no-deps" "")
    SCRIPT_DIR="$saved_script_dir"
    rm -rf "$tmpdir"
    [ "$result" = "[]" ]
}
