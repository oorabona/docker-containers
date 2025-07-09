#!/bin/bash

echo "🔧 Fixing Version Scripts"
echo "========================="
echo ""

fixed_count=0
total_scripts=0

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

for version_script in */version.sh; do
    if [[ -f "$version_script" ]]; then
        container=$(dirname "$version_script")
        total_scripts=$((total_scripts + 1))
        
        echo -e "🔍 Checking $container/version.sh..."
        
        # Check if executable
        if [[ ! -x "$version_script" ]]; then
            echo -e "  ${YELLOW}⚠️  Making executable${NC}"
            chmod +x "$version_script"
            fixed_count=$((fixed_count + 1))
        else
            echo -e "  ${GREEN}✅ Already executable${NC}"
        fi
        
        # Check for shebang
        if ! head -1 "$version_script" | grep -q "#!/"; then
            echo -e "  ${YELLOW}⚠️  Adding missing shebang${NC}"
            # Create temporary file with shebang
            {
                echo "#!/bin/bash"
                cat "$version_script"
            } > "${version_script}.tmp"
            mv "${version_script}.tmp" "$version_script"
            chmod +x "$version_script"
            fixed_count=$((fixed_count + 1))
        else
            echo -e "  ${GREEN}✅ Has shebang${NC}"
        fi
        
        # Test current version
        echo -e "  🧪 Testing current version..."
        if (cd "$container" && timeout 10 ./version.sh >/dev/null 2>&1); then
            current_version=$(cd "$container" && ./version.sh 2>/dev/null | head -1)
            echo -e "  ${GREEN}✅ Current: $current_version${NC}"
        else
            echo -e "  ${RED}❌ Current version failed${NC}"
        fi
        
        # Test latest version (allow failures for external APIs)
        echo -e "  🧪 Testing latest version..."
        if (cd "$container" && timeout 15 ./version.sh latest >/dev/null 2>&1); then
            latest_version=$(cd "$container" && ./version.sh latest 2>/dev/null | head -1)
            echo -e "  ${GREEN}✅ Latest: $latest_version${NC}"
        else
            echo -e "  ${YELLOW}⚠️  Latest version failed (may be expected for external APIs)${NC}"
        fi
        
        echo ""
    fi
done

echo "📊 Summary"
echo "=========="
echo "Total version scripts: $total_scripts"
echo "Scripts fixed: $fixed_count"

if [[ $fixed_count -gt 0 ]]; then
    echo -e "${GREEN}✅ Fixed $fixed_count version script(s)${NC}"
else
    echo -e "${GREEN}✅ All version scripts were already properly configured${NC}"
fi
