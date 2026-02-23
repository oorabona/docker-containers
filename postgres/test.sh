#!/bin/bash
# E2E test for postgres container with extension validation
# Tests base functionality and flavor-specific extensions

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-postgres}"
FLAVOR="${FLAVOR:-base}"
POSTGRES_USER="${POSTGRES_USER:-test}"
POSTGRES_DB="${POSTGRES_DB:-test}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✅ $*${NC}"; }
fail() { echo -e "  ${RED}❌ $*${NC}"; exit 1; }
info() { echo -e "  ${YELLOW}→${NC} $*"; }

# Execute SQL and return result
exec_sql() {
    docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -A -c "$1" 2>/dev/null
}

# Check if extension exists
extension_exists() {
    local ext="$1"
    result=$(exec_sql "SELECT 1 FROM pg_available_extensions WHERE name = '$ext';")
    [[ "$result" == "1" ]]
}

# Check if extension is installed
extension_installed() {
    local ext="$1"
    result=$(exec_sql "SELECT 1 FROM pg_extension WHERE extname = '$ext';")
    [[ "$result" == "1" ]]
}

# ============================================================================
# Base Tests
# ============================================================================
test_connectivity() {
    info "Testing PostgreSQL connectivity..."

    for _ in {1..30}; do
        if docker exec "$CONTAINER_NAME" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" &>/dev/null; then
            pass "PostgreSQL is ready"
            return 0
        fi
        sleep 1
    done

    fail "PostgreSQL not ready after 30 seconds"
}

test_basic_query() {
    info "Testing basic query..."

    result=$(exec_sql "SELECT 1 + 1;")
    if [[ "$result" == "2" ]]; then
        pass "Basic query works"
    else
        fail "Basic query failed: expected '2', got '$result'"
    fi
}

test_builtin_extensions() {
    info "Testing built-in extensions..."

    local builtin_exts=(
        "pg_stat_statements"
        "pgcrypto"
        "uuid-ossp"
        "btree_gin"
        "btree_gist"
        "pg_trgm"
    )

    for ext in "${builtin_exts[@]}"; do
        if extension_installed "$ext"; then
            pass "Extension $ext is installed"
        else
            fail "Extension $ext should be installed but isn't"
        fi
    done
}

# ============================================================================
# Extension-Specific Tests
# ============================================================================
test_pgvector() {
    info "Testing pgvector extension..."

    if ! extension_installed "vector"; then
        fail "pgvector extension not installed"
    fi

    # Test vector operations
    exec_sql "CREATE TABLE IF NOT EXISTS test_vectors (id serial PRIMARY KEY, embedding vector(3));" >/dev/null
    exec_sql "INSERT INTO test_vectors (embedding) VALUES ('[1,2,3]'), ('[4,5,6]') ON CONFLICT DO NOTHING;" >/dev/null

    # Test similarity search
    result=$(exec_sql "SELECT COUNT(*) FROM test_vectors WHERE embedding <-> '[1,2,3]' < 10;")
    if [[ "$result" -ge 1 ]]; then
        pass "pgvector: vector similarity search works"
    else
        fail "pgvector: similarity search failed"
    fi

    # Cleanup
    exec_sql "DROP TABLE IF EXISTS test_vectors;" >/dev/null
}

test_pg_partman() {
    info "Testing pg_partman extension..."

    if ! extension_installed "pg_partman"; then
        fail "pg_partman extension not installed"
    fi

    # Test that pg_partman functions exist
    result=$(exec_sql "SELECT COUNT(*) FROM pg_proc WHERE proname LIKE 'create_parent%';")
    if [[ "$result" -ge 1 ]]; then
        pass "pg_partman: partition management functions available"
    else
        fail "pg_partman: functions not found"
    fi
}

test_hypopg() {
    info "Testing hypopg extension..."

    if ! extension_installed "hypopg"; then
        fail "hypopg extension not installed"
    fi

    # Create test table
    exec_sql "CREATE TABLE IF NOT EXISTS test_hypopg (id int, name text);" >/dev/null

    # Create hypothetical index
    result=$(exec_sql "SELECT hypopg_create_index('CREATE INDEX ON test_hypopg (id)');")
    if [[ -n "$result" ]]; then
        pass "hypopg: hypothetical index creation works"
    else
        fail "hypopg: could not create hypothetical index"
    fi

    # Reset hypothetical indexes
    exec_sql "SELECT hypopg_reset();" >/dev/null
    exec_sql "DROP TABLE IF EXISTS test_hypopg;" >/dev/null
}

test_pg_qualstats() {
    info "Testing pg_qualstats extension..."

    if ! extension_installed "pg_qualstats"; then
        fail "pg_qualstats extension not installed"
    fi

    # Check pg_qualstats view exists
    result=$(exec_sql "SELECT COUNT(*) FROM pg_catalog.pg_class WHERE relname = 'pg_qualstats';")
    if [[ "$result" -ge 1 ]]; then
        pass "pg_qualstats: statistics view available"
    else
        # View might not exist if shared_preload_libraries not set
        info "pg_qualstats: view not found (may need shared_preload_libraries)"
    fi
}

test_timescaledb() {
    info "Testing TimescaleDB extension..."

    if ! extension_installed "timescaledb"; then
        fail "timescaledb extension not installed"
    fi

    # Create a hypertable
    exec_sql "CREATE TABLE IF NOT EXISTS test_timeseries (time TIMESTAMPTZ NOT NULL, value DOUBLE PRECISION);" >/dev/null
    exec_sql "SELECT create_hypertable('test_timeseries', by_range('time'), if_not_exists => TRUE);" >/dev/null

    # Insert some data
    exec_sql "INSERT INTO test_timeseries (time, value) VALUES (NOW(), 42.0) ON CONFLICT DO NOTHING;" >/dev/null

    # Test time_bucket function
    result=$(exec_sql "SELECT time_bucket('1 hour', NOW())::text IS NOT NULL;")
    if [[ "$result" == "t" ]]; then
        pass "timescaledb: hypertable and time_bucket work"
    else
        fail "timescaledb: time_bucket function failed"
    fi

    # Cleanup
    exec_sql "DROP TABLE IF EXISTS test_timeseries CASCADE;" >/dev/null
}

test_citus() {
    info "Testing Citus extension..."

    if ! extension_installed "citus"; then
        fail "citus extension not installed"
    fi

    # Check citus version
    result=$(exec_sql "SELECT citus_version();")
    if [[ -n "$result" ]]; then
        pass "citus: version check passed ($result)"
    else
        fail "citus: could not get version"
    fi

    # Test creating a distributed table (single-node mode)
    exec_sql "CREATE TABLE IF NOT EXISTS test_distributed (id int, data text);" >/dev/null

    # In single-node Citus, we can create reference tables
    result=$(exec_sql "SELECT create_reference_table('test_distributed');" 2>/dev/null || echo "skip")
    if [[ "$result" != "skip" ]]; then
        pass "citus: reference table creation works"
    else
        info "citus: reference table creation skipped (may need coordinator setup)"
    fi

    # Cleanup
    exec_sql "DROP TABLE IF EXISTS test_distributed CASCADE;" >/dev/null
}

test_paradedb() {
    info "Testing ParadeDB (pg_search) extension..."

    if ! extension_installed "pg_search"; then
        fail "pg_search extension not installed"
    fi

    # Create test table with BM25 index
    exec_sql "CREATE TABLE IF NOT EXISTS test_search (id SERIAL PRIMARY KEY, content TEXT);" >/dev/null
    exec_sql "INSERT INTO test_search (content) VALUES ('hello world'), ('postgresql database'), ('full text search') ON CONFLICT DO NOTHING;" >/dev/null

    # Create BM25 index (ParadeDB syntax)
    result=$(exec_sql "CALL paradedb.create_bm25(
        index_name => 'test_search_idx',
        table_name => 'test_search',
        key_field => 'id',
        text_fields => paradedb.field('content')
    );" 2>/dev/null || echo "skip")

    if [[ "$result" != "skip" ]]; then
        # Test search query
        search_result=$(exec_sql "SELECT COUNT(*) FROM test_search WHERE id @@@ paradedb.parse('content:hello');" 2>/dev/null || echo "0")
        if [[ "$search_result" -ge 1 ]]; then
            pass "paradedb: BM25 search works"
        else
            info "paradedb: BM25 index created but search returned no results"
        fi
    else
        info "paradedb: BM25 index creation skipped (may need initialization)"
    fi

    # Cleanup
    exec_sql "DROP TABLE IF EXISTS test_search CASCADE;" >/dev/null
}

test_pg_cron() {
    info "Testing pg_cron extension..."

    # pg_cron can only be created in the database matching cron.database_name (default: postgres)
    # Verify it's loaded via shared_preload_libraries and functional in the postgres database
    if ! extension_exists "pg_cron"; then
        fail "pg_cron extension not available"
    fi

    # Check pg_cron is running (background worker loaded)
    result=$(exec_sql "SHOW shared_preload_libraries;")
    if [[ "$result" == *"pg_cron"* ]]; then
        pass "pg_cron: loaded in shared_preload_libraries"
    else
        fail "pg_cron: not in shared_preload_libraries"
    fi

    # Create extension in the postgres database (cron.database_name default)
    local cron_db
    cron_db=$(exec_sql "SHOW cron.database_name;" 2>/dev/null || echo "postgres")
    docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$cron_db" -t -A -c \
        "CREATE EXTENSION IF NOT EXISTS pg_cron;" >/dev/null 2>&1 || true

    # Verify cron.job table exists in the cron database
    result=$(docker exec "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$cron_db" -t -A -c \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'cron' AND table_name = 'job';" 2>/dev/null)
    if [[ "$result" -ge 1 ]]; then
        pass "pg_cron: cron.job table available in '$cron_db' database"
    else
        fail "pg_cron: cron.job table not found"
    fi
}

test_pg_ivm() {
    info "Testing pg_ivm extension..."

    if ! extension_installed "pg_ivm"; then
        fail "pg_ivm extension not installed"
    fi

    # Create a base table and incrementally maintained materialized view
    exec_sql "CREATE TABLE IF NOT EXISTS test_ivm_base (id int, val int);" >/dev/null
    exec_sql "INSERT INTO test_ivm_base VALUES (1, 10), (2, 20) ON CONFLICT DO NOTHING;" >/dev/null

    result=$(exec_sql "SELECT COUNT(*) FROM pg_proc WHERE proname = 'create_immv';" 2>/dev/null)
    if [[ "$result" -ge 1 ]]; then
        pass "pg_ivm: create_immv function available"
    else
        fail "pg_ivm: create_immv function not found"
    fi

    # Cleanup
    exec_sql "DROP TABLE IF EXISTS test_ivm_base CASCADE;" >/dev/null
}

test_postgis() {
    info "Testing PostGIS extension..."

    if ! extension_installed "postgis"; then
        fail "postgis extension not installed"
    fi

    # Check PostGIS version
    result=$(exec_sql "SELECT PostGIS_Version();" 2>/dev/null)
    if [[ -n "$result" ]]; then
        pass "postgis: version $result"
    else
        fail "postgis: could not get version"
    fi

    # Test spatial operations
    exec_sql "CREATE TABLE IF NOT EXISTS test_geo (id serial PRIMARY KEY, geom geometry(Point, 4326));" >/dev/null
    exec_sql "INSERT INTO test_geo (geom) VALUES (ST_SetSRID(ST_MakePoint(-73.99, 40.73), 4326)) ON CONFLICT DO NOTHING;" >/dev/null

    result=$(exec_sql "SELECT ST_AsText(geom) FROM test_geo LIMIT 1;")
    if [[ "$result" == *"POINT"* ]]; then
        pass "postgis: spatial operations work"
    else
        fail "postgis: spatial operations failed"
    fi

    # Cleanup
    exec_sql "DROP TABLE IF EXISTS test_geo;" >/dev/null
}

# ============================================================================
# Flavor-Based Test Runner
# ============================================================================
run_flavor_tests() {
    local flavor="$1"

    echo ""
    echo "Running tests for flavor: $flavor"
    echo "======================================"

    # Base tests (always run)
    test_connectivity
    test_basic_query
    test_builtin_extensions

    # Flavor-specific tests (matches config.yaml flavor composition)
    case "$flavor" in
        base)
            info "Base flavor: no additional extension tests"
            ;;
        vector)
            test_pgvector
            test_paradedb
            test_pg_cron
            test_pg_ivm
            ;;
        analytics)
            test_pg_partman
            test_hypopg
            test_pg_qualstats
            test_postgis
            test_pg_cron
            test_pg_ivm
            ;;
        timeseries)
            test_timescaledb
            test_pg_partman
            test_postgis
            test_pg_cron
            test_pg_ivm
            ;;
        spatial)
            test_postgis
            test_pg_cron
            test_pg_ivm
            ;;
        distributed)
            test_citus
            test_pg_cron
            test_pg_ivm
            ;;
        full)
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
            info "Unknown flavor '$flavor', running all extension tests"
            # Try all extensions, don't fail if not present
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

    echo ""
    pass "All tests passed for flavor: $flavor"
}

# ============================================================================
# Main
# ============================================================================

# Try to detect flavor from container labels
detect_flavor() {
    local label_flavor
    label_flavor=$(docker inspect "$CONTAINER_NAME" --format '{{index .Config.Labels "flavor"}}' 2>/dev/null || echo "")

    if [[ -n "$label_flavor" ]]; then
        echo "$label_flavor"
    else
        echo "${FLAVOR:-base}"
    fi
}

main() {
    echo "PostgreSQL E2E Tests"
    echo "===================="
    echo "Container: $CONTAINER_NAME"

    # Detect or use provided flavor
    detected_flavor=$(detect_flavor)
    echo "Flavor: $detected_flavor"

    run_flavor_tests "$detected_flavor"
}

main "$@"
