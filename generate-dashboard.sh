#!/bin/bash

# Docker Containers Dashboard Generator - Templated Version
# Generates dashboard using Jekyll includes for clean templating

set -euo pipefail

DASHBOARD_FILE="DASHBOARD.md"
TEMP_FILE=$(mktemp)

# Colors for terminal output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}📊 $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to get container version comparison
get_container_versions() {
    local container=$1
    cd "$container" 2>/dev/null || return 1
    
    # Get current version (from version.sh with no args)
    current_version=$(timeout 30 ./version.sh 2>/dev/null || echo "unknown")
    
    # Get latest version (from version.sh latest)
    latest_version=$(timeout 30 ./version.sh latest 2>/dev/null || echo "unknown")
    
    cd - >/dev/null
    
    # Determine status
    if [[ "$current_version" == "unknown" || "$latest_version" == "unknown" ]]; then
        echo "unknown|secondary|Unknown Status"
    elif [[ "$current_version" == "$latest_version" ]]; then
        echo "green|Up to Date"
    else
        echo "warning|Update Available"
    fi
    
    echo "$current_version"
    echo "$latest_version"
}

# Function to generate container card include
generate_container_card() {
    local container=$1
    local description=""
    
    # Get container description from README if available
    if [[ -f "$container/README.md" ]]; then
        description=$(head -n 5 "$container/README.md" | grep -v "^#" | head -n 1 | sed 's/^[[:space:]]*//')
    fi
    
    # Get version information
    local version_info
    version_info=$(get_container_versions "$container")
    local status_info=$(echo "$version_info" | head -n 1)
    local current_version=$(echo "$version_info" | sed -n '2p')
    local latest_version=$(echo "$version_info" | sed -n '3p')
    
    local status_color=$(echo "$status_info" | cut -d'|' -f1)
    local status_text=$(echo "$status_info" | cut -d'|' -f2)
    
    # Generate Jekyll include call
    cat << EOF
{% include container-card.html 
   name="$container"
   current_version="$current_version"
   latest_version="$latest_version"
   status_color="$status_color"
   status_text="$status_text"
   build_status="success"
   description="$description"
%}
EOF
}

# Function to calculate dashboard statistics
calculate_stats() {
    local total=0
    local up_to_date=0
    local updates_available=0
    
    for container in */; do
        container=${container%/}
        [[ -f "$container/version.sh" ]] || continue
        
        total=$((total + 1))
        
        local version_info
        version_info=$(get_container_versions "$container")
        local status_info=$(echo "$version_info" | head -n 1)
        local status_color=$(echo "$status_info" | cut -d'|' -f1)
        
        if [[ "$status_color" == "green" ]]; then
            up_to_date=$((up_to_date + 1))
        elif [[ "$status_color" == "warning" ]]; then
            updates_available=$((updates_available + 1))
        fi
    done
    
    local success_rate=100
    if [[ $total -gt 0 ]]; then
        success_rate=$(( (up_to_date * 100) / total ))
    fi
    
    echo "$total|$up_to_date|$updates_available|$success_rate"
}

# Main dashboard generation function
generate_dashboard() {
    log_info "Generating templated dashboard..."
    
    # Calculate statistics
    local stats
    stats=$(calculate_stats)
    local total=$(echo "$stats" | cut -d'|' -f1)
    local up_to_date=$(echo "$stats" | cut -d'|' -f2)
    local updates_available=$(echo "$stats" | cut -d'|' -f3)
    local success_rate=$(echo "$stats" | cut -d'|' -f4)
    
    # Generate dashboard header
    cat << EOF > "$TEMP_FILE"
# 📊 Container Dashboard

*Last updated: $(date -u +"%Y-%m-%d %H:%M UTC")*

{% include dashboard-stats.html 
   total_containers="$total"
   up_to_date="$up_to_date"
   updates_available="$updates_available"
   build_success_rate="$success_rate"
%}

{% include quick-actions.html %}

## 📦 Container Status

<div class="row row-deck row-cards">
EOF

    # Generate container cards
    log_info "Processing containers..."
    for container in */; do
        container=${container%/}
        
        # Skip if not a container directory
        [[ -f "$container/version.sh" ]] || continue
        [[ -f "$container/Dockerfile" ]] || continue
        
        echo "  🔍 Processing $container..."
        if generate_container_card "$container" >> "$TEMP_FILE"; then
            echo "    ✅ Generated card for $container"
        else
            log_warning "Failed to generate card for $container"
        fi
    done
    
    # Close container grid and add footer
    cat << EOF >> "$TEMP_FILE"
</div>

## 🔄 Recent Activity

- 🤖 **Automated Monitoring**: Upstream versions checked every 6 hours
- 🚀 **Auto-Build**: Triggered on version updates and code changes  
- 📊 **Dashboard Updates**: Real-time status after successful builds
- 🔒 **Branch Protection**: All changes flow through pull requests

## 📈 System Health

| Metric | Status |
|--------|--------|
| Build Success Rate | **${success_rate}%** |
| Containers Up-to-Date | **${up_to_date}/${total}** |
| Updates Available | **${updates_available}** |
| Last Check | **$(date -u +"%Y-%m-%d %H:%M UTC")** |

---

*🤖 Generated by [\`generate-dashboard.sh\`](generate-dashboard.sh) using Jekyll templating*
*📋 Update Reason: \`${UPDATE_REASON:-Manual generation}\`*
EOF

    # Replace the dashboard file
    mv "$TEMP_FILE" "$DASHBOARD_FILE"
    log_info "Templated dashboard generated successfully: $DASHBOARD_FILE"
}

# Main execution
generate_dashboard
