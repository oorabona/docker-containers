#!/bin/bash
# Comprehensive Extension Testing Suite
# Tests extensions individually and in combination with compatibility validation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

log_failure() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((TESTS_SKIPPED++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Function to wait for PostgreSQL
wait_for_postgres() {
    local container_name="$1"
    local max_attempts=60
    local attempt=0
    
    log_info "Waiting for PostgreSQL to be ready in container: $container_name"
    
    while [ $attempt -lt $max_attempts ]; do
        if docker exec "$container_name" pg_isready -U postgres &> /dev/null; then
            log_success "PostgreSQL is ready in container: $container_name"
            return 0
        fi
        
        sleep 2
        ((attempt++))
        
        if [ $((attempt % 10)) -eq 0 ]; then
            log_info "Still waiting for PostgreSQL... ($attempt/$max_attempts)"
        fi
    done
    
    log_failure "PostgreSQL failed to start in container: $container_name"
    return 1
}

# Function to run SQL test with timing
run_sql_test() {
    local container_name="$1"
    local test_name="$2"
    local sql="$3"
    local expected_pattern="${4:-.*}"
    local timeout="${5:-30}"
    
    log_info "Testing: $test_name"
    
    local start_time=$(date +%s.%N)
    
    if result=$(timeout "$timeout" docker exec "$container_name" psql -U postgres -d postgres -t -c "$sql" 2>&1); then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
        
        if echo "$result" | grep -q "$expected_pattern"; then
            log_success "$test_name (${duration}s)"
            return 0
        else
            log_failure "$test_name - Unexpected result: $result"
            return 1
        fi
    else
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
        log_failure "$test_name - SQL execution failed after ${duration}s: $result"
        return 1
    fi
}

# Function to test extension availability and functionality
test_extension_comprehensive() {
    local container_name="$1"
    local extension_name="$2"
    
    log_info "=== Comprehensive Testing: $extension_name ==="
    
    # Test 1: Extension availability
    if ! run_sql_test "$container_name" "Extension $extension_name availability" \
        "SELECT count(*) FROM pg_available_extensions WHERE name = '$extension_name';" "1"; then
        return 1
    fi
    
    # Test 2: Extension creation
    if ! run_sql_test "$container_name" "Extension $extension_name creation" \
        "CREATE EXTENSION IF NOT EXISTS $extension_name;" ""; then
        return 1
    fi
    
    # Test 3: Extension installed check
    if ! run_sql_test "$container_name" "Extension $extension_name installed check" \
        "SELECT count(*) FROM pg_extension WHERE extname = '$extension_name';" "1"; then
        return 1
    fi
    
    # Extension-specific functionality tests
    case "$extension_name" in
        "vector"|"pg_vector")
            test_vector_functionality "$container_name"
            ;;
        "postgis")
            test_postgis_functionality "$container_name"
            ;;
        "pg_cron")
            test_pg_cron_functionality "$container_name"
            ;;
        "pg_net")
            test_pg_net_functionality "$container_name"
            ;;
        "pg_search")
            test_pg_search_functionality "$container_name"
            ;;
        "citus")
            test_citus_functionality "$container_name"
            ;;
        "pg_partman")
            test_pg_partman_functionality "$container_name"
            ;;
        "pgcrypto")
            test_pgcrypto_functionality "$container_name"
            ;;
        *)
            log_info "No specific functionality test for $extension_name"
            ;;
    esac
    
    return 0
}

# Vector extension functionality tests
test_vector_functionality() {
    local container_name="$1"
    
    # Create test table
    run_sql_test "$container_name" "Vector table creation" \
        "DROP TABLE IF EXISTS test_vectors; CREATE TABLE test_vectors (id SERIAL PRIMARY KEY, embedding vector(3));" ""
    
    # Insert test data
    run_sql_test "$container_name" "Vector data insertion" \
        "INSERT INTO test_vectors (embedding) VALUES ('[1,2,3]'), ('[4,5,6]'), ('[7,8,9]');" ""
    
    # Test similarity search
    run_sql_test "$container_name" "Vector similarity search" \
        "SELECT id FROM test_vectors ORDER BY embedding <-> '[1,2,3]' LIMIT 1;" "1"
    
    # Cleanup
    run_sql_test "$container_name" "Vector cleanup" \
        "DROP TABLE IF EXISTS test_vectors;" ""
}

# PostGIS functionality tests
test_postgis_functionality() {
    local container_name="$1"
    
    # Test basic PostGIS functions
    run_sql_test "$container_name" "PostGIS point creation" \
        "SELECT ST_AsText(ST_MakePoint(-74.006, 40.7128));" "POINT"
    
    # Create test spatial table
    run_sql_test "$container_name" "PostGIS spatial table creation" \
        "DROP TABLE IF EXISTS test_locations; CREATE TABLE test_locations (id SERIAL PRIMARY KEY, name TEXT, location GEOMETRY(POINT, 4326));" ""
    
    # Insert spatial data
    run_sql_test "$container_name" "PostGIS spatial data insertion" \
        "INSERT INTO test_locations (name, location) VALUES ('NYC', ST_SetSRID(ST_MakePoint(-74.006, 40.7128), 4326));" ""
    
    # Test spatial query
    run_sql_test "$container_name" "PostGIS spatial query" \
        "SELECT name FROM test_locations WHERE ST_DWithin(location::geography, ST_MakePoint(-74.006, 40.7128)::geography, 1000);" "NYC"
    
    # Cleanup
    run_sql_test "$container_name" "PostGIS cleanup" \
        "DROP TABLE IF EXISTS test_locations;" ""
}

# pg_cron functionality tests
test_pg_cron_functionality() {
    local container_name="$1"
    
    # Test cron job scheduling (in postgres database)
    run_sql_test "$container_name" "pg_cron job scheduling" \
        "SELECT cron.schedule('test-job', '*/5 * * * *', 'SELECT 1;');" ""
    
    # Check job exists
    run_sql_test "$container_name" "pg_cron job existence check" \
        "SELECT count(*) FROM cron.job WHERE jobname = 'test-job';" "1"
    
    # Remove test job
    run_sql_test "$container_name" "pg_cron job removal" \
        "SELECT cron.unschedule('test-job');" ""
}

# pg_net functionality tests
test_pg_net_functionality() {
    local container_name="$1"
    
    # Test HTTP request creation (this creates a queued request)
    run_sql_test "$container_name" "pg_net HTTP request creation" \
        "SELECT net.http_get('https://httpbin.org/get') as request_id;" ""
    
    # Check request queue (should have at least one request)
    run_sql_test "$container_name" "pg_net request queue check" \
        "SELECT count(*) > 0 FROM net.http_request_queue;" "t"
}

# pg_search functionality tests
test_pg_search_functionality() {
    local container_name="$1"
    
    # Create test table for search
    run_sql_test "$container_name" "pg_search test table creation" \
        "DROP TABLE IF EXISTS test_search; CREATE TABLE test_search (id SERIAL PRIMARY KEY, title TEXT, content TEXT);" ""
    
    # Insert test data
    run_sql_test "$container_name" "pg_search test data insertion" \
        "INSERT INTO test_search (title, content) VALUES 
         ('PostgreSQL Guide', 'Learn about PostgreSQL database management'),
         ('Search Tutorial', 'Full text search with ParadeDB');" ""
    
    # Test BM25 index creation
    run_sql_test "$container_name" "pg_search BM25 index creation" \
        "CREATE INDEX search_idx ON test_search USING bm25 (id, title, content) WITH (key_field='id');" ""
    
    # Test search functionality
    run_sql_test "$container_name" "pg_search BM25 search" \
        "SELECT title FROM test_search WHERE test_search @@@ 'PostgreSQL';" "PostgreSQL Guide"
    
    # Cleanup
    run_sql_test "$container_name" "pg_search cleanup" \
        "DROP TABLE IF EXISTS test_search;" ""
}

# Citus functionality tests
test_citus_functionality() {
    local container_name="$1"
    
    # Test Citus version
    run_sql_test "$container_name" "Citus version check" \
        "SELECT citus_version();" "[0-9]+\\.[0-9]+"
    
    # Test node information
    run_sql_test "$container_name" "Citus node information" \
        "SELECT count(*) FROM pg_dist_node;" "[0-9]+"
}

# pg_partman functionality tests
test_pg_partman_functionality() {
    local container_name="$1"
    
    # Create test partitioned table
    run_sql_test "$container_name" "pg_partman test table creation" \
        "DROP TABLE IF EXISTS test_partitioned CASCADE; 
         CREATE TABLE test_partitioned (id SERIAL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), data TEXT) 
         PARTITION BY RANGE (created_at);" ""
    
    # Setup partitioning
    run_sql_test "$container_name" "pg_partman partition setup" \
        "SELECT create_parent(
            p_parent_table => 'public.test_partitioned',
            p_control => 'created_at',
            p_type => 'range',
            p_interval => '1 month'
        );" ""
    
    # Insert test data
    run_sql_test "$container_name" "pg_partman test data insertion" \
        "INSERT INTO test_partitioned (data) VALUES ('test data');" ""
    
    # Cleanup
    run_sql_test "$container_name" "pg_partman cleanup" \
        "DELETE FROM public.part_config WHERE parent_table = 'public.test_partitioned';
         DROP TABLE IF EXISTS test_partitioned CASCADE;" ""
}

# Cryptographic functionality tests
test_pgcrypto_functionality() {
    local container_name="$1"
    
    # Test hash functions
    run_sql_test "$container_name" "pgcrypto hash generation" \
        "SELECT length(encode(digest('test', 'sha256'), 'hex'));" "64"
    
    # Test encryption/decryption
    run_sql_test "$container_name" "pgcrypto encryption/decryption" \
        "SELECT decrypt(encrypt('secret text', 'key', 'aes'), 'key', 'aes');" "secret text"
}

# Function to test extension profile combinations
test_profile_combination() {
    local profile_name="$1"
    local container_name="test-profile-$profile_name"
    
    log_info "=== Testing Profile Combination: $profile_name ==="
    
    # Start container with specific profile
    if ! docker run -d \
        --name "$container_name" \
        -e POSTGRES_PASSWORD="testpass" \
        -e POSTGRES_EXTENSION_PROFILE="$profile_name" \
        "$IMAGE_NAME" > /dev/null 2>&1; then
        log_failure "Failed to start container for profile: $profile_name"
        return 1
    fi
    
    # Wait for PostgreSQL to be ready
    if ! wait_for_postgres "$container_name"; then
        log_failure "PostgreSQL failed to start for profile: $profile_name"
        docker logs "$container_name" | tail -10
        docker stop "$container_name" > /dev/null 2>&1 || true
        docker rm "$container_name" > /dev/null 2>&1 || true
        return 1
    fi
    
    # Test extensions in this profile
    local extensions=$(docker exec "$container_name" cat /tmp/postgres_extensions.txt 2>/dev/null || echo "")
    
    if [[ -n "$extensions" ]]; then
        log_info "Profile $profile_name loaded extensions: $extensions"
        
        IFS=',' read -ra EXT_ARRAY <<< "$extensions"
        for ext in "${EXT_ARRAY[@]}"; do
            ext=$(echo "$ext" | xargs)  # trim whitespace
            if [[ -n "$ext" ]]; then
                test_extension_comprehensive "$container_name" "$ext"
            fi
        done
    else
        log_warning "No extensions found for profile: $profile_name"
    fi
    
    # Cleanup container
    docker stop "$container_name" > /dev/null 2>&1 || true
    docker rm "$container_name" > /dev/null 2>&1 || true
    
    log_success "Profile combination test completed: $profile_name"
    return 0
}

# Function to run compatibility validation
test_compatibility_validation() {
    log_info "=== Testing Compatibility Validation ==="
    
    # Test compatibility script
    if [[ -f "$POSTGRES_DIR/scripts/validate-compatibility.sh" ]]; then
        # Test matrix validation
        if "$POSTGRES_DIR/scripts/validate-compatibility.sh" matrix; then
            log_success "Compatibility matrix validation"
        else
            log_failure "Compatibility matrix validation"
        fi
        
        # Test profile listing
        if "$POSTGRES_DIR/scripts/validate-compatibility.sh" profiles > /dev/null; then
            log_success "Profile listing"
        else
            log_failure "Profile listing"
        fi
    else
        log_skip "Compatibility validation script not found"
    fi
}

# Function to run performance benchmarks
run_performance_benchmarks() {
    local container_name="$1"

    log_info "=== Performance Benchmarks ==="
    
    # Basic performance test
    run_sql_test "$container_name" "Simple query performance" \
        "SELECT count(*) FROM generate_series(1, 1000);" "1000" 5
    
    # Connection performance
    local start_time=$(date +%s.%N)
    for i in {1..5}; do
        docker exec "$container_name" psql -U postgres -d postgres -c "SELECT 1;" > /dev/null 2>&1
    done
    local end_time=$(date +%s.%N)
    local avg_time=$(echo "($end_time - $start_time) / 5" | bc -l)
    
    if (( $(echo "$avg_time < 1.0" | bc -l) )); then
        log_success "Connection performance: ${avg_time}s average"
    else
        log_warning "Connection performance: ${avg_time}s average (may be slow)"
    fi
}

# Main test execution
run_comprehensive_tests() {
    local image_name="${1:-postgres-modern-test}"
    export IMAGE_NAME="$image_name"
    
    log_info "Starting Comprehensive Extension Test Suite"
    log_info "Image: $image_name"
    log_info "Time: $(date)"
    
    # Build test image
    log_info "Building test image..."
    if ! docker build -t "$image_name" "$POSTGRES_DIR" > /dev/null 2>&1; then
        log_failure "Failed to build test image"
        return 1
    fi
    log_success "Test image built successfully"
    
    # Test compatibility validation
    test_compatibility_validation
    
    # Test individual profiles
    local profiles=("supabase" "paradedb" "analytics" "ai-ml")
    for profile in "${profiles[@]}"; do
        test_profile_combination "$profile"
    done
    
    # Test performance with supabase profile
    local perf_container="test-performance"
    if docker run -d --name "$perf_container" \
        -e POSTGRES_PASSWORD="testpass" \
        -e POSTGRES_EXTENSION_PROFILE="supabase" \
        "$image_name" > /dev/null 2>&1; then
        
        if wait_for_postgres "$perf_container"; then
            run_performance_benchmarks "$perf_container"
        fi
        
        docker stop "$perf_container" > /dev/null 2>&1 || true
        docker rm "$perf_container" > /dev/null 2>&1 || true
    fi
    
    # Final results
    log_info "=== Comprehensive Test Results ==="
    log_info "Tests passed: $TESTS_PASSED"
    log_info "Tests failed: $TESTS_FAILED"
    log_info "Tests skipped: $TESTS_SKIPPED"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        log_success "All tests passed! 🎉"
        return 0
    else
        log_failure "Some tests failed. Please review the output above."
        return 1
    fi
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test resources..."
    
    # Stop and remove all test containers
    docker ps -a --filter "name=test-" --format "{{.Names}}" | while read -r container; do
        if [[ -n "$container" ]]; then
            docker stop "$container" > /dev/null 2>&1 || true
            docker rm "$container" > /dev/null 2>&1 || true
        fi
    done
    
    # Remove test image
    if [[ -n "${IMAGE_NAME:-}" ]]; then
        docker rmi "$IMAGE_NAME" > /dev/null 2>&1 || true
    fi
    
    log_info "Cleanup completed"
}

# Trap cleanup on exit
trap cleanup EXIT

# Script execution
case "${1:-full}" in
    "full")
        run_comprehensive_tests "${2:-postgres-modern-test}"
        ;;
    "profile")
        if [[ -z "$2" ]]; then
            echo "Usage: $0 profile <profile-name> [image-name]"
            exit 1
        fi
        export IMAGE_NAME="${3:-postgres-modern-test}"
        docker build -t "$IMAGE_NAME" "$POSTGRES_DIR" > /dev/null
        test_profile_combination "$2"
        ;;
    "compatibility")
        test_compatibility_validation
        ;;
    *)
        echo "Usage: $0 [full|profile|compatibility] [options]"
        echo "  full         - Run complete test suite (default)"
        echo "  profile      - Test specific profile: $0 profile supabase"
        echo "  compatibility - Test compatibility validation only"
        exit 1
        ;;
esac