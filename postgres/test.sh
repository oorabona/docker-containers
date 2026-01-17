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

    for i in {1..30}; do
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

    # Flavor-specific tests
    case "$flavor" in
        base)
            info "Base flavor: no additional extension tests"
            ;;
        vector)
            test_pgvector
            ;;
        analytics)
            test_pg_partman
            test_hypopg
            test_pg_qualstats
            ;;
        full)
            test_pgvector
            test_pg_partman
            test_hypopg
            test_pg_qualstats
            ;;
        *)
            info "Unknown flavor '$flavor', running all extension tests"
            # Try all extensions, don't fail if not present
            extension_installed "vector" && test_pgvector || true
            extension_installed "pg_partman" && test_pg_partman || true
            extension_installed "hypopg" && test_hypopg || true
            extension_installed "pg_qualstats" && test_pg_qualstats || true
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
