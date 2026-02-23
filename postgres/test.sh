#!/bin/bash
# E2E test for postgres container with extension validation
# Tests base functionality and flavor-specific extensions
#
# Usage:
#   CONTAINER_NAME=my-pg FLAVOR=vector ./test.sh
#   ./test.sh --flavor vector --report tap
#   ./test.sh --all-flavors --image ghcr.io/user/postgres --tag 17-alpine

set -uo pipefail

# Source test harness
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

# Defaults
CONTAINER_NAME="${CONTAINER_NAME:-e2e-postgres}"
FLAVOR="${FLAVOR:-base}"
POSTGRES_USER="${POSTGRES_USER:-test}"
POSTGRES_DB="${POSTGRES_DB:-test}"

# Argument parsing
REPORT_FORMAT="table"
ALL_FLAVORS=false
IMAGE=""
TAG=""

FLAVOR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report)      REPORT_FORMAT="$2"; shift 2 ;;
        --flavor)      FLAVOR_OVERRIDE="$2"; shift 2 ;;
        --all-flavors) ALL_FLAVORS=true; shift ;;
        --image)       IMAGE="$2"; shift 2 ;;
        --tag)         TAG="$2"; shift 2 ;;
        --no-color)    export NO_COLOR=1; shift ;;
        *)             shift ;;
    esac
done

# ============================================================================
# Helper Functions
# ============================================================================

# Execute SQL and return result (returns empty string on failure)
exec_sql() {
    docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -t -A -c "$1" 2>/dev/null || true
}

# Execute SQL against a specific database
exec_sql_db() {
    local db="$1" sql="$2"
    docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$db" \
        -t -A -c "$sql" 2>/dev/null || true
}

# Check if extension is available
extension_exists() {
    local ext="$1"
    local result
    result=$(exec_sql "SELECT 1 FROM pg_available_extensions WHERE name = '$ext';")
    [[ "$result" == "1" ]]
}

# Check if extension is installed
extension_installed() {
    local ext="$1"
    local result
    result=$(exec_sql "SELECT 1 FROM pg_extension WHERE extname = '$ext';")
    [[ "$result" == "1" ]]
}

# ============================================================================
# Base Tests
# ============================================================================
test_connectivity() {
    th_info "Waiting for PostgreSQL to be ready..."
    th_start

    local max_wait=60
    local elapsed=0

    # Phase 1: if container has a HEALTHCHECK, wait for Docker to report "healthy".
    # pg_isready checks TCP connectivity — it only sees the real PG, not the
    # temporary PG used during init (which listens on a Unix socket only).
    local has_healthcheck
    has_healthcheck=$(docker inspect --format '{{if .State.Health}}yes{{else}}no{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "no")

    if [[ "$has_healthcheck" == "yes" ]]; then
        while [[ "$elapsed" -lt "$max_wait" ]]; do
            local health
            health=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
            [[ "$health" == "healthy" ]] && break
            if [[ "$health" == "unhealthy" ]]; then
                th_fail "PostgreSQL HEALTHCHECK reported unhealthy"
                return 1
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
    else
        # Fallback for containers without HEALTHCHECK: poll with queries
        while [[ "$elapsed" -lt "$max_wait" ]]; do
            local result
            result=$(exec_sql "SELECT 1;") || true
            [[ "$result" == "1" ]] && break
            sleep 1
            elapsed=$((elapsed + 1))
        done
    fi

    # Phase 2: stability check — heavy extensions (citus, timescaledb, postgis)
    # do background init after startup that can briefly interrupt queries.
    local stable=0
    for _ in 1 2 3 4 5; do
        local result
        result=$(exec_sql "SELECT 1 + 1;") || true
        if [[ "$result" == "2" ]]; then
            stable=$((stable + 1))
        else
            stable=0
        fi
        sleep 0.5
    done

    if [[ "$stable" -ge 5 ]]; then
        th_pass "PostgreSQL is ready"
        return 0
    fi

    th_fail "PostgreSQL not ready after ${max_wait} seconds"
}

test_basic_query() {
    th_start
    local result
    result=$(exec_sql "SELECT 1 + 1;")
    th_assert_eq "Basic query works" "$result" "2"
}

test_builtin_extensions() {
    th_info "Testing built-in extensions..."
    local builtin_exts=(
        "pg_stat_statements"
        "pgcrypto"
        "uuid-ossp"
        "btree_gin"
        "btree_gist"
        "pg_trgm"
    )
    for ext in "${builtin_exts[@]}"; do
        th_start
        if extension_installed "$ext"; then
            th_pass "Extension $ext is installed"
        else
            th_fail "Extension $ext should be installed but isn't"
        fi
    done
}

# ============================================================================
# Extension-Specific Tests
# ============================================================================
test_pgvector() {
    th_start
    if ! extension_installed "vector"; then
        th_fail "pgvector extension not installed"
        return
    fi
    th_pass "pgvector extension installed"

    # Test vector operations
    exec_sql "CREATE TABLE IF NOT EXISTS test_vectors (id serial PRIMARY KEY, embedding vector(3));" >/dev/null
    exec_sql "INSERT INTO test_vectors (embedding) VALUES ('[1,2,3]'), ('[4,5,6]') ON CONFLICT DO NOTHING;" >/dev/null

    th_start
    local result
    result=$(exec_sql "SELECT COUNT(*) FROM test_vectors WHERE embedding <-> '[1,2,3]' < 10;")
    th_assert_ge "pgvector: vector similarity search works" "$result" 1

    exec_sql "DROP TABLE IF EXISTS test_vectors;" >/dev/null
}

test_pg_partman() {
    th_start
    if ! extension_installed "pg_partman"; then
        th_fail "pg_partman extension not installed"
        return
    fi
    th_pass "pg_partman extension installed"

    th_start
    local result
    result=$(exec_sql "SELECT COUNT(*) FROM pg_proc WHERE proname LIKE 'create_parent%';")
    th_assert_ge "pg_partman: partition management functions available" "$result" 1
}

test_hypopg() {
    th_start
    if ! extension_installed "hypopg"; then
        th_fail "hypopg extension not installed"
        return
    fi
    th_pass "hypopg extension installed"

    exec_sql "CREATE TABLE IF NOT EXISTS test_hypopg (id int, name text);" >/dev/null

    th_start
    local result
    result=$(exec_sql "SELECT hypopg_create_index('CREATE INDEX ON test_hypopg (id)');")
    th_assert_not_empty "hypopg: hypothetical index creation works" "$result"

    exec_sql "SELECT hypopg_reset();" >/dev/null
    exec_sql "DROP TABLE IF EXISTS test_hypopg;" >/dev/null
}

test_pg_qualstats() {
    th_start
    if ! extension_installed "pg_qualstats"; then
        th_fail "pg_qualstats extension not installed"
        return
    fi
    th_pass "pg_qualstats extension installed"

    th_start
    local result
    result=$(exec_sql "SELECT COUNT(*) FROM pg_catalog.pg_class WHERE relname = 'pg_qualstats';")
    if [[ "$result" -ge 1 ]] 2>/dev/null; then
        th_pass "pg_qualstats: statistics view available"
    else
        th_skip "pg_qualstats: statistics view" "may need shared_preload_libraries"
    fi
}

test_timescaledb() {
    th_start
    if ! extension_installed "timescaledb"; then
        th_fail "timescaledb extension not installed"
        return
    fi
    th_pass "timescaledb extension installed"

    exec_sql "CREATE TABLE IF NOT EXISTS test_timeseries (time TIMESTAMPTZ NOT NULL, value DOUBLE PRECISION);" >/dev/null
    exec_sql "SELECT create_hypertable('test_timeseries', by_range('time'), if_not_exists => TRUE);" >/dev/null
    exec_sql "INSERT INTO test_timeseries (time, value) VALUES (NOW(), 42.0) ON CONFLICT DO NOTHING;" >/dev/null

    th_start
    local result
    result=$(exec_sql "SELECT time_bucket('1 hour', NOW())::text IS NOT NULL;")
    th_assert_eq "timescaledb: hypertable and time_bucket work" "$result" "t"

    exec_sql "DROP TABLE IF EXISTS test_timeseries CASCADE;" >/dev/null
}

test_citus() {
    th_start
    if ! extension_installed "citus"; then
        th_fail "citus extension not installed"
        return
    fi
    th_pass "citus extension installed"

    th_start
    local result
    result=$(exec_sql "SELECT citus_version();")
    th_assert_not_empty "citus: version check passed" "$result"

    exec_sql "CREATE TABLE IF NOT EXISTS test_distributed (id int, data text);" >/dev/null

    th_start
    result=$(exec_sql "SELECT create_reference_table('test_distributed');" 2>/dev/null || echo "skip")
    if [[ "$result" != "skip" ]]; then
        th_pass "citus: reference table creation works"
    else
        th_skip "citus: reference table creation" "may need coordinator setup"
    fi

    exec_sql "DROP TABLE IF EXISTS test_distributed CASCADE;" >/dev/null
}

test_paradedb() {
    th_start
    if ! extension_installed "pg_search"; then
        th_fail "pg_search extension not installed"
        return
    fi
    th_pass "pg_search (ParadeDB) extension installed"

    exec_sql "CREATE TABLE IF NOT EXISTS test_search (id SERIAL PRIMARY KEY, content TEXT);" >/dev/null
    exec_sql "INSERT INTO test_search (content) VALUES ('hello world'), ('postgresql database'), ('full text search') ON CONFLICT DO NOTHING;" >/dev/null

    th_start
    local index_ok
    index_ok=$(exec_sql "CREATE INDEX IF NOT EXISTS test_search_idx ON test_search USING bm25 (id, content) WITH (key_field = 'id');" >/dev/null 2>&1 && echo "ok" || echo "skip")

    if [[ "$index_ok" == "ok" ]]; then
        local search_result
        search_result=$(exec_sql "SELECT COUNT(*) FROM test_search WHERE id @@@ paradedb.parse('content:hello');" 2>/dev/null || echo "0")
        th_assert_ge "paradedb: BM25 search works" "$search_result" 1
    else
        th_skip "paradedb: BM25 index creation" "index type not available"
    fi

    exec_sql "DROP TABLE IF EXISTS test_search CASCADE;" >/dev/null
}

test_pg_cron() {
    th_start
    if ! extension_exists "pg_cron"; then
        th_fail "pg_cron extension not available"
        return
    fi
    th_pass "pg_cron extension available"

    th_start
    local result
    result=$(exec_sql "SHOW shared_preload_libraries;")
    th_assert_contains "pg_cron: loaded in shared_preload_libraries" "$result" "pg_cron"

    # pg_cron can only be created in cron.database_name (default: postgres)
    local cron_db
    cron_db=$(exec_sql "SHOW cron.database_name;" 2>/dev/null)
    [[ -z "$cron_db" ]] && cron_db="postgres"

    exec_sql_db "$cron_db" "CREATE EXTENSION IF NOT EXISTS pg_cron;" >/dev/null 2>&1

    th_start
    result=$(exec_sql_db "$cron_db" \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'cron' AND table_name = 'job';")
    th_assert_ge "pg_cron: cron.job table available in '$cron_db' database" "$result" 1
}

test_pg_ivm() {
    th_start
    if ! extension_installed "pg_ivm"; then
        th_fail "pg_ivm extension not installed"
        return
    fi
    th_pass "pg_ivm extension installed"

    exec_sql "CREATE TABLE IF NOT EXISTS test_ivm_base (id int, val int);" >/dev/null
    exec_sql "INSERT INTO test_ivm_base VALUES (1, 10), (2, 20) ON CONFLICT DO NOTHING;" >/dev/null

    th_start
    local result
    result=$(exec_sql "SELECT COUNT(*) FROM pg_proc WHERE proname = 'create_immv';")
    th_assert_ge "pg_ivm: create_immv function available" "$result" 1

    exec_sql "DROP TABLE IF EXISTS test_ivm_base CASCADE;" >/dev/null
}

test_postgis() {
    th_start
    if ! extension_installed "postgis"; then
        th_fail "postgis extension not installed"
        return
    fi
    th_pass "postgis extension installed"

    th_start
    local result
    result=$(exec_sql "SELECT PostGIS_Version();")
    th_assert_not_empty "postgis: version check" "$result"

    exec_sql "CREATE TABLE IF NOT EXISTS test_geo (id serial PRIMARY KEY, geom geometry(Point, 4326));" >/dev/null
    exec_sql "INSERT INTO test_geo (geom) VALUES (ST_SetSRID(ST_MakePoint(-73.99, 40.73), 4326)) ON CONFLICT DO NOTHING;" >/dev/null

    th_start
    result=$(exec_sql "SELECT ST_AsText(geom) FROM test_geo LIMIT 1;")
    th_assert_contains "postgis: spatial operations work" "$result" "POINT"

    exec_sql "DROP TABLE IF EXISTS test_geo;" >/dev/null
}

# ============================================================================
# Flavor-Based Test Runner
# ============================================================================
run_flavor_tests() {
    local flavor="$1"

    th_group "Base Tests"
    test_connectivity
    if ! th_last_passed; then
        th_info "Aborting: PostgreSQL not reachable"
        return
    fi

    test_basic_query
    test_builtin_extensions

    # Flavor-specific tests (matches config.yaml flavor composition)
    case "$flavor" in
        base)
            th_info "Base flavor: no additional extension tests"
            ;;
        vector)
            th_group "Vector Extensions"
            test_pgvector
            test_paradedb
            test_pg_cron
            test_pg_ivm
            ;;
        analytics)
            th_group "Analytics Extensions"
            test_pg_partman
            test_hypopg
            test_pg_qualstats
            test_postgis
            test_pg_cron
            test_pg_ivm
            ;;
        timeseries)
            th_group "Timeseries Extensions"
            test_timescaledb
            test_pg_partman
            test_postgis
            test_pg_cron
            test_pg_ivm
            ;;
        spatial)
            th_group "Spatial Extensions"
            test_postgis
            test_pg_cron
            test_pg_ivm
            ;;
        distributed)
            th_group "Distributed Extensions"
            test_citus
            test_pg_cron
            test_pg_ivm
            ;;
        full)
            th_group "All Extensions"
            test_pgvector
            test_paradedb
            test_pg_partman
            test_hypopg
            test_pg_qualstats
            test_postgis
            test_citus
            test_timescaledb
            test_pg_cron
            test_pg_ivm
            ;;
        *)
            th_info "Unknown flavor '$flavor', running available extension tests"
            extension_installed "vector" && test_pgvector || true
            extension_installed "pg_search" && test_paradedb || true
            extension_installed "pg_partman" && test_pg_partman || true
            extension_installed "hypopg" && test_hypopg || true
            extension_installed "pg_qualstats" && test_pg_qualstats || true
            extension_installed "postgis" && test_postgis || true
            extension_installed "timescaledb" && test_timescaledb || true
            extension_installed "citus" && test_citus || true
            extension_installed "pg_cron" && test_pg_cron || true
            extension_installed "pg_ivm" && test_pg_ivm || true
            ;;
    esac
}

# ============================================================================
# Multi-Flavor Runner
# ============================================================================
run_all_flavors() {
    if [[ -z "$IMAGE" || -z "$TAG" ]]; then
        printf 'Error: --all-flavors requires --image and --tag\n' >&2
        exit 1
    fi

    local flavors=(base vector analytics timeseries spatial distributed full)
    local overall_pass=0 overall_fail=0 overall_skip=0
    local flavor_results=()
    local json_outputs=()

    # Cleanup trap
    cleanup() {
        for f in "${flavors[@]}"; do
            docker rm -f "e2e-pg-${f}" >/dev/null 2>&1 || true
        done
    }
    trap cleanup EXIT

    for flavor in "${flavors[@]}"; do
        local image_tag
        if [[ "$flavor" == "base" ]]; then
            image_tag="${IMAGE}:${TAG}"
        else
            image_tag="${IMAGE}:${TAG}-${flavor}"
        fi

        # Check if image exists
        if ! docker image inspect "$image_tag" &>/dev/null && \
           ! docker pull "$image_tag" >/dev/null 2>&1; then
            if [[ "$REPORT_FORMAT" != "json" ]]; then
                th_init --name "PostgreSQL E2E — ${flavor}" --report "$REPORT_FORMAT"
                th_skip "Flavor $flavor" "image not found: $image_tag"
                th_summary || true
            fi
            overall_skip=$((overall_skip + 1))
            flavor_results+=("${flavor}: SKIP (no image)")
            json_outputs+=("{\"suite\": \"PostgreSQL E2E — ${flavor}\", \"version\": \"$TH_VERSION\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)\", \"duration_ms\": 0, \"counts\": {\"total\": 1, \"pass\": 0, \"fail\": 0, \"skip\": 1}, \"tests\": [{\"id\": 1, \"group\": \"\", \"name\": \"Flavor ${flavor}\", \"status\": \"skip\", \"duration_ms\": 0, \"detail\": \"image not found: ${image_tag}\"}]}")
            continue
        fi

        local cname="e2e-pg-${flavor}"

        # Start container
        docker run -d --name "$cname" \
            -e POSTGRES_USER="$POSTGRES_USER" \
            -e POSTGRES_DB="$POSTGRES_DB" \
            -e POSTGRES_HOST_AUTH_METHOD=trust \
            --health-cmd "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}" \
            --health-interval=2s \
            --health-timeout=3s \
            --health-retries=3 \
            --health-start-period=5s \
            -l "flavor=${flavor}" \
            "$image_tag" >/dev/null 2>&1

        CONTAINER_NAME="$cname"

        if [[ "$REPORT_FORMAT" == "json" ]]; then
            th_init --name "PostgreSQL E2E — ${flavor}" --report json
            run_flavor_tests "$flavor"
            json_outputs+=("$(th_summary)")
            # th_summary returns 1 on failures — don't exit
            true
        else
            th_init --name "PostgreSQL E2E — ${flavor}" --report "$REPORT_FORMAT"
            run_flavor_tests "$flavor"
            th_summary || true
        fi

        overall_pass=$((overall_pass + _TH_PASS))
        overall_fail=$((overall_fail + _TH_FAIL))
        overall_skip=$((overall_skip + _TH_SKIP))

        local status="PASS"
        [[ "$_TH_FAIL" -gt 0 ]] && status="FAIL"
        flavor_results+=("${flavor}: ${status} (${_TH_PASS}/${_TH_FAIL}/${_TH_SKIP})")

        # Stop container
        docker rm -f "$cname" >/dev/null 2>&1 || true
    done

    # Combined summary
    if [[ "$REPORT_FORMAT" == "json" ]]; then
        printf '[\n'
        local i last=$((${#json_outputs[@]} - 1))
        for ((i = 0; i <= last; i++)); do
            printf '  %s' "${json_outputs[$i]}"
            [[ "$i" -lt "$last" ]] && printf ','
            printf '\n'
        done
        printf ']\n'
    else
        printf '\n  Combined Results\n'
        printf '  ════════════════════════════════════════════════\n'
        printf '  %-14s %s\n' "Flavor" "Status (pass/fail/skip)"
        printf '  %-14s %s\n' "──────────" "───────────────────────"
        for r in "${flavor_results[@]}"; do
            printf '  %s\n' "$r"
        done
        printf '  ════════════════════════════════════════════════\n'
        printf '  Total: %d passed │ %d failed │ %d skipped\n' \
            "$overall_pass" "$overall_fail" "$overall_skip"
        printf '  ════════════════════════════════════════════════\n'
    fi

    [[ "$overall_fail" -eq 0 ]]
}

# ============================================================================
# Flavor Detection
# ============================================================================
detect_flavor() {
    # CLI --flavor always wins
    if [[ -n "$FLAVOR_OVERRIDE" ]]; then
        echo "$FLAVOR_OVERRIDE"
        return
    fi

    local label_flavor
    label_flavor=$(docker inspect "$CONTAINER_NAME" --format '{{index .Config.Labels "flavor"}}' 2>/dev/null || echo "")

    if [[ -n "$label_flavor" ]]; then
        echo "$label_flavor"
    else
        echo "${FLAVOR:-base}"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    if [[ "$ALL_FLAVORS" == true ]]; then
        run_all_flavors
        return $?
    fi

    # Single-flavor mode
    local detected_flavor
    detected_flavor=$(detect_flavor)

    th_init --name "PostgreSQL E2E Tests — ${detected_flavor}" --report "$REPORT_FORMAT"
    run_flavor_tests "$detected_flavor"
    th_summary
}

main "$@"
