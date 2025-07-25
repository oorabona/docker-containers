#!/bin/bash

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"

echo "🧪 Testing All Containers"
echo "========================="
echo ""

failed_containers=()
total_containers=0
test_results=()

log_test() {
    local status="$1"
    local container="$2"
    local test="$3"
    local message="$4"
    
    case "$status" in
        "PASS")
            echo -e "  ${GREEN}✅ $test${NC}: $message"
            ;;
        "FAIL")
            echo -e "  ${RED}❌ $test${NC}: $message"
            failed_containers+=("$container")
            ;;
        "WARN")
            echo -e "  ${YELLOW}⚠️  $test${NC}: $message"
            ;;
        "INFO")
            echo -e "  ${BLUE}ℹ️  $test${NC}: $message"
            ;;
    esac
}

test_container() {
    local container="$1"
    local container_failed=false
    
    echo -e "${BLUE}📦 Testing $container...${NC}"
    
    # Test 1: Check if Dockerfile exists
    if [[ -f "$container/Dockerfile" ]]; then
        log_test "PASS" "$container" "Dockerfile" "exists"
    else
        log_test "FAIL" "$container" "Dockerfile" "missing"
        container_failed=true
    fi
    
    # Test 2: Check version script
    if [[ -f "$container/version.sh" ]]; then
        if [[ -x "$container/version.sh" ]]; then
            log_test "PASS" "$container" "Version Script" "exists and executable"
            
            # Test version script execution
            if (cd "$container" && timeout 30 ./version.sh >/dev/null 2>&1); then
                log_test "PASS" "$container" "Version Current" "script works"
            else
                log_test "FAIL" "$container" "Version Current" "script failed or timed out"
                container_failed=true
            fi
            
            # Test latest version detection
            if (cd "$container" && timeout 30 ./version.sh latest >/dev/null 2>&1); then
                log_test "PASS" "$container" "Version Latest" "script works"
            else
                log_test "WARN" "$container" "Version Latest" "script failed or timed out (may be expected)"
            fi
        else
            log_test "FAIL" "$container" "Version Script" "not executable"
            container_failed=true
        fi
    else
        log_test "FAIL" "$container" "Version Script" "missing"
        container_failed=true
    fi
    
    # Test 3: Check README
    if [[ -f "$container/README.md" ]]; then
        log_test "PASS" "$container" "README" "exists"
    else
        log_test "WARN" "$container" "README" "missing (documentation needed)"
    fi
    
    # Test 4: Test Docker build
    echo -e "  ${BLUE}🔨 Testing Docker build...${NC}"
    if timeout 300 ./make build "$container" >/dev/null 2>&1; then
        log_test "PASS" "$container" "Docker Build" "successful"
    else
        log_test "FAIL" "$container" "Docker Build" "failed"
        container_failed=true
    fi
    
    # Test 5: Check for security best practices
    if [[ -f "$container/Dockerfile" ]]; then
        # Check for healthcheck
        if grep -q "HEALTHCHECK" "$container/Dockerfile"; then
            log_test "PASS" "$container" "Healthcheck" "present"
        else
            log_test "WARN" "$container" "Healthcheck" "missing"
        fi
        
        # Check for non-root user
        if grep -q "USER" "$container/Dockerfile"; then
            log_test "PASS" "$container" "Non-root User" "configured"
        else
            log_test "WARN" "$container" "Non-root User" "not configured"
        fi
        
        # Check for :latest tags (anti-pattern)
        if grep -E "FROM.*:latest" "$container/Dockerfile" >/dev/null; then
            log_test "WARN" "$container" "Base Image" "uses :latest tag (consider pinning)"
        else
            log_test "PASS" "$container" "Base Image" "properly versioned"
        fi
    fi
    
    if [ "$container_failed" = true ]; then
        test_results+=("❌ $container: FAILED")
    else
        test_results+=("✅ $container: PASSED")
    fi
    
    echo ""
}

# Main testing loop
for dir in */; do
    if [[ -f "$dir/Dockerfile" && -d "$dir" && "$dir" != "archive/" ]]; then
        container=$(basename "$dir")
        total_containers=$((total_containers + 1))
        test_container "$container"
    fi
done

# Summary
echo "📊 Test Summary"
echo "==============="
echo "Total containers tested: $total_containers"
echo ""

echo "📋 Results:"
for result in "${test_results[@]}"; do
    echo "  $result"
done

echo ""

# Failed containers summary
unique_failed=($(printf "%s\n" "${failed_containers[@]}" | sort -u))
if [[ ${#unique_failed[@]} -gt 0 ]]; then
    echo -e "${RED}❌ Failed containers (${#unique_failed[@]}):"
    printf '  - %s\n' "${unique_failed[@]}"
    echo -e "${NC}"
    exit 1
else
    echo -e "${GREEN}✅ All containers passed basic tests!${NC}"
    echo ""
    echo "🎯 Recommendations:"
    echo "  - Add healthchecks where missing"
    echo "  - Configure non-root users where possible"
    echo "  - Pin base image versions instead of using :latest"
    echo "  - Add missing READMEs for better documentation"
fi
