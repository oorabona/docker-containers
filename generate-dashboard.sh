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
EOF

        # Check for variants
        local container_dir="./$container"
        if has_variants "$container_dir"; then
            echo "  has_variants: true" >> "$DATA_FILE"
            echo "  variants:" >> "$DATA_FILE"

            while IFS= read -r variant_name; do
                [[ -z "$variant_name" ]] && continue

                local variant_tag variant_desc is_default
                variant_tag=$(variant_image_tag "$current_version" "$variant_name" "$container_dir")
                variant_desc=$(variant_property "$container_dir" "$variant_name" "description")
                is_default=$(variant_property "$container_dir" "$variant_name" "default")

                # Ensure is_default is either true or false
                [[ "$is_default" != "true" ]] && is_default="false"

                cat >> "$DATA_FILE" << EOF
    - name: "$variant_name"
      tag: "$variant_tag"
      description: "$(yaml_escape "$variant_desc")"
      is_default: $is_default
EOF
            done < <(list_variants "$container_dir")
        else
            echo "  has_variants: false" >> "$DATA_FILE"
        fi

        echo "" >> "$DATA_FILE"
    done

    # Calculate success rate
    local success_rate=100
    [[ $total -gt 0 ]] && success_rate=$(( (up_to_date * 100) / total ))

    # Write stats file
    cat > "$STATS_FILE" << EOF
# Auto-generated dashboard statistics
# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

total_containers: $total
up_to_date: $up_to_date
updates_available: $updates_available
build_success_rate: $success_rate
last_updated: "$(date -u +"%Y-%m-%d %H:%M UTC")"
EOF

    log_info "Generated $DATA_FILE with $total containers"
    log_info "Stats: $up_to_date up-to-date, $updates_available updates, ${success_rate}% success"
}

generate_data
