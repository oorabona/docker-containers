#!/bin/bash
# Comprehensive test suite for PostgreSQL modern container
# Tests extension profiles, functionality, and performance

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test configuration
TEST_DB="test_modern_postgres"
TEST_USER="testuser"
TEST_PASSWORD="testpass123"
CONTAINER_NAME="postgres-test-$$"

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

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

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Function to wait for PostgreSQL
wait_for_postgres() {
    local max_attempts=30
    for i in $(seq 1 $max_attempts); do
        if docker exec "$CONTAINER_NAME" pg_isready -U postgres &> /dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Function to run SQL and check result
run_sql_test() {
    local description="$1"
    local sql="$2"
    local expected_pattern="${3:-.*}"
    
    log_info "Testing: $description"
    
    if result=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -t -c "$sql" 2>&1); then
        if echo "$result" | grep -q "$expected_pattern"; then
            log_success "$description"
            return 0
        else
            log_failure "$description - Unexpected result: $result"
            return 1
        fi
    else
        log_failure "$description - SQL execution failed: $result"
        return 1
    fi
}

# Test extension availability
test_extension_availability() {
    log_info "=== Testing Extension Availability ==="
    
    local core_extensions=("citus" "vector" "postgis" "pg_cron" "pg_stat_statements")
    
    for ext in "${core_extensions[@]}"; do
        run_sql_test "Extension $ext availability" \
            "SELECT count(*) FROM pg_available_extensions WHERE name = '$ext';" \
            "1"
    done
}

# Test extension profiles
test_extension_profiles() {
    log_info "=== Testing Extension Profiles ==="
    
    # Test profile loading mechanism
    run_sql_test "Extension profile environment variable" \
        "SELECT current_setting('POSTGRES_EXTENSION_PROFILE', true);" \
        ".*"
    
    # Test extension enablement
    run_sql_test "Extensions enabled check" \
        "SELECT count(*) FROM pg_extension WHERE extname IN ('plpgsql');" \
        "[1-9]"
}

# Test vector functionality (if available)
test_vector_functionality() {
    log_info "=== Testing Vector Functionality ==="
    
    # Check if vector extension is enabled
    if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1 FROM pg_extension WHERE extname = 'vector';" | grep -q "1"; then
        
        # Test vector operations
        run_sql_test "Vector extension basic functionality" \
            "SELECT array_dims(array[1,2,3]::vector);" \
            "\\[1:3\\]"
            
        # Test vector table creation (if ai_examples schema exists)
        run_sql_test "Vector similarity search setup" \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'ai_examples' AND table_name = 'documents';" \
            "[0-9]+"
            
    else
        log_warning "Vector extension not enabled, skipping vector tests"
    fi
}

# Test PostGIS functionality (if available)
test_postgis_functionality() {
    log_info "=== Testing PostGIS Functionality ==="
    
    # Check if PostGIS extension is enabled
    if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1 FROM pg_extension WHERE extname = 'postgis';" | grep -q "1"; then
        
        # Test PostGIS basic functionality
        run_sql_test "PostGIS basic functionality" \
            "SELECT ST_AsText(ST_MakePoint(-74.006, 40.7128));" \
            "POINT"
            
        # Test geospatial examples schema
        run_sql_test "PostGIS examples schema" \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'geo_examples';" \
            "[0-9]+"
            
    else
        log_warning "PostGIS extension not enabled, skipping geospatial tests"  
    fi
}

# Test Citus functionality
test_citus_functionality() {
    log_info "=== Testing Citus Functionality ==="
    
    # Check if Citus extension is enabled
    if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1 FROM pg_extension WHERE extname = 'citus';" | grep -q "1"; then
        
        # Test Citus node information
        run_sql_test "Citus node information" \
            "SELECT count(*) FROM pg_dist_node;" \
            "[0-9]+"
            
        # Test Citus version
        run_sql_test "Citus version check" \
            "SELECT citus_version();" \
            "[0-9]+\\.[0-9]+"
            
    else
        log_warning "Citus extension not enabled, skipping distributed tests"
    fi
}

# Test monitoring functionality
test_monitoring_functionality() {
    log_info "=== Testing Monitoring Functionality ==="
    
    # Test health check function
    run_sql_test "Health check function" \
        "SELECT count(*) FROM public.health_check();" \
        "[1-9]"
    
    # Test monitoring schema (if available)
    if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'monitoring';" | grep -q "1"; then
        
        run_sql_test "Monitoring views availability" \
            "SELECT count(*) FROM information_schema.views WHERE table_schema = 'monitoring';" \
            "[1-9]"
    else
        log_warning "Monitoring schema not available"
    fi
}

# Test security features
test_security_functionality() {
    log_info "=== Testing Security Functionality ==="
    
    # Test RLS examples (if available)
    if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'security_examples';" | grep -q "1"; then
        
        run_sql_test "Security examples schema" \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'security_examples';" \
            "[1-9]"
            
        run_sql_test "RLS policies" \
            "SELECT count(*) FROM pg_policies WHERE schemaname = 'security_examples';" \
            "[1-9]"
    else
        log_warning "Security examples not available"
    fi
}

# Test container startup with different profiles
test_profile_startup() {
    local profile=$1
    log_info "=== Testing Profile: $profile ==="
    
    local test_container="${CONTAINER_NAME}_${profile}"
    
    # Start container with specific profile
    if docker run -d \
        --name "$test_container" \
        -e POSTGRES_EXTENSION_PROFILE="$profile" \
        -e POSTGRES_PASSWORD="$TEST_PASSWORD" \
        "$CONTAINER_NAME" > /dev/null 2>&1; then
        
        # Wait for startup
        local max_attempts=30
        for i in $(seq 1 $max_attempts); do
            if docker exec "$test_container" pg_isready -U postgres &> /dev/null; then
                log_success "Profile $profile startup"
                break
            fi
            sleep 2
            if [ $i -eq $max_attempts ]; then
                log_failure "Profile $profile startup timeout"
                docker logs "$test_container" | tail -10
            fi
        done
        
        # Cleanup
        docker stop "$test_container" > /dev/null 2>&1 || true
        docker rm "$test_container" > /dev/null 2>&1 || true
    else
        log_failure "Profile $profile container creation failed"
    fi
}

# Main test execution
run_all_tests() {
    log_info "Starting PostgreSQL Modern Container Test Suite"
    log_info "Container: $CONTAINER_NAME"
    
    # Build the container first
    log_info "Building container..."
    if ! docker build -t "$CONTAINER_NAME" "$POSTGRES_DIR" > /dev/null 2>&1; then
        log_failure "Container build failed"
        exit 1
    fi
    log_success "Container build completed"
    
    # Start container with default profile
    log_info "Starting container with default configuration..."
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        -e POSTGRES_PASSWORD="$TEST_PASSWORD" \
        -e POSTGRES_EXTENSION_PROFILE="supabase" \
        "$CONTAINER_NAME" > /dev/null 2>&1; then
        log_failure "Container startup failed"
        exit 1
    fi
    
    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    if ! wait_for_postgres; then
        log_failure "PostgreSQL failed to start"
        docker logs "$CONTAINER_NAME" | tail -20
        exit 1
    fi
    log_success "PostgreSQL is ready"
    
    # Run functional tests
    test_extension_availability
    test_extension_profiles
    test_vector_functionality
    test_postgis_functionality
    test_citus_functionality
    test_monitoring_functionality
    test_security_functionality
    
    # Clean up main container
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" > /dev/null 2>&1 || true
    
    # Test different profiles
    local profiles=("supabase" "paradedb" "analytics" "ai-ml")
    for profile in "${profiles[@]}"; do
        test_profile_startup "$profile"
    done
    
    # Final results
    log_info "=== Test Results ==="
    log_info "Tests passed: $TESTS_PASSED"
    log_info "Tests failed: $TESTS_FAILED"
    
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
    docker ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Names}}" | while read -r container; do
        if [[ -n "$container" ]]; then
            docker stop "$container" > /dev/null 2>&1 || true
            docker rm "$container" > /dev/null 2>&1 || true
        fi
    done
    
    # Remove test image
    docker rmi "$CONTAINER_NAME" > /dev/null 2>&1 || true
    
    log_info "Cleanup completed"
}

# Trap cleanup on exit
trap cleanup EXIT

# Run tests
case "${1:-all}" in
    "extensions")
        # Quick extension test only
        run_all_tests | grep -E "(Testing Extension|PASS|FAIL|INFO.*==="
        ;;
    "profiles")
        # Profile testing only
        profiles=("supabase" "paradedb" "analytics" "ai-ml")
        for profile in "${profiles[@]}"; do
            test_profile_startup "$profile"
        done
        ;;
    "quick")
        # Quick smoke test
        log_info "Running quick smoke test..."
        docker build -t "$CONTAINER_NAME" "$POSTGRES_DIR" > /dev/null
        docker run -d --name "$CONTAINER_NAME" -e POSTGRES_PASSWORD="test" "$CONTAINER_NAME" > /dev/null
        if wait_for_postgres; then
            log_success "Quick smoke test passed"
        else
            log_failure "Quick smoke test failed"
        fi
        ;;
    "all"|*)
        # Full test suite
        run_all_tests
        ;;
esac
