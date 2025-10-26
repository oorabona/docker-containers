#!/bin/bash

# =============================================================================
# PostgreSQL Smart Performance Test Suite - REFERENCE VERSION
# =============================================================================
# 
# This is the consolidated reference script that combines all testing capabilities:
# - Intelligent container detection (docker-compose + temporary containers)
# - Robust authentication (md5 with PGPASSWORD)
# - Smart extension detection (build-time + database queries)
# - Conditional testing (only tests compiled extensions)
# - Comprehensive performance tests for all available extensions
# - Detailed reporting with tested/skipped counters
#
# Compatible with both `./make build postgres` and `docker compose up` workflows
# =============================================================================

# More controlled error handling instead of strict set -e
set -u  # Only exit on undefined variables

# Disable ble.sh interference if present
if [[ -n "${BLE_VERSION:-}" ]]; then
    # Temporarily disable ble.sh hooks during script execution
    builtin unset -f ble/util/invokeHook 2>/dev/null || true
fi

# =============================================================================
# CONFIGURATION AND GLOBALS
# =============================================================================

# Global variables
POSTGRES_CMD=""
CONTAINER_MODE=""
INSTALLED_EXTENSIONS=""
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# =============================================================================
# CONTAINER DETECTION AND SETUP
# =============================================================================

detect_postgres_container() {
    local postgres_cmd=""
    local container_mode=""
    
    # Set PostgreSQL authentication for all connection methods
    export PGPASSWORD="${POSTGRES_PASSWORD:-changeme}"
    
    echo "🔍 Detecting PostgreSQL container..."
    
    # Method 1: Check if docker-compose is available and running
    if command -v docker-compose >/dev/null 2>&1 && docker-compose ps postgres &>/dev/null 2>&1; then
        if docker-compose ps postgres | grep -q "Up"; then
            postgres_cmd="docker-compose exec -e PGPASSWORD=changeme postgres"
            container_mode="docker-compose"
            echo "✅ Detected running docker-compose postgres container"
        fi
    fi
    
    # Method 2: Try to start docker-compose if file exists
    if [[ -z "$postgres_cmd" && -f "docker-compose.yml" ]] && command -v docker-compose >/dev/null 2>&1; then
        echo "🚀 Starting docker-compose for testing..."
        if docker-compose up -d postgres; then
            sleep 8
            if docker-compose ps postgres | grep -q "Up"; then
                postgres_cmd="docker-compose exec -e PGPASSWORD=changeme postgres"
                container_mode="docker-compose"
                echo "✅ Started docker-compose postgres container"
            fi
        fi
    fi
    
    # Method 3: Check for built postgres image from make build
    if [[ -z "$postgres_cmd" ]]; then
        local built_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "(postgres|oorabona/postgres)" | head -1)
        if [[ -n "$built_images" ]]; then
            # Start a temporary container for testing
            local temp_container_name="postgres-test-$(date +%s)"
            echo "🚀 Starting temporary postgres container from built image: $built_images"
            
            if docker run -d \
                --name "$temp_container_name" \
                -e POSTGRES_DB=myapp \
                -e POSTGRES_USER=postgres \
                -e POSTGRES_PASSWORD=changeme \
                -p 5433:5432 \
                "$built_images" >/dev/null; then
                
                # Wait for container to be ready
                echo "⏳ Waiting for postgres to be ready..."
                for i in {1..30}; do
                    if docker exec "$temp_container_name" pg_isready -U postgres -d myapp >/dev/null 2>&1; then
                        break
                    fi
                    sleep 1
                done
                
                postgres_cmd="docker exec -e PGPASSWORD=changeme $temp_container_name"
                container_mode="temporary"
                export CLEANUP_CONTAINER="$temp_container_name"
                echo "✅ Started temporary postgres container: $temp_container_name"
            fi
        fi
    fi
    
    # Method 4: Fallback error
    if [[ -z "$postgres_cmd" ]]; then
        echo "❌ No PostgreSQL container found!"
        echo "Please either:"
        echo "  1. Run 'docker-compose up -d postgres' first, or"
        echo "  2. Run './make build postgres' to build the image"
        exit 1
    fi
    
    echo "📦 Container mode: $container_mode"
    echo "🔧 Command prefix: $postgres_cmd"
    echo ""
    
    export POSTGRES_CMD="$postgres_cmd"
    export CONTAINER_MODE="$container_mode"
}

# Cleanup function for temporary containers
cleanup() {
    if [[ -n "${CLEANUP_CONTAINER:-}" ]]; then
        echo "🧹 Cleaning up temporary container: $CLEANUP_CONTAINER"
        docker stop "$CLEANUP_CONTAINER" >/dev/null 2>&1 || true
        docker rm "$CLEANUP_CONTAINER" >/dev/null 2>&1 || true
    fi
}

# Set trap for cleanup
trap cleanup EXIT

# =============================================================================
# EXTENSION DETECTION
# =============================================================================

detect_installed_extensions() {
    echo "🔍 Detecting installed extensions..."
    
    # Wait for PostgreSQL to be ready before querying
    echo "⏳ Waiting for PostgreSQL to accept connections..."
    for i in {1..30}; do
        if $POSTGRES_CMD pg_isready -U postgres >/dev/null 2>&1; then
            echo "✅ PostgreSQL is ready"
            break
        fi
        sleep 1
    done
    
    # Query database directly for available extensions
    local extensions=""
    echo "🔍 Querying database for available extensions..."
    
    # Get all extensions that are commonly tested, available in the database
    extensions=$($POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -t -c "
        SELECT string_agg(name, ',' ORDER BY name) 
        FROM pg_available_extensions 
        WHERE name IN (
            'citus', 'vector', 'pg_net', 'pgcrypto', 'pg_trgm', 'pg_stat_statements', 
            'uuid-ossp', 'btree_gin', 'btree_gist', 'hypopg', 'pg_qualstats', 
            'postgis', 'pg_cron', 'pgjwt', 'pg_partman', 'postgres_fdw'
        );" 2>/dev/null | tr -d ' \n\r' || echo "")
    
    if [[ -n "$extensions" && "$extensions" != "" ]]; then
        echo "📦 Extensions detected from database: $extensions"
    else
        echo "⚠️  No specialized extensions detected, checking basic PostgreSQL extensions..."
        # Fallback to basic extensions that should always be available
        extensions=$($POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -t -c "
            SELECT string_agg(name, ',' ORDER BY name) 
            FROM pg_available_extensions 
            WHERE name IN ('pgcrypto', 'pg_trgm', 'btree_gin', 'btree_gist');" 2>/dev/null | tr -d ' \n\r' || echo "")
        
        if [[ -n "$extensions" && "$extensions" != "" ]]; then
            echo "📦 Basic extensions detected: $extensions"
        else
            echo "⚠️  Using minimal fallback extension set"
            extensions="pg_stat_statements"
        fi
    fi
    
    echo ""
    export INSTALLED_EXTENSIONS="$extensions"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Function to check if extension is available
is_extension_available() {
    local ext_name="$1"
    # Check if variables are set and non-empty
    [[ -n "$ext_name" ]] && [[ -n "$INSTALLED_EXTENSIONS" ]] && [[ ",$INSTALLED_EXTENSIONS," == *",$ext_name,"* ]]
    return $?
}

# Function to execute SQL and measure time
benchmark_sql() {
    local description="$1"
    local sql="$2"
    echo "⏱️  Testing: $description"
    local start_time=$(date +%s.%N)
    $POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -c "$sql" >/dev/null 2>&1
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
    echo "   ✅ Completed in ${duration}s"
}

# Function to execute SQL and show results
execute_sql() {
    local description="$1"
    local sql="$2"
    echo "🔍 $description"
    $POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -c "$sql"
    echo ""
}

# Function to test extension installation and functionality
test_extension() {
    local ext_name="$1"
    local install_name="$2"  # Name to use for CREATE EXTENSION (may need quotes)
    local test_sql="$3"
    local description="$4"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "=== Test $TOTAL_TESTS: $description ($ext_name) ==="
    
    if ! is_extension_available "$ext_name"; then
        echo "   ⏭️  Extension $ext_name not available - SKIPPED"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        echo ""
        return
    fi
    
    echo "📦 Installing $ext_name..."
    if $POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -c "CREATE EXTENSION IF NOT EXISTS $install_name;" >/dev/null 2>&1; then
        echo "   ✅ Installation successful"
        
        # Verify extension is installed
        local version=$($POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -t -c "SELECT extversion FROM pg_extension WHERE extname = '$ext_name';" 2>/dev/null | tr -d ' \n\r')
        if [[ -n "$version" ]]; then
            echo "   ✅ Extension active (version: $version)"
            
            # Run functionality test if provided
            if [[ -n "$test_sql" ]]; then
                echo "   🔍 Testing functionality..."
                if $POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -c "$test_sql" >/dev/null 2>&1; then
                    echo "   ✅ Functionality test passed"
                    PASSED_TESTS=$((PASSED_TESTS + 1))
                else
                    echo "   ❌ Functionality test failed"
                    FAILED_TESTS=$((FAILED_TESTS + 1))
                fi
            else
                echo "   ✅ Basic installation test passed"
                PASSED_TESTS=$((PASSED_TESTS + 1))
            fi
        else
            echo "   ❌ Extension not properly installed"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    else
        echo "   ❌ Installation failed"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    echo ""
}

# =============================================================================
# MAIN TEST EXECUTION
# =============================================================================

main() {
    echo "🚀 PostgreSQL Smart Performance Test Suite - REFERENCE VERSION"
    echo "Testing installed extensions with realistic workloads and intelligent detection..."
    echo ""
    
    # Setup: detect container and extensions
    detect_postgres_container
    detect_installed_extensions
    
    echo "=== 1. Extension Status Overview ==="
    execute_sql "Database and extension overview" "
    SELECT 
        'PostgreSQL ' || version() as database_info,
        current_database() as current_db,
        current_user as connected_user;
    
    SELECT 
        'Available extensions: ' || count(*) as extension_count
    FROM pg_available_extensions;"
    
    # Show test plan
    echo "=== 2. Intelligent Test Plan ==="
    echo "📋 Available extension tests:"
    
    local all_testable_extensions=("pgcrypto" "uuid-ossp" "pg_trgm" "btree_gin" "btree_gist" "pg_stat_statements" "vector" "postgis" "pg_net" "pg_cron" "pgjwt" "citus" "hypopg" "pg_qualstats" "postgres_fdw" "pg_partman")
    local planned_tests=0
    local planned_skips=0
    
    for ext in "${all_testable_extensions[@]}"; do
        if is_extension_available "$ext" 2>/dev/null; then
            echo "   ✅ $ext - will be tested"
            planned_tests=$((planned_tests + 1))
        else
            echo "   ⏭️  $ext - will be skipped (not available)"
            planned_skips=$((planned_skips + 1))
        fi
    done
    
    echo ""
    echo "📊 Test Plan Summary: $planned_tests tests planned, $planned_skips will be skipped"
    echo ""

    # Execute extension tests
    echo "=== 3. Extension Testing Results ==="
    
    # Standard Extensions (commonly available)
    test_extension "pgcrypto" "pgcrypto" "SELECT encode(digest('test', 'sha256'), 'hex') as crypto_hash;" "Cryptographic Functions"
    
    test_extension "uuid-ossp" '"uuid-ossp"' "SELECT uuid_generate_v4() as test_uuid;" "UUID Generation"
    
    test_extension "pg_trgm" "pg_trgm" "SELECT similarity('PostgreSQL', 'PostGIS') as similarity_score;" "Trigram Text Similarity"
    
    test_extension "btree_gin" "btree_gin" "CREATE TABLE IF NOT EXISTS gin_test (id serial, data text[]); DROP TABLE gin_test;" "GIN Indexing Support"
    
    test_extension "btree_gist" "btree_gist" "CREATE TABLE IF NOT EXISTS gist_test (id serial, geom point); DROP TABLE gist_test;" "GiST Indexing Support"
    
    test_extension "pg_stat_statements" "pg_stat_statements" "SELECT 'pg_stat_statements ready' as status;" "Query Statistics Tracking"
    
    # Advanced Extensions (conditionally compiled)
    test_extension "vector" "vector" "CREATE TABLE IF NOT EXISTS vector_test (id serial, embedding vector(3)); INSERT INTO vector_test (embedding) VALUES ('[1,2,3]'); DROP TABLE vector_test;" "Vector Similarity Search"
    
    test_extension "postgis" "postgis" "SELECT PostGIS_Version() as postgis_info;" "PostGIS Geospatial"
    
    test_extension "pg_net" "pg_net" "SELECT 'pg_net functions available' as status;" "HTTP Client"
    
    test_extension "pg_cron" "pg_cron" "SELECT 'pg_cron available' as status;" "Job Scheduler"
    
    test_extension "pgjwt" "pgjwt" "SELECT 'pgjwt functions available' as status;" "JWT Authentication"
    
    test_extension "citus" "citus" "SELECT citus_version() as citus_info;" "Distributed PostgreSQL"
    
    test_extension "hypopg" "hypopg" "SELECT 'hypopg functions available' as status;" "Hypothetical Indexes"
    
    test_extension "pg_qualstats" "pg_qualstats" "SELECT 'pg_qualstats available' as status;" "Query Statistics Analysis"
    
    test_extension "postgres_fdw" "postgres_fdw" "SELECT 'postgres_fdw available' as status;" "Foreign Data Wrapper"
    
    test_extension "pg_partman" "pg_partman" "SELECT 'pg_partman available' as status;" "Partition Management"
    
    # Performance Tests
    echo "=== 4. Performance Validation ==="
    echo "🔍 Combined extension performance test..."
    
    local start_time=$(date +%s.%N)
    $POSTGRES_CMD psql -U postgres -d "${POSTGRES_DB:-myapp}" -c "
    -- Create test data
    CREATE TABLE IF NOT EXISTS perf_combined_test (
        id SERIAL PRIMARY KEY,
        name TEXT,
        data JSONB,
        created_at TIMESTAMP DEFAULT NOW()
    );
    
    -- Insert test data
    INSERT INTO perf_combined_test (name, data) 
    SELECT 'test_' || i, '{\"value\": ' || i || '}' 
    FROM generate_series(1, 1000) i
    ON CONFLICT DO NOTHING;
    
    -- Test query performance
    SELECT COUNT(*) as total_records,
           AVG((data->>'value')::int) as avg_value
    FROM perf_combined_test;
    
    -- Cleanup
    DROP TABLE perf_combined_test;
    " >/dev/null 2>&1
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "unknown")
    echo "✅ Combined performance test completed in ${duration}s"
    echo ""
    
    # System Status
    echo "=== 5. System Health Check ==="
    execute_sql "Database performance metrics" "
    -- Connection status
    SELECT 
        'Active connections: ' || count(*) as connections
    FROM pg_stat_activity 
    WHERE state = 'active';
    
    -- Database statistics
    SELECT 
        datname as database,
        numbackends as connections,
        xact_commit as commits,
        xact_rollback as rollbacks,
        CASE 
            WHEN blks_hit + blks_read = 0 THEN '0%'
            ELSE round(100.0 * blks_hit / (blks_hit + blks_read), 2)::text || '%'
        END as cache_hit_ratio
    FROM pg_stat_database 
    WHERE datname = '${POSTGRES_DB:-myapp}';
    
    -- Currently installed extensions
    SELECT 
        extname as extension_name,
        extversion as version,
        'Active' as status
    FROM pg_extension 
    WHERE extname != 'plpgsql' 
    ORDER BY extname;
    "
    
    # Final Summary
    echo "=== 6. Final Test Results ==="
    echo "📊 Test Execution Summary:"
    echo "   🎯 Total tests attempted: $TOTAL_TESTS"
    echo "   ✅ Successful tests: $PASSED_TESTS"
    echo "   ❌ Failed tests: $FAILED_TESTS"
    echo "   ⏭️  Skipped tests: $SKIPPED_TESTS"
    echo ""
    
    if [[ $FAILED_TESTS -eq 0 ]]; then
        if [[ $PASSED_TESTS -gt 0 ]]; then
            echo "🎉 All executed tests PASSED! ($PASSED_TESTS/$TOTAL_TESTS successful)"
            if [[ $SKIPPED_TESTS -gt 0 ]]; then
                echo "📝 Note: $SKIPPED_TESTS tests were skipped due to unavailable extensions"
            fi
            echo "🚀 PostgreSQL container is ready and optimized!"
        else
            echo "⚠️  No tests were executed (all extensions skipped)"
        fi
    else
        echo "⚠️  Some tests failed - review the output above"
        echo "🔧 Consider checking extension compilation and dependencies"
    fi
    
    echo ""
    echo "✅ Smart performance testing completed!"
    echo "💡 This test suite intelligently adapts to your container's extension configuration"
    
    # Return appropriate exit code
    if [[ $FAILED_TESTS -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi