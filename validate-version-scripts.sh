#!/bin/bash

# Version Script Validator
# Tests all version.sh scripts for reliability and consistency
# Enhanced with retry logic, better error handling, and fallback strategies

# Note: Not using 'set -e' to allow graceful error handling

# Configuration
readonly TIMEOUT_CURRENT=30      # Timeout for current version check
readonly TIMEOUT_LATEST=60       # Timeout for latest version check  
readonly MAX_RETRIES=3           # Maximum retries for failed operations
readonly RETRY_DELAY=2           # Delay between retries (seconds)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
total_containers=0
passed_containers=0
failed_containers=0
skipped_containers=0

# Arrays for results
declare -a passed_list=()
declare -a failed_list=()
declare -a skipped_list=()
declare -A container_issues=()

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to execute version script with retries
execute_with_retry() {
    local container="$1"
    local mode="$2"  # "current" or "latest"
    local timeout="$3"
    local retry_count=0
    local result=""
    local exit_code=0
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        if [ "$mode" = "current" ]; then
            result=$(timeout "$timeout" bash version.sh 2>/dev/null)
            exit_code=$?
        else
            result=$(timeout "$timeout" bash version.sh latest 2>/dev/null)
            exit_code=$?
        fi
        
        # Handle special case for no published version
        if [[ "$result" == "no-published-version" ]]; then
            echo "$result"
            return 2  # Special return code for no published version
        fi
        
        # Check if result is valid
        if [[ $exit_code -eq 0 && -n "$result" && "$result" != "null" && "$result" != "unknown" ]]; then
            echo "$result"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            log_warning "Retry $retry_count/$MAX_RETRIES for $container ($mode mode) - got: '$result'"
            sleep $RETRY_DELAY
        fi
    done
    
    # All retries exhausted
    echo ""
    return 1
}

# Function to validate version format
validate_version_format() {
    local version="$1"
    local issues=()
    
    # Check basic format
    if [[ -z "$version" ]]; then
        issues+=("empty")
        echo "${issues[@]}"
        return 1
    fi
    
    if [[ "$version" == "null" || "$version" == "unknown" || "$version" == "latest" ]]; then
        issues+=("invalid_value:$version")
    fi
    
    # Check for suspicious patterns
    if [[ "$version" =~ [[:space:]] ]]; then
        issues+=("contains_whitespace")
    fi
    
    if [[ ${#version} -gt 50 ]]; then
        issues+=("too_long")
    fi
    
    if [[ ! "$version" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        issues+=("invalid_characters")
    fi
    
    # Return issues if any
    if [ ${#issues[@]} -gt 0 ]; then
        echo "${issues[@]}"
        return 1
    fi
    
    return 0
}

# Function to check helper dependencies
check_dependencies() {
    local container="$1"
    local issues=()
    
    if grep -q "source.*helpers" version.sh 2>/dev/null; then
        if [[ ! -f "../helpers/docker-tags" ]]; then
            issues+=("missing_helpers")
        else
            # Check if helpers script is executable
            if [[ ! -x "../helpers/docker-tags" ]]; then
                log_warning "helpers/docker-tags is not executable - fixing"
                chmod +x "../helpers/docker-tags" 2>/dev/null || true
            fi
        fi
    fi
    
    # Check for network dependencies
    if grep -q "curl\|wget" version.sh 2>/dev/null; then
        # Test network connectivity with a simple request
        if ! timeout 10 curl -s --head https://httpbin.org/get >/dev/null 2>&1; then
            issues+=("network_unavailable")
        fi
    fi
    
    if [ ${#issues[@]} -eq 0 ]; then
        echo ""  # No issues
        return 0
    else
        echo "${issues[@]}"
        return 1
    fi
}

# Function to test a single version script
test_version_script() {
    local container="$1"
    local test_results=()
    local issues=()
    local has_errors=false
    
    echo ""
    log_info "Testing $container/version.sh"
    
    # Check if container directory exists
    if [[ ! -d "$container" ]]; then
        log_error "Container directory does not exist"
        container_issues["$container"]="directory_missing"
        return 1
    fi
    
    # Check if version.sh exists
    if [[ ! -f "$container/version.sh" ]]; then
        log_warning "No version.sh file found - skipping"
        container_issues["$container"]="version_script_missing"
        return 2
    fi
    
    # Check if version.sh is executable
    if [[ ! -x "$container/version.sh" ]]; then
        log_warning "version.sh is not executable - fixing"
        chmod +x "$container/version.sh"
    fi
    
    cd "$container"
    
    # Test syntax first
    echo "  📋 Checking syntax..."
    if bash -n version.sh 2>/dev/null; then
        log_success "Syntax check passed"
        test_results+=("syntax_ok")
    else
        log_error "Syntax errors found"
        has_errors=true
        issues+=("syntax_error")
    fi
    
    # Check dependencies
    echo "  📋 Checking dependencies..."
    dep_issues=$(check_dependencies "$container")
    if [ $? -eq 0 ]; then
        log_success "Dependencies OK"
    else
        for issue in $dep_issues; do
            log_warning "Dependency issue: $issue"
            issues+=("dep:$issue")
        done
    fi
    
    # Test 1: Check current version (no arguments) with retries
    echo "  📋 Testing current version (with retries)..."
    current_version=$(execute_with_retry "$container" "current" "$TIMEOUT_CURRENT")
    current_exit_code=$?
    
    if [ $current_exit_code -eq 0 ] && [ -n "$current_version" ]; then
        # Validate format
        format_issues=$(validate_version_format "$current_version")
        if [ $? -eq 0 ]; then
            log_success "Current version: $current_version"
            test_results+=("current_ok")
        else
            log_error "Current version format issues: $format_issues"
            issues+=("current_format:$format_issues")
            has_errors=true
        fi
    elif [ $current_exit_code -eq 2 ] && [ "$current_version" = "no-published-version" ]; then
        log_warning "No published version found (container not yet published to registry)"
        test_results+=("current_no_published")
        # This is not considered an error for validation purposes
    else
        log_error "Failed to get current version after $MAX_RETRIES retries"
        issues+=("current_failed")
        has_errors=true
    fi
    
    # Test 2: Check latest version with retries
    echo "  📋 Testing latest version (with retries)..."
    latest_version=$(execute_with_retry "$container" "latest" "$TIMEOUT_LATEST")
    if [ $? -eq 0 ] && [ -n "$latest_version" ]; then
        # Validate format
        format_issues=$(validate_version_format "$latest_version")
        if [ $? -eq 0 ]; then
            log_success "Latest version: $latest_version"
            test_results+=("latest_ok")
            
            # Compare versions if both are available
            if [[ "$current_version" != "no-published-version" && -n "$current_version" && "$current_version" != "$latest_version" ]]; then
                log_info "Version difference detected: $current_version → $latest_version"
            elif [[ "$current_version" = "no-published-version" ]]; then
                log_info "New container detected: no published version → $latest_version (ready for initial release)"
            fi
        else
            log_error "Latest version format issues: $format_issues"
            issues+=("latest_format:$format_issues")
            has_errors=true
        fi
    else
        log_error "Failed to get latest version after $MAX_RETRIES retries"
        issues+=("latest_failed")
        has_errors=true
    fi
    
    # Test 3: Performance check (measure execution time)
    echo "  📋 Testing performance..."
    start_time=$(date +%s.%N)
    if timeout "$TIMEOUT_CURRENT" bash version.sh >/dev/null 2>&1; then
        end_time=$(date +%s.%N)
        execution_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")
        if [[ "$execution_time" != "N/A" ]] && (( $(echo "$execution_time > 5.0" | bc -l 2>/dev/null || echo 0) )); then
            log_warning "Slow execution time: ${execution_time}s"
            issues+=("slow_execution:${execution_time}s")
        else
            log_success "Performance OK (${execution_time}s)"
        fi
    else
        log_warning "Performance test timed out"
        issues+=("performance_timeout")
    fi
    
    cd ..
    
    # Store issues for reporting
    if [ ${#issues[@]} -gt 0 ]; then
        container_issues["$container"]="${issues[*]}"
    fi
    
    # Overall result
    if [[ "$has_errors" == "false" ]]; then
        log_success "$container: All tests passed"
        return 0
    else
        log_error "$container: Some tests failed"
        return 1
    fi
}

# Main execution
main() {
    local specific_container=""
    local verbose=false
    local show_help=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help=true
                shift
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -c|--container)
                specific_container="$2"
                shift 2
                ;;
            *)
                specific_container="$1"
                shift
                ;;
        esac
    done
    
    if [ "$show_help" = true ]; then
        echo "🔍 Docker Containers Version Script Validator"
        echo "=============================================="
        echo ""
        echo "Usage: $0 [OPTIONS] [CONTAINER]"
        echo ""
        echo "Validates version.sh scripts for Docker containers with enhanced error handling"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help           Show this help message"
        echo "  -v, --verbose        Enable verbose output"
        echo "  -c, --container NAME Test specific container only"
        echo ""
        echo "EXAMPLES:"
        echo "  $0                   Test all containers"
        echo "  $0 wordpress         Test only wordpress container"
        echo "  $0 -c debian         Test only debian container"
        echo "  $0 -v                Test all containers with verbose output"
        echo ""
        echo "CONFIGURATION:"
        echo "  Current version timeout: ${TIMEOUT_CURRENT}s"
        echo "  Latest version timeout:  ${TIMEOUT_LATEST}s"
        echo "  Max retries:            $MAX_RETRIES"
        echo "  Retry delay:            ${RETRY_DELAY}s"
        return 0
    fi
    
    echo "🔍 Docker Containers Version Script Validator"
    echo "=============================================="
    echo ""
    
    if [ "$verbose" = true ]; then
        echo "Configuration:"
        echo "  Current version timeout: ${TIMEOUT_CURRENT}s"
        echo "  Latest version timeout:  ${TIMEOUT_LATEST}s"
        echo "  Max retries:            $MAX_RETRIES"
        echo "  Retry delay:            ${RETRY_DELAY}s"
        echo ""
    fi
    
    if [ -n "$specific_container" ]; then
        log_info "Testing specific container: $specific_container"
        ((total_containers++))
        
        if test_version_script "$specific_container"; then
            ((passed_containers++))
            passed_list+=("$specific_container")
        else
            case $? in
                1)
                    ((failed_containers++))
                    failed_list+=("$specific_container")
                    ;;
                2)
                    ((skipped_containers++))
                    skipped_list+=("$specific_container")
                    ;;
            esac
        fi
    else
        # Find all containers with Dockerfiles
        containers=$(find . -name "Dockerfile" -not -path "./.git/*" -not -path "./helpers/*" | cut -d'/' -f2 | sort -u)
        
        if [[ -z "$containers" ]]; then
            log_error "No containers found with Dockerfiles"
            exit 1
        fi
        
        log_info "Found $(echo "$containers" | wc -w) containers to test"
        
        # Test each container
        for container in $containers; do
            ((total_containers++))
            
            if test_version_script "$container"; then
                ((passed_containers++))
                passed_list+=("$container")
            else
                case $? in
                    1)
                        ((failed_containers++))
                        failed_list+=("$container")
                        ;;
                    2)
                        ((skipped_containers++))
                        skipped_list+=("$container")
                        ;;
                esac
            fi
        done
    fi
    
    # Summary
    echo ""
    echo "📊 Test Summary"
    echo "==============="
    echo "Total containers: $total_containers"
    echo "Passed: $passed_containers"
    echo "Failed: $failed_containers"
    echo "Skipped: $skipped_containers"
    echo ""
    
    # Success rate calculation
    if [ $total_containers -gt 0 ]; then
        success_rate=$((passed_containers * 100 / total_containers))
        echo "🎯 Success Rate: $success_rate%"
        echo ""
    fi
    
    if [[ ${#passed_list[@]} -gt 0 ]]; then
        echo ""
        log_success "Passed containers:"
        printf '  %s\n' "${passed_list[@]}"
    fi
    
    if [[ ${#failed_list[@]} -gt 0 ]]; then
        echo ""
        log_error "Failed containers:"
        for container in "${failed_list[@]}"; do
            if [[ -n "${container_issues[$container]}" ]]; then
                echo "  - $container: ${container_issues[$container]}"
            else
                echo "  - $container"
            fi
        done
    fi
    
    if [[ ${#skipped_list[@]} -gt 0 ]]; then
        echo ""
        log_warning "Skipped containers (no version.sh):"
        for container in "${skipped_list[@]}"; do
            if [[ -n "${container_issues[$container]}" ]]; then
                echo "  - $container: ${container_issues[$container]}"
            else
                echo "  - $container"
            fi
        done
    fi
    
    # Recommendations
    if [[ $failed_containers -gt 0 || $skipped_containers -gt 0 ]]; then
        echo ""
        echo "💡 Recommendations:"
        echo "  - For missing version.sh files, create them using the pattern in existing containers"
        echo "  - For failed scripts, check network connectivity and API rate limits"
        echo "  - For syntax errors, run 'bash -n version.sh' to debug"
        echo "  - For slow scripts, consider caching or optimizing API calls"
        echo ""
        echo "📖 For help creating version.sh scripts, see: docs/LOCAL_DEVELOPMENT.md"
    fi
    
    # Exit with error if any tests failed
    if [[ $failed_containers -gt 0 ]]; then
        echo ""
        log_error "Some version scripts have issues that need attention"
        exit 1
    else
        echo ""
        log_success "All version scripts are working correctly!"
        exit 0
    fi
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
