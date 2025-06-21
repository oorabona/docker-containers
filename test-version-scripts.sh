#!/bin/bash

# Test script to validate all version.sh files work correctly
# This script can be used locally or in CI to test the upstream monitoring system

set -euo pipefail

echo "🧪 Testing all version.sh files..."
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "📋 Testing version.sh files for all containers..."
echo ""

# Initialize counters
containers_passed=0
containers_failed=0

# Initialize temp file for results
echo "" > /tmp/test_results.txt

# Find all containers with version.sh files and test them
find . -name "version.sh" -not -path "./.git/*" -not -path "./helpers/*" | while read -r version_file; do
    container=$(dirname "$version_file" | sed 's|^\./||')
    
    echo "🔍 Testing $container..."
    
    # Make version.sh executable
    chmod +x "$version_file"
    
    # Get the original directory
    original_dir=$(pwd)
    
    if cd "$container" 2>/dev/null; then
        # Test 1: Can we get latest version?
        echo -n "   📥 Getting latest version... "
        if latest_version=$(bash version.sh latest 2>/dev/null); then
            if [[ -n "$latest_version" ]]; then
                echo -e "${GREEN}✅ $latest_version${NC}"
                
                # Test 2: Can we validate the latest version?
                echo -n "   🔍 Validating latest version... "
                if validation_result=$(bash version.sh "$latest_version" 2>/dev/null); then
                    if [[ -n "$validation_result" ]]; then
                        echo -e "${GREEN}✅ Valid${NC}"
                        echo "PASS" >> /tmp/test_results.txt
                    else
                        echo -e "${RED}❌ Empty validation result${NC}"
                        echo "FAIL" >> /tmp/test_results.txt
                    fi
                else
                    echo -e "${RED}❌ Validation failed${NC}"
                    echo "FAIL" >> /tmp/test_results.txt
                fi
            else
                echo -e "${RED}❌ Empty result${NC}"
                echo "FAIL" >> /tmp/test_results.txt
            fi
        else
            echo -e "${RED}❌ Failed${NC}"
            echo "FAIL" >> /tmp/test_results.txt
        fi
        
        cd "$original_dir"
    else
        echo -e "${RED}❌ Cannot access directory${NC}"
        echo "FAIL" >> /tmp/test_results.txt
    fi
    echo ""
done

# Count results
containers_tested=$(find . -name "version.sh" -not -path "./.git/*" -not -path "./helpers/*" | wc -l)
containers_passed=$(grep -c "PASS" /tmp/test_results.txt 2>/dev/null || echo "0")
containers_failed=$(grep -c "FAIL" /tmp/test_results.txt 2>/dev/null || echo "0")

# Clean up temp file
rm -f /tmp/test_results.txt

echo ""
echo "📊 Test Summary:"
echo "   Total containers tested: $containers_tested"
echo -e "   ${GREEN}Passed: $containers_passed${NC}"
echo -e "   ${RED}Failed: $containers_failed${NC}"
echo ""

# Check results
if [[ $containers_passed -eq $containers_tested ]]; then
    echo -e "${GREEN}✅ All version.sh files passed the tests!${NC}"
elif [[ $containers_failed -eq 0 ]]; then
    echo -e "${YELLOW}⚠️ Some version.sh files did not return expected results, but no failures detected.${NC}"
elif [[ $containers_failed -gt 0 ]]; then
    echo -e "${RED}❌ Some version.sh files failed the tests!${NC}"
    echo "Please check the output above for details."
fi
exit 0