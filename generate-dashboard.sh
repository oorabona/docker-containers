#!/bin/bash
# Generate dashboard data as YAML for Jekyll consumption
# This script outputs container data that Jekyll can iterate over

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/helpers/logging.sh"
source "$SCRIPT_DIR/helpers/variant-utils.sh"

DATA_FILE="$SCRIPT_DIR/docs/site/_data/containers.yml"
STATS_FILE="$SCRIPT_DIR/docs/site/_data/stats.yml"

# Function to check if a directory should be skipped
is_skip_directory() {
    local container=$1
    [[ "$container" == "helpers" || "$container" == "docs" || "$container" == "backup-"* || \
       "$container" == ".github" || "$container" == "archive"* || "$container" == "_"* || \
       "$container" == "test-"* || "$container" == "scripts" ]]
}

# Get container versions
get_container_versions() {
    local container=$1

    pushd "$container" >/dev/null 2>&1 || {
        echo "unknown|unknown|secondary|Unknown Status"
        return 1
    }

    local pattern current_version latest_version status_color status_text

    if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
        current_version=$(../helpers/latest-docker-tag "oorabona/$container" "$pattern" 2>/dev/null | head -1 | tr -d '\n')
    else
        current_version=$(../helpers/latest-docker-tag "oorabona/$container" "^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$" 2>/dev/null | head -1 | tr -d '\n')
    fi
    # Handle empty result
    [[ -z "$current_version" ]] && current_version="no-published-version"

    latest_version=$(timeout 30 ./version.sh 2>/dev/null | head -1 | tr -d '\n' || echo "unknown")

    popd >/dev/null 2>&1

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

    echo "${current_version}|${latest_version}|${status_color}|${status_text}"
}

# Get container description from README
get_container_description() {
    local container=$1
    local description=""

    if [[ -f "$container/README.md" ]]; then
        description=$(awk '
            BEGIN { found_desc = 0 }
            /^---$/ && NR == 1 { in_frontmatter = 1; next }
            /^---$/ && in_frontmatter { in_frontmatter = 0; next }
            in_frontmatter { next }
            /^# / && !found_desc {
                title = $0
                gsub(/^# /, "", title)
                gsub(/[Dd]ocker [Cc]ontainer[[:space:]]*/, "", title)
                gsub(/^[[:space:]]*/, "", title)
                gsub(/[[:space:]]*$/, "", title)
                if (length(title) > 15 && length(title) < 120) {
                    print title
                    found_desc = 1
                }
            }
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

    if [[ -z "$description" ]]; then
        description="Docker container for ${container}"
    fi

    echo "$description"
}

# Escape YAML string (handle quotes and special chars)
yaml_escape() {
    local str="$1"
    # Replace backslashes first, then quotes
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

# Get Docker Hub pull count for a container
get_dockerhub_pulls() {
    local user=$1
    local repo=$2
    local pulls

    pulls=$(curl -s --max-time 10 "https://hub.docker.com/v2/repositories/${user}/${repo}" 2>/dev/null | \
            jq -r '.pull_count // 0' 2>/dev/null)

    # Return 0 if failed or empty
    [[ -z "$pulls" || "$pulls" == "null" ]] && pulls="0"
    echo "$pulls"
}

# Format number with K/M suffix
format_number() {
    local num=$1
    if [[ $num -ge 1000000 ]]; then
        printf "%.1fM" "$(echo "scale=1; $num/1000000" | bc)"
    elif [[ $num -ge 1000 ]]; then
        printf "%.1fK" "$(echo "scale=1; $num/1000" | bc)"
    else
        echo "$num"
    fi
}

# Get GHCR image sizes (compressed) for all architectures
get_ghcr_sizes() {
    local image=$1
    local token manifest sizes_output=""

    # Get anonymous token for GHCR
    token=$(curl -s "https://ghcr.io/token?scope=repository:${image#ghcr.io/}:pull" 2>/dev/null | \
            jq -r '.token // empty' 2>/dev/null)

    [[ -z "$token" ]] && echo "" && return

    # Get manifest list
    manifest=$(curl -s -H "Authorization: Bearer $token" \
               -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
               "https://ghcr.io/v2/${image#ghcr.io/}/manifests/latest" 2>/dev/null)

    [[ -z "$manifest" ]] && echo "" && return

    # Parse manifests for each architecture
    local manifests_data
    manifests_data=$(echo "$manifest" | jq -r '.manifests[]? | "\(.platform.architecture):\(.digest)"' 2>/dev/null)

    while IFS=':' read -r arch digest_prefix digest_hash; do
        [[ -z "$arch" || -z "$digest_hash" ]] && continue
        [[ "$arch" == "unknown" ]] && continue

        # Get blob sizes for this architecture
        local arch_manifest total_size=0
        arch_manifest=$(curl -s -H "Authorization: Bearer $token" \
                       -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
                       "https://ghcr.io/v2/${image#ghcr.io/}/manifests/${digest_prefix}:${digest_hash}" 2>/dev/null)

        if [[ -n "$arch_manifest" ]]; then
            total_size=$(echo "$arch_manifest" | jq '[.layers[]?.size // 0] | add // 0' 2>/dev/null)
        fi

        # Format size
        local size_mb
        if [[ $total_size -gt 0 ]]; then
            size_mb=$(echo "scale=1; $total_size/1048576" | bc)
            sizes_output+="${arch}:${size_mb}MB "
        fi
    done <<< "$manifests_data"

    echo "${sizes_output% }"
}

# Main function
generate_data() {
    log_info "Generating Jekyll data files..."

    cd "$SCRIPT_DIR"

    local total=0 up_to_date=0 updates_available=0

    # Start YAML file
    echo "# Auto-generated container data" > "$DATA_FILE"
    echo "# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")" >> "$DATA_FILE"
    echo "" >> "$DATA_FILE"

    for container in */; do
        container=${container%/}

        is_skip_directory "$container" && continue
        [[ -f "$container/version.sh" ]] || continue
        [[ -f "$container/Dockerfile" ]] || continue

        log_info "Processing $container..."

        local version_info
        version_info=$(get_container_versions "$container")

        IFS='|' read -r current_version latest_version status_color status_text <<< "$version_info"

        local description
        description=$(get_container_description "$container")

        local build_status="success"
        [[ "$current_version" == "no-published-version" ]] && build_status="pending"

        total=$((total + 1))
        case "$status_color" in
            "green") up_to_date=$((up_to_date + 1)) ;;
            "warning") updates_available=$((updates_available + 1)) ;;
        esac

        # Get pull count from Docker Hub
        local pull_count pull_count_formatted
        pull_count=$(get_dockerhub_pulls "oorabona" "$container")
        pull_count_formatted=$(format_number "$pull_count")

        # Get image sizes (only if published)
        local sizes_amd64="" sizes_arm64=""
        if [[ "$current_version" != "no-published-version" ]]; then
            local sizes_raw
            sizes_raw=$(get_ghcr_sizes "oorabona/$container" 2>/dev/null) || true
            if [[ -n "$sizes_raw" ]]; then
                sizes_amd64=$(echo "$sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
                sizes_arm64=$(echo "$sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
            fi
        fi

        # Write container entry
        cat >> "$DATA_FILE" << EOF
- name: "$container"
  current_version: "$current_version"
  latest_version: "$latest_version"
  status_color: "$status_color"
  status_text: "$status_text"
  build_status: "$build_status"
  description: "$(yaml_escape "$description")"
  ghcr_image: "ghcr.io/oorabona/$container:$current_version"
  dockerhub_image: "docker.io/oorabona/$container:$current_version"
  github_username: "oorabona"
  dockerhub_username: "oorabona"
  pull_count: $pull_count
  pull_count_formatted: "$pull_count_formatted"
  size_amd64: "$sizes_amd64"
  size_arm64: "$sizes_arm64"
EOF

        # Check for variants
        local container_dir="./$container"
        if has_variants "$container_dir"; then
            echo "  has_variants: true" >> "$DATA_FILE"

            # Check if multi-version structure
            local ver_count
            ver_count=$(version_count "$container_dir")

            if [[ "$ver_count" -gt 0 ]]; then
                # Multi-version structure: show versions with their variants
                echo "  versions:" >> "$DATA_FILE"

                while IFS= read -r ver_tag; do
                    [[ -z "$ver_tag" ]] && continue

                    echo "    - tag: \"$ver_tag\"" >> "$DATA_FILE"
                    echo "      variants:" >> "$DATA_FILE"

                    while IFS= read -r variant_name; do
                        [[ -z "$variant_name" ]] && continue

                        local variant_tag variant_desc is_default
                        variant_tag=$(variant_image_tag "$ver_tag" "$variant_name" "$container_dir")
                        variant_desc=$(variant_property "$container_dir" "$variant_name" "description" "$ver_tag")
                        is_default=$(variant_property "$container_dir" "$variant_name" "default" "$ver_tag")

                        [[ "$is_default" != "true" ]] && is_default="false"

                        cat >> "$DATA_FILE" << EOF
        - name: "$variant_name"
          tag: "$variant_tag"
          description: "$(yaml_escape "$variant_desc")"
          is_default: $is_default
EOF
                    done < <(list_variants "$container_dir" "$ver_tag")
                done < <(list_versions "$container_dir")
            else
                # Old single-version structure
                echo "  variants:" >> "$DATA_FILE"

                while IFS= read -r variant_name; do
                    [[ -z "$variant_name" ]] && continue

                    local variant_tag variant_desc is_default
                    variant_tag=$(variant_image_tag "$current_version" "$variant_name" "$container_dir")
                    variant_desc=$(variant_property "$container_dir" "$variant_name" "description")
                    is_default=$(variant_property "$container_dir" "$variant_name" "default")

                    [[ "$is_default" != "true" ]] && is_default="false"

                    cat >> "$DATA_FILE" << EOF
    - name: "$variant_name"
      tag: "$variant_tag"
      description: "$(yaml_escape "$variant_desc")"
      is_default: $is_default
EOF
                done < <(list_variants "$container_dir")
            fi
        else
            echo "  has_variants: false" >> "$DATA_FILE"
        fi

        echo "" >> "$DATA_FILE"
    done

    # Calculate success rate
    local success_rate=100
    [[ $total -gt 0 ]] && success_rate=$(( (up_to_date * 100) / total ))

    # Fetch recent workflow runs from GitHub API (public, no auth needed)
    log_info "Fetching recent workflow runs..."
    local runs_json activity_yaml=""
    runs_json=$(curl -s --max-time 15 \
        "https://api.github.com/repos/oorabona/docker-containers/actions/runs?per_page=5&status=completed" 2>/dev/null)

    if [[ -n "$runs_json" ]] && echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        activity_yaml="recent_activity:"
        while IFS= read -r run_line; do
            [[ -z "$run_line" ]] && continue
            local run_name run_status run_conclusion run_date run_url
            run_name=$(echo "$run_line" | cut -d'|' -f1)
            run_conclusion=$(echo "$run_line" | cut -d'|' -f2)
            run_date=$(echo "$run_line" | cut -d'|' -f3)
            run_url=$(echo "$run_line" | cut -d'|' -f4)

            # Format date for display
            local formatted_date
            formatted_date=$(date -d "$run_date" +"%b %d, %H:%M" 2>/dev/null || echo "$run_date")

            activity_yaml+="
  - name: \"$(yaml_escape "$run_name")\"
    conclusion: \"$run_conclusion\"
    date: \"$formatted_date\"
    url: \"$run_url\""
        done < <(echo "$runs_json" | jq -r '.workflow_runs[] | "\(.display_title)|\(.conclusion)|\(.created_at)|\(.html_url)"' 2>/dev/null)
    else
        activity_yaml="recent_activity: []"
    fi

    # Write stats file
    cat > "$STATS_FILE" << EOF
# Auto-generated dashboard statistics
# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

total_containers: $total
up_to_date: $up_to_date
updates_available: $updates_available
build_success_rate: $success_rate
last_updated: "$(date -u +"%Y-%m-%d %H:%M UTC")"

$activity_yaml
EOF

    log_info "Generated $DATA_FILE with $total containers"
    log_info "Stats: $up_to_date up-to-date, $updates_available updates, ${success_rate}% success"
}

generate_data
