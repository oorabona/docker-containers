#!/bin/bash

# Docker Containers Dashboard Generator - Templated Version
# Generates dashboard using Jekyll includes for clean templating

set -euo pipefail

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"

DASHBOARD_FILE="index.md"
TEMP_FILE=$(mktemp)

# Function to check if a directory should be skipped
is_skip_directory() {
    local container=$1
    
    # Skip helper directories, archived containers, and non-container directories
    if [[ "$container" == "helpers" || "$container" == "docs" || "$container" == "backup-"* || "$container" == ".github" || "$container" == "archive"* || "$container" == "_"* || "$container" == "test-"* ]]; then
        return 0  # True - should skip
    fi
    
    return 1  # False - should not skip
}

# Function to get container version comparison
get_container_versions() {
    local container=$1
    local current_version latest_version status_color status_text
    
    pushd "$container" >/dev/null 2>&1 || {
        echo "unknown|unknown|secondary|Unknown Status"
        return 1
    }
    
    # Get published version from oorabona/* registry (same logic as make script)
    local pattern
    if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
        current_version=$(../helpers/latest-docker-tag "oorabona/$container" "$pattern" 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
    else
        # Fallback: try common version pattern
        current_version=$(../helpers/latest-docker-tag "oorabona/$container" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
    fi
    
    # Get latest upstream version
    latest_version=$(timeout 30 ./version.sh 2>/dev/null | head -1 | tr -d '\n' || echo "unknown")
    
    popd >/dev/null 2>&1
    
    # Determine status based on version comparison
    if [[ "$current_version" == "no-published-version" ]]; then
        status_color="warning"
        status_text="Not Published Yet"
    elif [[ "$current_version" == "unknown" || "$latest_version" == "unknown" ]]; then
        status_color="secondary"
        status_text="Unknown Status"
    elif [[ "$current_version" == "$latest_version" ]]; then
        status_color="green"
        status_text="Up to Date"
    else
        status_color="warning"
        status_text="Update Available"
    fi
    
    # Output structured data: current|latest|color|text
    echo "${current_version}|${latest_version}|${status_color}|${status_text}"
}

# Function to generate container card include
generate_container_card() {
    local container=$1
    local description=""
    local github_username="oorabona"  # TODO: Make this configurable
    local dockerhub_username="oorabona"  # TODO: Make this configurable
    
    # Get container description from README if available
    if [[ -f "$container/README.md" ]]; then
        # Extract description from title or first meaningful paragraph
        description=$(awk '
            BEGIN { found_desc = 0 }
            # Skip YAML frontmatter
            /^---$/ && NR == 1 { in_frontmatter = 1; next }
            /^---$/ && in_frontmatter { in_frontmatter = 0; next }
            in_frontmatter { next }
            
            # Try to extract from H1 header (after cleaning up)
            /^# / && !found_desc {
                title = $0
                gsub(/^# /, "", title)
                # Remove "Docker Container" phrase (case insensitive) but keep emojis!
                gsub(/[Dd]ocker [Cc]ontainer[[:space:]]*/, "", title)
                # Clean up extra whitespace
                gsub(/^[[:space:]]*/, "", title)
                gsub(/[[:space:]]*$/, "", title)
                gsub(/[[:space:]]+/, " ", title)
                if (length(title) > 15 && length(title) < 120) {
                    print title
                    found_desc = 1
                    next
                }
            }
            
            # Look for first substantial paragraph as fallback
            /^[^#]/ && length($0) > 20 && !found_desc {
                gsub(/^[[:space:]]*/, "")
                gsub(/[[:space:]]*$/, "")
                if (length($0) > 0) {
                    print $0
                    found_desc = 1
                }
            }
        ' "$container/README.md")
    fi
    
    # Fallback description if none found
    if [[ -z "$description" ]]; then
        description="Docker container for ${container}"
    fi
    
    # Get version information (structured output: current|latest|color|text)
    local version_info
    version_info=$(get_container_versions "$container")
    
    # Parse structured output efficiently
    IFS='|' read -r current_version latest_version status_color status_text <<< "$version_info"
    
    # Generate Docker pull commands
    local ghcr_image="ghcr.io/${github_username}/${container}:${current_version}"
    local dockerhub_image="docker.io/${dockerhub_username}/${container}:${current_version}"
    
    # Generate Jekyll include call with enhanced data
    cat << EOF
{% include container-card.html 
   name="$container"
   current_version="$current_version"
   latest_version="$latest_version"
   status_color="$status_color"
   status_text="$status_text"
   build_status="success"
   description="$description"
   ghcr_image="$ghcr_image"
   dockerhub_image="$dockerhub_image"
   github_username="$github_username"
   dockerhub_username="$dockerhub_username"
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
        
        # Skip helper directories, archived containers, and non-container directories
        if is_skip_directory "$container"; then
            continue
        fi
        
        [[ -f "$container/version.sh" ]] || continue
        
        total=$((total + 1))
        
        # Get version information (structured output: current|latest|color|text)
        local version_info
        version_info=$(get_container_versions "$container")
        
        # Parse structured output efficiently
        local current_version latest_version status_color status_text
        IFS='|' read -r current_version latest_version status_color status_text <<< "$version_info"
        
        case "$status_color" in
            "green")
                up_to_date=$((up_to_date + 1))
                ;;
            "warning")
                updates_available=$((updates_available + 1))
                ;;
        esac
    done
    
    local success_rate=100
    if [[ $total -gt 0 ]]; then
        success_rate=$(( (up_to_date * 100) / total ))
    fi
    
    # Output structured stats: total|up_to_date|updates_available|success_rate
    echo "$total|$up_to_date|$updates_available|$success_rate"
}

# Main dashboard generation function
generate_dashboard() {
    log_info "Generating templated dashboard..."
    
    # Calculate statistics
    local stats
    stats=$(calculate_stats)
    
    # Parse structured stats efficiently: total|up_to_date|updates_available|success_rate
    local total up_to_date updates_available success_rate
    IFS='|' read -r total up_to_date updates_available success_rate <<< "$stats"
    
    # Export stats for potential use by workflow
    echo "DASHBOARD_STATS_TOTAL=$total" > .dashboard-stats
    echo "DASHBOARD_STATS_UP_TO_DATE=$up_to_date" >> .dashboard-stats
    echo "DASHBOARD_STATS_UPDATES_AVAILABLE=$updates_available" >> .dashboard-stats
    echo "DASHBOARD_STATS_SUCCESS_RATE=$success_rate" >> .dashboard-stats
    
    log_info "Statistics: $total total, $up_to_date up-to-date, $updates_available updates available, $success_rate% success rate"
    
    # Generate dashboard header with Jekyll front matter
    cat << EOF > "$TEMP_FILE"
---
layout: dashboard
title: Container Dashboard
permalink: /
updated: $(date -u +"%Y-%m-%d %H:%M UTC")
description: Real-time status monitoring for Docker containers with automated upstream version tracking
---

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
        
        # Skip helper directories, archived containers, and non-container directories
        if is_skip_directory "$container"; then
            continue
        fi
        
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
