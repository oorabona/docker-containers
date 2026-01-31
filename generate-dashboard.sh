#!/bin/bash
# Generate dashboard data as YAML for Jekyll consumption
# This script outputs container data that Jekyll can iterate over

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/helpers/logging.sh"
source "$SCRIPT_DIR/helpers/variant-utils.sh"
source "$SCRIPT_DIR/helpers/build-args-utils.sh"

DATA_FILE="$SCRIPT_DIR/docs/site/_data/containers.yml"
STATS_FILE="$SCRIPT_DIR/docs/site/_data/stats.yml"
CONTAINERS_DIR="$SCRIPT_DIR/docs/site/_containers"

# Resolve the lineage JSON file for a container
# Tries {container}.json first, then falls back to {container}-*.json (first match)
resolve_lineage_file() {
    local container="$1"
    local lineage_dir="$SCRIPT_DIR/.build-lineage"
    local lineage_file="$lineage_dir/${container}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
        return
    fi
    # Fallback: flavored lineage files (e.g. postgres-base.json)
    local fallback
    fallback=$(ls "$lineage_dir/${container}"-*.json 2>/dev/null | head -1)
    if [[ -n "$fallback" ]]; then
        echo "$fallback"
    fi
}

# Resolve lineage file for a specific variant of a container
# Tries {container}-{variant}.json, then falls back to {container}.json
resolve_variant_lineage_file() {
    local container="$1"
    local variant_name="$2"
    local lineage_dir="$SCRIPT_DIR/.build-lineage"
    local lineage_file="$lineage_dir/${container}-${variant_name}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
        return
    fi
    # Fallback: main container lineage
    lineage_file="$lineage_dir/${container}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
    fi
}

# Get a field from the build lineage JSON for a container
# Falls back to "unknown" if lineage data doesn't exist
get_build_lineage_field() {
    local container="$1"
    local field="$2"
    local lineage_file
    lineage_file=$(resolve_lineage_file "$container")
    if [[ -n "$lineage_file" ]]; then
        jq -r ".[\"$field\"] // \"unknown\"" "$lineage_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get build_args from lineage as YAML key-value pairs (indented)
# Falls back to config.yaml when lineage files are unavailable
# Usage: get_build_lineage_args <container> <indent>
get_build_lineage_args() {
    local container="$1"
    local indent="${2:-    }"
    local result=""

    # Try lineage file first
    local lineage_file
    lineage_file=$(resolve_lineage_file "$container")
    if [[ -n "$lineage_file" ]]; then
        result=$(jq -r ".build_args // {} | to_entries[] | \"${indent}- name: \\\"\\(.key)\\\"\\n${indent}  value: \\\"\\(.value)\\\"\"" "$lineage_file" 2>/dev/null || true)
    fi

    # Fallback to config.yaml if lineage didn't provide build_args
    if [[ -z "$result" ]]; then
        local lines
        lines=$(build_args_lines "$SCRIPT_DIR/$container")
        if [[ -n "$lines" ]]; then
            result=$(echo "$lines" | while IFS='=' read -r key value; do
                printf '%s- name: "%s"\n%s  value: "%s"' "$indent" "$key" "$indent" "$value"
                echo
            done)
        fi
    fi

    echo "$result"
}

# Get build_args filtered for a specific variant as JSON array
# Reads build_args_include from variants.yaml; if absent, includes all build_args
# For containers with extensions (e.g. postgres), resolves extension versions from flavors
# Usage: get_variant_build_args_json <container> <variant_name> [version_tag]
get_variant_build_args_json() {
    local container="$1"
    local variant_name="$2"
    local version_tag="${3:-latest}"
    local container_dir="$SCRIPT_DIR/$container"
    local variants_file="$container_dir/variants.yaml"
    local config_file="$container_dir/config.yaml"
    local ext_config="$container_dir/extensions/config.yaml"

    # Strategy 1: containers with build_args in config.yaml (terraform, etc.)
    local args_json
    args_json=$(build_args_json "$container_dir")
    if [[ "$args_json" != "{}" ]] && [[ -n "$args_json" ]]; then
        # Check if this variant has build_args_include filter
        local filter_list=""
        if [[ -f "$variants_file" ]]; then
            filter_list=$(yq -r ".versions[] | select(.tag == \"$version_tag\") | .variants[] | select(.name == \"$variant_name\") | .build_args_include // [] | .[]" "$variants_file" 2>/dev/null)
            # Fallback to "latest" tag
            if [[ -z "$filter_list" ]]; then
                filter_list=$(yq -r '.versions[] | select(.tag == "latest") | .variants[] | select(.name == "'"$variant_name"'") | .build_args_include // [] | .[]' "$variants_file" 2>/dev/null)
            fi
        fi

        if [[ -n "$filter_list" ]]; then
            local jq_filter
            jq_filter=$(echo "$filter_list" | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
            echo "$args_json" | jq '[to_entries[] | select(.key == ('"$jq_filter"')) | {"name": .key, "value": (.value | tostring)}]' 2>/dev/null || echo "[]"
        else
            echo "$args_json" | jq '[to_entries[] | {"name": .key, "value": (.value | tostring)}]' 2>/dev/null || echo "[]"
        fi
        return
    fi

    # Strategy 2: containers with extensions (postgres) — resolve from flavor files
    local flavor_file="$container_dir/flavors/${variant_name}.yaml"
    if [[ -f "$ext_config" ]] && [[ -f "$flavor_file" ]]; then
        local ext_names
        ext_names=$(yq -r '.extensions // [] | .[]' "$flavor_file" 2>/dev/null)
        if [[ -z "$ext_names" ]]; then
            echo "[]"
            return
        fi
        # Build JSON array of {name: ext_name, value: version} from extensions/config.yaml
        local result="["
        local first=true
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            local ver
            ver=$(yq -r ".extensions.${ext}.version // \"\"" "$ext_config" 2>/dev/null)
            [[ -z "$ver" ]] && continue
            $first || result+=","
            first=false
            result+="{\"name\":\"${ext}\",\"value\":\"${ver}\"}"
        done <<< "$ext_names"
        result+="]"
        echo "$result"
        return
    fi

    echo "[]"
}

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

# Generate a Jekyll collection page for a container
# Creates _containers/<name>.md with front matter and README content
generate_container_page() {
    local container="$1"
    local current_version="$2"
    local latest_version="$3"
    local status_color="$4"
    local status_text="$5"
    local build_status="$6"
    local description="$7"
    local pull_count="$8"
    local pull_count_formatted="$9"
    local star_count="${10}"
    local sizes_amd64="${11}"
    local sizes_arm64="${12}"

    local page_file="$CONTAINERS_DIR/${container}.md"
    local build_digest base_image

    build_digest=$(get_build_lineage_field "$container" "build_digest")
    base_image=$(get_build_lineage_field "$container" "base_image_ref")

    # Write front matter
    cat > "$page_file" << FRONTMATTER
---
layout: container-detail
name: "${container}"
current_version: "${current_version}"
latest_version: "${latest_version}"
status_color: "${status_color}"
status_text: "${status_text}"
build_status: "${build_status}"
description: "$(yaml_escape "$description")"
build_digest: "${build_digest}"
base_image: "${base_image}"
pull_count: ${pull_count}
pull_count_formatted: "${pull_count_formatted}"
star_count: ${star_count}
size_amd64: "${sizes_amd64}"
size_arm64: "${sizes_arm64}"
github_username: "oorabona"
dockerhub_username: "oorabona"
ghcr_image: "ghcr.io/oorabona/${container}:${current_version}"
dockerhub_image: "docker.io/oorabona/${container}:${current_version}"
FRONTMATTER

    # Add build args from lineage (3rd party library versions)
    local lineage_args
    lineage_args=$(get_build_lineage_args "$container" "  ")
    if [[ -n "$lineage_args" ]]; then
        echo "build_args:" >> "$page_file"
        echo "$lineage_args" >> "$page_file"
    fi

    # Add variant data to front matter if applicable
    local container_dir="./$container"
    if has_variants "$container_dir"; then
        echo "has_variants: true" >> "$page_file"

        local ver_count
        ver_count=$(version_count "$container_dir")

        if [[ "$ver_count" -gt 0 ]]; then
            echo "versions:" >> "$page_file"
            while IFS= read -r ver_tag; do
                [[ -z "$ver_tag" ]] && continue
                echo "  - tag: \"$ver_tag\"" >> "$page_file"
                local base_tag
                base_tag=$(variant_image_tag "$ver_tag" "base" "$container_dir")
                echo "    base_tag: \"$base_tag\"" >> "$page_file"
                echo "    variants:" >> "$page_file"
                while IFS= read -r variant_name; do
                    [[ -z "$variant_name" ]] && continue
                    local variant_tag variant_desc is_default
                    variant_tag=$(variant_image_tag "$ver_tag" "$variant_name" "$container_dir")
                    variant_desc=$(variant_property "$container_dir" "$variant_name" "description" "$ver_tag")
                    is_default=$(variant_property "$container_dir" "$variant_name" "default" "$ver_tag")
                    [[ "$is_default" != "true" ]] && is_default="false"
                    cat >> "$page_file" << VARIANT
      - name: "${variant_name}"
        tag: "${variant_tag}"
        description: "$(yaml_escape "$variant_desc")"
        is_default: ${is_default}
VARIANT
                    # Get sizes for this variant
                    if [[ "$current_version" != "no-published-version" ]]; then
                        local var_sizes_raw var_size_amd64="" var_size_arm64=""
                        var_sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
                        if [[ -n "$var_sizes_raw" ]]; then
                            var_size_amd64=$(echo "$var_sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
                            var_size_arm64=$(echo "$var_sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
                        fi
                        echo "        size_amd64: \"$var_size_amd64\"" >> "$page_file"
                        echo "        size_arm64: \"$var_size_arm64\"" >> "$page_file"
                    else
                        echo "        size_amd64: \"\"" >> "$page_file"
                        echo "        size_arm64: \"\"" >> "$page_file"
                    fi
                    # Per-variant lineage (build_digest + base_image)
                    local var_lineage_file var_build_digest var_base_image
                    var_lineage_file=$(resolve_variant_lineage_file "$container" "$variant_name")
                    if [[ -n "$var_lineage_file" ]]; then
                        var_build_digest=$(jq -r '.build_digest // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                        var_base_image=$(jq -r '.base_image_ref // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                        # Version mismatch check: lineage file may be from a different version
                        if [[ "$var_base_image" != "unknown" ]]; then
                            local lineage_version
                            lineage_version=$(jq -r '.version // ""' "$var_lineage_file" 2>/dev/null || echo "")
                            if [[ -n "$lineage_version" && "$lineage_version" != "$ver_tag"* ]]; then
                                local base_image_prefix="${var_base_image%%:*}"
                                var_base_image="${base_image_prefix}:${base_tag}"
                                var_build_digest="unknown"
                            fi
                        fi
                    else
                        var_build_digest="unknown"
                        # Derive base_image from page-level base_image prefix + version base_tag
                        local base_image_prefix="${base_image%%:*}"
                        if [[ -n "$base_image_prefix" && "$base_image_prefix" != "unknown" ]]; then
                            var_base_image="${base_image_prefix}:${base_tag}"
                        else
                            var_base_image="unknown"
                        fi
                    fi
                    echo "        build_digest: \"$var_build_digest\"" >> "$page_file"
                    echo "        base_image: \"$var_base_image\"" >> "$page_file"
                    # Per-variant build_args (filtered by build_args_include if present)
                    local var_build_args_json
                    var_build_args_json=$(get_variant_build_args_json "$container" "$variant_name" "$ver_tag")
                    if [[ "$var_build_args_json" != "[]" ]]; then
                        echo "        build_args:" >> "$page_file"
                        echo "$var_build_args_json" | jq -r '.[] | "          - name: \"" + .name + "\"\n            value: \"" + .value + "\""' >> "$page_file"
                    fi
                done < <(list_variants "$container_dir" "$ver_tag")
            done < <(list_versions "$container_dir")
        else
            echo "variants:" >> "$page_file"
            while IFS= read -r variant_name; do
                [[ -z "$variant_name" ]] && continue
                local variant_tag variant_desc is_default
                variant_tag=$(variant_image_tag "$current_version" "$variant_name" "$container_dir")
                variant_desc=$(variant_property "$container_dir" "$variant_name" "description")
                is_default=$(variant_property "$container_dir" "$variant_name" "default")
                [[ "$is_default" != "true" ]] && is_default="false"
                cat >> "$page_file" << VARIANT
  - name: "${variant_name}"
    tag: "${variant_tag}"
    description: "$(yaml_escape "$variant_desc")"
    is_default: ${is_default}
VARIANT
                if [[ "$current_version" != "no-published-version" ]]; then
                    local var_sizes_raw var_size_amd64="" var_size_arm64=""
                    var_sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
                    if [[ -n "$var_sizes_raw" ]]; then
                        var_size_amd64=$(echo "$var_sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
                        var_size_arm64=$(echo "$var_sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
                    fi
                    echo "    size_amd64: \"$var_size_amd64\"" >> "$page_file"
                    echo "    size_arm64: \"$var_size_arm64\"" >> "$page_file"
                else
                    echo "    size_amd64: \"\"" >> "$page_file"
                    echo "    size_arm64: \"\"" >> "$page_file"
                fi
                # Per-variant lineage
                local var_lineage_file var_build_digest var_base_image
                var_lineage_file=$(resolve_variant_lineage_file "$container" "$variant_name")
                if [[ -n "$var_lineage_file" ]]; then
                    var_build_digest=$(jq -r '.build_digest // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                    var_base_image=$(jq -r '.base_image_ref // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                else
                    var_build_digest="unknown"
                    var_base_image="unknown"
                fi
                echo "    build_digest: \"$var_build_digest\"" >> "$page_file"
                echo "    base_image: \"$var_base_image\"" >> "$page_file"
            done < <(list_variants "$container_dir")
        fi
    else
        echo "has_variants: false" >> "$page_file"
    fi

    echo "---" >> "$page_file"

    # Append README content (strip front matter if present)
    if [[ -f "$container/README.md" ]]; then
        awk '
            BEGIN { in_fm = 0; fm_done = 0 }
            NR == 1 && /^---$/ { in_fm = 1; next }
            in_fm && /^---$/ { in_fm = 0; fm_done = 1; next }
            in_fm { next }
            { print }
        ' "$container/README.md" >> "$page_file"
    else
        echo "" >> "$page_file"
        echo "No README available for this container." >> "$page_file"
    fi
}

# Get Docker Hub pull count for a container
# Get Docker Hub stats (pulls and stars)
# Usage: get_dockerhub_stats <user> <repo>
# Output: "pulls:N stars:M" or "pulls:0 stars:0" on failure
get_dockerhub_stats() {
    local user=$1
    local repo=$2
    local response pulls stars

    response=$(curl -s --max-time 10 "https://hub.docker.com/v2/repositories/${user}/${repo}" 2>/dev/null)

    if [[ -n "$response" ]]; then
        pulls=$(echo "$response" | jq -r '.pull_count // 0' 2>/dev/null)
        stars=$(echo "$response" | jq -r '.star_count // 0' 2>/dev/null)
    fi

    # Default to 0 if failed or empty
    [[ -z "$pulls" || "$pulls" == "null" ]] && pulls="0"
    [[ -z "$stars" || "$stars" == "null" ]] && stars="0"

    echo "pulls:$pulls stars:$stars"
}

# Legacy wrapper for backward compatibility
get_dockerhub_pulls() {
    local stats
    stats=$(get_dockerhub_stats "$1" "$2")
    echo "$stats" | grep -oP 'pulls:\K[0-9]+'
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
# Usage: get_ghcr_sizes <image> [tag]
get_ghcr_sizes() {
    local image=$1
    local tag=${2:-latest}
    local token manifest sizes_output=""

    # Get anonymous token for GHCR
    token=$(curl -s "https://ghcr.io/token?scope=repository:${image#ghcr.io/}:pull" 2>/dev/null | \
            jq -r '.token // empty' 2>/dev/null)

    [[ -z "$token" ]] && echo "" && return

    # Get manifest list
    manifest=$(curl -s -H "Authorization: Bearer $token" \
               -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
               "https://ghcr.io/v2/${image#ghcr.io/}/manifests/${tag}" 2>/dev/null)

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

    # Prepare containers collection directory
    mkdir -p "$CONTAINERS_DIR"
    rm -f "$CONTAINERS_DIR"/*.md

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

        # Get Docker Hub stats (pulls and stars)
        local dockerhub_stats pull_count pull_count_formatted star_count
        dockerhub_stats=$(get_dockerhub_stats "oorabona" "$container")
        pull_count=$(echo "$dockerhub_stats" | grep -oP 'pulls:\K[0-9]+')
        star_count=$(echo "$dockerhub_stats" | grep -oP 'stars:\K[0-9]+')
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
  build_digest: "$(get_build_lineage_field "$container" "build_digest")"
  base_image: "$(get_build_lineage_field "$container" "base_image_ref")"
  github_username: "oorabona"
  dockerhub_username: "oorabona"
  pull_count: $pull_count
  pull_count_formatted: "$pull_count_formatted"
  star_count: $star_count
  size_amd64: "$sizes_amd64"
  size_arm64: "$sizes_arm64"
EOF

        # Add build args from lineage (3rd party library versions)
        local lineage_args
        lineage_args=$(get_build_lineage_args "$container" "    ")
        if [[ -n "$lineage_args" ]]; then
            echo "  build_args:" >> "$DATA_FILE"
            echo "$lineage_args" >> "$DATA_FILE"
        fi

        # Check for variants
        local container_dir="./$container"
        local base_image
        base_image=$(get_build_lineage_field "$container" "base_image_ref")
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
                    local base_tag
                    base_tag=$(variant_image_tag "$ver_tag" "base" "$container_dir")
                    echo "      base_tag: \"$base_tag\"" >> "$DATA_FILE"
                    echo "      variants:" >> "$DATA_FILE"

                    while IFS= read -r variant_name; do
                        [[ -z "$variant_name" ]] && continue

                        local variant_tag variant_desc is_default
                        variant_tag=$(variant_image_tag "$ver_tag" "$variant_name" "$container_dir")
                        variant_desc=$(variant_property "$container_dir" "$variant_name" "description" "$ver_tag")
                        is_default=$(variant_property "$container_dir" "$variant_name" "default" "$ver_tag")

                        [[ "$is_default" != "true" ]] && is_default="false"

                        # Get sizes for this variant (only if container is published)
                        local var_size_amd64="" var_size_arm64=""
                        if [[ "$current_version" != "no-published-version" ]]; then
                            local var_sizes_raw
                            var_sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
                            if [[ -n "$var_sizes_raw" ]]; then
                                var_size_amd64=$(echo "$var_sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
                                var_size_arm64=$(echo "$var_sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
                            fi
                        fi

                        # Per-variant lineage (build_digest + base_image)
                        local var_lineage_file var_build_digest var_base_image
                        var_lineage_file=$(resolve_variant_lineage_file "$container" "$variant_name")
                        if [[ -n "$var_lineage_file" ]]; then
                            var_build_digest=$(jq -r '.build_digest // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                            var_base_image=$(jq -r '.base_image_ref // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                            # Version mismatch check: lineage file may be from a different version
                            if [[ "$var_base_image" != "unknown" ]]; then
                                local lineage_version
                                lineage_version=$(jq -r '.version // ""' "$var_lineage_file" 2>/dev/null || echo "")
                                if [[ -n "$lineage_version" && "$lineage_version" != "$ver_tag"* ]]; then
                                    local base_image_prefix="${var_base_image%%:*}"
                                    var_base_image="${base_image_prefix}:${base_tag}"
                                    var_build_digest="unknown"
                                fi
                            fi
                        else
                            var_build_digest="unknown"
                            # Derive base_image from page-level base_image prefix + version base_tag
                            local base_image_prefix="${base_image%%:*}"
                            if [[ -n "$base_image_prefix" && "$base_image_prefix" != "unknown" ]]; then
                                var_base_image="${base_image_prefix}:${base_tag}"
                            else
                                var_base_image="unknown"
                            fi
                        fi

                        cat >> "$DATA_FILE" << EOF
        - name: "$variant_name"
          tag: "$variant_tag"
          description: "$(yaml_escape "$variant_desc")"
          is_default: $is_default
          size_amd64: "$var_size_amd64"
          size_arm64: "$var_size_arm64"
          build_digest: "$var_build_digest"
          base_image: "$var_base_image"
EOF
                        # Per-variant build_args
                        local var_build_args_json
                        var_build_args_json=$(get_variant_build_args_json "$container" "$variant_name" "$ver_tag")
                        if [[ "$var_build_args_json" != "[]" ]]; then
                            echo "          build_args:" >> "$DATA_FILE"
                            echo "$var_build_args_json" | jq -r '.[] | "            - name: \"" + .name + "\"\n              value: \"" + .value + "\""' >> "$DATA_FILE"
                        fi
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

                    # Get sizes for this variant (only if container is published)
                    local var_size_amd64="" var_size_arm64=""
                    if [[ "$current_version" != "no-published-version" ]]; then
                        local var_sizes_raw
                        var_sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
                        if [[ -n "$var_sizes_raw" ]]; then
                            var_size_amd64=$(echo "$var_sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
                            var_size_arm64=$(echo "$var_sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
                        fi
                    fi

                    # Per-variant lineage
                    local var_lineage_file var_build_digest var_base_image
                    var_lineage_file=$(resolve_variant_lineage_file "$container" "$variant_name")
                    if [[ -n "$var_lineage_file" ]]; then
                        var_build_digest=$(jq -r '.build_digest // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                        var_base_image=$(jq -r '.base_image_ref // "unknown"' "$var_lineage_file" 2>/dev/null || echo "unknown")
                    else
                        var_build_digest="unknown"
                        var_base_image="unknown"
                    fi

                    cat >> "$DATA_FILE" << EOF
    - name: "$variant_name"
      tag: "$variant_tag"
      description: "$(yaml_escape "$variant_desc")"
      is_default: $is_default
      size_amd64: "$var_size_amd64"
      size_arm64: "$var_size_arm64"
      build_digest: "$var_build_digest"
      base_image: "$var_base_image"
EOF
                done < <(list_variants "$container_dir")
            fi
        else
            echo "  has_variants: false" >> "$DATA_FILE"
        fi

        echo "" >> "$DATA_FILE"

        # Generate Jekyll collection page for this container
        generate_container_page "$container" "$current_version" "$latest_version" \
            "$status_color" "$status_text" "$build_status" "$description" \
            "$pull_count" "$pull_count_formatted" "$star_count" \
            "$sizes_amd64" "$sizes_arm64"
    done

    # Calculate build success rate from auto-build workflow jobs (last 30 days)
    # Only count jobs that start with "Build" to exclude detection, manifest, and other jobs
    log_info "Calculating build success rate from GitHub Actions build jobs..."
    local build_runs_json build_success=0 build_total=0 build_success_rate=0
    local thirty_days_ago
    thirty_days_ago=$(date -u -d "30 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-30d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

    # Fetch auto-build workflow runs from last 30 days (limit to 20 for API efficiency)
    # Prefer gh CLI (authenticated, higher rate limit) with curl fallback
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        build_runs_json=$(gh api "repos/oorabona/docker-containers/actions/workflows/auto-build.yaml/runs?per_page=20&created=>$thirty_days_ago" 2>/dev/null)
    else
        build_runs_json=$(curl -s --max-time 30 \
            "https://api.github.com/repos/oorabona/docker-containers/actions/workflows/auto-build.yaml/runs?per_page=20&created=>$thirty_days_ago" 2>/dev/null)
    fi

    if [[ -n "$build_runs_json" ]] && echo "$build_runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        # For each completed run, fetch jobs and count only "Build" jobs
        local run_ids
        run_ids=$(echo "$build_runs_json" | jq -r '.workflow_runs[] | select(.status == "completed") | .id' 2>/dev/null)

        for run_id in $run_ids; do
            local jobs_json
            if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
                jobs_json=$(gh api "repos/oorabona/docker-containers/actions/runs/$run_id/jobs?per_page=50" 2>/dev/null)
            else
                jobs_json=$(curl -s --max-time 10 \
                    "https://api.github.com/repos/oorabona/docker-containers/actions/runs/$run_id/jobs?per_page=50" 2>/dev/null)
            fi

            if [[ -n "$jobs_json" ]] && echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
                # Count only jobs starting with "Build" (e.g., "Build terraform (amd64)")
                local run_build_total run_build_success
                run_build_total=$(echo "$jobs_json" | jq '[.jobs[] | select(.name | startswith("Build")) | select(.status == "completed" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
                run_build_success=$(echo "$jobs_json" | jq '[.jobs[] | select(.name | startswith("Build")) | select(.status == "completed" and .conclusion == "success")] | length' 2>/dev/null || echo "0")

                build_total=$((build_total + run_build_total))
                build_success=$((build_success + run_build_success))
            fi
        done

        [[ $build_total -gt 0 ]] && build_success_rate=$(( (build_success * 100) / build_total ))
    fi
    log_info "Build jobs stats (30 days): $build_success/$build_total successful (${build_success_rate}%)"

    # Fetch recent workflow runs from GitHub API
    log_info "Fetching recent workflow runs..."
    local runs_json activity_yaml=""
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        runs_json=$(gh api "repos/oorabona/docker-containers/actions/runs?per_page=5&status=completed" 2>/dev/null)
    else
        runs_json=$(curl -s --max-time 15 \
            "https://api.github.com/repos/oorabona/docker-containers/actions/runs?per_page=5&status=completed" 2>/dev/null)
    fi

    if [[ -n "$runs_json" ]] && echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        activity_yaml="recent_activity:"
        while IFS= read -r run_line; do
            [[ -z "$run_line" ]] && continue
            local run_name run_conclusion run_date run_url
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
build_success_rate: $build_success_rate
build_success_count: $build_success
build_total_count: $build_total
last_updated: "$(date -u +"%Y-%m-%d %H:%M UTC")"

$activity_yaml
EOF

    log_info "Generated $DATA_FILE with $total containers"
    log_info "Stats: $up_to_date/$total up-to-date, $updates_available updates, build jobs success ${build_success_rate}% ($build_success/$build_total)"
}

generate_data
