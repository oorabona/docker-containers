#!/bin/bash
# Generate dashboard data as YAML for Jekyll consumption
# This script outputs container data that Jekyll can iterate over
#
# Architecture: data is collected as JSON objects, then converted to YAML via yq.
# This eliminates fragile echo/heredoc YAML generation and ensures consistency
# between containers.yml and per-container page files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/helpers/logging.sh"
source "$SCRIPT_DIR/helpers/variant-utils.sh"
source "$SCRIPT_DIR/helpers/build-args-utils.sh"
source "$SCRIPT_DIR/helpers/registry-utils.sh"
source "$SCRIPT_DIR/helpers/version-utils.sh"

DATA_FILE="$SCRIPT_DIR/docs/site/_data/containers.yml"
STATS_FILE="$SCRIPT_DIR/docs/site/_data/stats.yml"
CONTAINERS_DIR="$SCRIPT_DIR/docs/site/_containers"

# --- Lineage resolution helpers ---

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
    fallback=$(find "$lineage_dir" -maxdepth 1 -name "${container}-*.json" -print -quit 2>/dev/null)
    if [[ -n "$fallback" ]]; then
        echo "$fallback"
    fi
}

# Resolve lineage file for a specific variant of a container
# Primary: {container}-{tag}.json (e.g. postgres-18-alpine.json)
# Fallback 1: {container}-{flavor}.json (legacy format, e.g. postgres-base.json)
# Fallback 2: {container}.json (non-variant containers)
resolve_variant_lineage_file() {
    local container="$1"
    local tag="$2"
    local flavor="${3:-}"
    local lineage_dir="$SCRIPT_DIR/.build-lineage"
    # Primary: per-tag lineage file (new format)
    local lineage_file="$lineage_dir/${container}-${tag}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
        return
    fi
    # Fallback 1: per-flavor lineage file (legacy format)
    if [[ -n "$flavor" ]]; then
        lineage_file="$lineage_dir/${container}-${flavor}.json"
        if [[ -f "$lineage_file" ]]; then
            echo "$lineage_file"
            return
        fi
    fi
    # Fallback 2: main container lineage
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

# Get container-level build_args from lineage as JSON array [{name, value}, ...]
# Falls back to config.yaml when lineage files are unavailable
get_build_lineage_args_json() {
    local container="$1"

    # Try lineage file first
    local lineage_file
    lineage_file=$(resolve_lineage_file "$container")
    if [[ -n "$lineage_file" ]]; then
        local args
        args=$(jq '.build_args // {}' "$lineage_file" 2>/dev/null)
        if [[ "$args" != "{}" && -n "$args" ]]; then
            echo "$args" | jq '[to_entries[] | {name: .key, value: (.value | tostring)}]'
            return
        fi
    fi

    # Fallback to config.yaml
    local lines
    lines=$(build_args_lines "$SCRIPT_DIR/$container")
    if [[ -n "$lines" ]]; then
        echo "$lines" | jq -R 'split("=") | {name: .[0], value: (.[1:] | join("="))}' | jq -s '.'
        return
    fi

    echo "[]"
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

# --- Container metadata helpers ---

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

    local current_version latest_version status_color status_text

    current_version=$(get_current_published_version "oorabona/$container")
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
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

# --- JSON data collection ---
# These functions build container data as JSON objects, eliminating the need
# for manual YAML string construction. The JSON is converted to YAML via yq.

# Resolve variant lineage data as JSON: {build_digest, base_image}
# Includes version mismatch check and fallback base_image derivation
resolve_variant_lineage_json() {
    local container="$1" tag="$2" version="$3" fallback_base_image="${4:-unknown}" flavor="${5:-}"

    local lineage_file build_digest="unknown" base_image="unknown"
    lineage_file=$(resolve_variant_lineage_file "$container" "$tag" "$flavor")

    if [[ -n "$lineage_file" ]]; then
        build_digest=$(jq -r '.build_digest // "unknown"' "$lineage_file" 2>/dev/null || echo "unknown")
        base_image=$(jq -r '.base_image_ref // "unknown"' "$lineage_file" 2>/dev/null || echo "unknown")
        # Version mismatch check: lineage file may be from a different version
        if [[ "$base_image" != "unknown" ]]; then
            local lineage_ver
            lineage_ver=$(jq -r '.version // ""' "$lineage_file" 2>/dev/null || echo "")
            # Compare major version: lineage may store a major-version tag
            # (e.g., "18-alpine") while version is a full version (e.g.,
            # "18.1-alpine"). Extract leading digits to compare.
            local lineage_major="${lineage_ver%%[^0-9]*}"
            local version_major="${version%%[^0-9]*}"
            if [[ -n "$lineage_major" && -n "$version_major" && "$lineage_major" != "$version_major" ]]; then
                base_image="${base_image%%:*}:${version}"
                build_digest="unknown"
            fi
        fi
    else
        # Derive base_image from fallback prefix + version
        local prefix="${fallback_base_image%%:*}"
        if [[ -n "$prefix" && "$prefix" != "unknown" ]]; then
            base_image="${prefix}:${version}"
        fi
    fi

    BD="$build_digest" BI="$base_image" \
        yq -n -o json '.build_digest = env(BD) | .base_image = env(BI)'
}

# Build a single variant entry as JSON
# Handles sizes, lineage, and build_args in one place (no duplication)
collect_variant_json() {
    local container="$1" container_dir="$2" variant_name="$3"
    local version="$4" current_version="$5" fallback_base_image="$6"
    local is_versioned="${7:-false}"

    local variant_tag variant_desc is_default
    variant_tag=$(variant_image_tag "$version" "$variant_name" "$container_dir")
    if [[ "$is_versioned" == "true" ]]; then
        variant_desc=$(variant_property "$container_dir" "$variant_name" "description" "$version")
        is_default=$(variant_property "$container_dir" "$variant_name" "default" "$version")
    else
        variant_desc=$(variant_property "$container_dir" "$variant_name" "description")
        is_default=$(variant_property "$container_dir" "$variant_name" "default")
    fi
    [[ "$is_default" != "true" ]] && is_default="false"

    # Sizes
    local size_amd64="" size_arm64=""
    if [[ "$current_version" != "no-published-version" ]]; then
        local sizes_raw
        sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
        if [[ -n "$sizes_raw" ]]; then
            size_amd64=$(echo "$sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
            size_arm64=$(echo "$sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
        fi
    fi

    # Lineage (build_digest + base_image with version mismatch check)
    # Use variant_tag for lineage file lookup, version for mismatch check
    # (NOT current_version — that's the container's latest published version,
    # which may differ from this variant's PG major version)
    local flavor
    if [[ "$is_versioned" == "true" ]]; then
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$version")
    else
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor")
    fi
    local lineage_json
    lineage_json=$(resolve_variant_lineage_json "$container" "$variant_tag" "$version" "$fallback_base_image" "$flavor")

    # Build args
    local build_args_json
    if [[ "$is_versioned" == "true" ]]; then
        build_args_json=$(get_variant_build_args_json "$container" "$variant_name" "$version")
    else
        build_args_json=$(get_variant_build_args_json "$container" "$variant_name")
    fi
    [[ -z "$build_args_json" ]] && build_args_json="[]"

    # Assemble JSON
    jq -n \
        --arg name "$variant_name" \
        --arg tag "$variant_tag" \
        --arg desc "$variant_desc" \
        --argjson is_default "$is_default" \
        --arg size_amd64 "$size_amd64" \
        --arg size_arm64 "$size_arm64" \
        --argjson lineage "$lineage_json" \
        --argjson build_args "$build_args_json" \
        '{
            name: $name, tag: $tag, description: $desc,
            is_default: $is_default,
            size_amd64: $size_amd64, size_arm64: $size_arm64,
            build_digest: $lineage.build_digest,
            base_image: $lineage.base_image
        } + (if ($build_args | length) > 0 then {build_args: $build_args} else {} end)'
}

# Build the variants structure for a container as JSON
# Handles both multi-version (postgres) and single-version (terraform) layouts
collect_variants_json() {
    local container="$1" container_dir="$2" current_version="$3" base_image="$4"

    local ver_count
    ver_count=$(version_count "$container_dir")

    if [[ "$ver_count" -gt 0 ]]; then
        # Multi-version: {has_variants: true, versions: [{tag, base_tag, variants: [...]}]}
        local versions_json="[]"
        while IFS= read -r ver_tag; do
            [[ -z "$ver_tag" ]] && continue
            local base_tag
            base_tag=$(variant_image_tag "$ver_tag" "base" "$container_dir")

            local variants_arr="[]"
            while IFS= read -r variant_name; do
                [[ -z "$variant_name" ]] && continue
                local var_json
                var_json=$(collect_variant_json "$container" "$container_dir" "$variant_name" \
                    "$ver_tag" "$current_version" "$base_image" "true")
                variants_arr=$(echo "$variants_arr" | jq --argjson v "$var_json" '. + [$v]')
            done < <(list_variants "$container_dir" "$ver_tag")

            local ver_json
            ver_json=$(jq -n \
                --arg tag "$ver_tag" --arg base_tag "$base_tag" \
                --argjson variants "$variants_arr" \
                '{tag: $tag, base_tag: $base_tag, variants: $variants}')
            versions_json=$(echo "$versions_json" | jq --argjson v "$ver_json" '. + [$v]')
        done < <(list_versions "$container_dir")

        jq -n --argjson versions "$versions_json" \
            '{has_variants: true, versions: $versions}'
    else
        # Single-version: {has_variants: true, variants: [...]}
        local variants_arr="[]"
        while IFS= read -r variant_name; do
            [[ -z "$variant_name" ]] && continue
            local var_json
            var_json=$(collect_variant_json "$container" "$container_dir" "$variant_name" \
                "$current_version" "$current_version" "$base_image" "false")
            variants_arr=$(echo "$variants_arr" | jq --argjson v "$var_json" '. + [$v]')
        done < <(list_variants "$container_dir")

        jq -n --argjson variants "$variants_arr" \
            '{has_variants: true, variants: $variants}'
    fi
}

# --- Output functions ---

# Generate a Jekyll collection page for a container
# Takes a JSON object and writes YAML front matter via yq
generate_container_page() {
    local container="$1"
    local container_json="$2"
    local page_file="$CONTAINERS_DIR/${container}.md"

    # Add layout field and convert JSON to YAML front matter
    echo "---" > "$page_file"
    echo "$container_json" | jq '{layout: "container-detail"} + .' | yq -P >> "$page_file"
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

# --- Registry wrappers ---
# Thin wrappers over helpers/registry-utils.sh
# Preserves dashboard-specific calling conventions and output formats

# Get Docker Hub stats (pulls and stars)
# Usage: get_dockerhub_stats <user> <repo>
# Output: "pulls:N stars:M"
get_dockerhub_stats() {
    dockerhub_get_repo_stats "$@"
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

# Get GHCR image sizes formatted for dashboard (MB suffix)
# Usage: get_ghcr_sizes <image> [tag]
# Output: "amd64:84.0MB arm64:81.5MB"
get_ghcr_sizes() {
    local image=${1#ghcr.io/}
    local tag=${2:-latest}
    local sizes_output=""

    local raw_sizes
    raw_sizes=$(ghcr_get_manifest_sizes "$image" "$tag") || return

    while IFS=':' read -r arch bytes; do
        [[ -z "$arch" || -z "$bytes" ]] && continue
        if [[ "$bytes" -gt 0 ]] 2>/dev/null; then
            local size_mb
            size_mb=$(echo "scale=1; $bytes/1048576" | bc)
            sizes_output+="${arch}:${size_mb}MB "
        fi
    done <<< "$raw_sizes"

    echo "${sizes_output% }"
}

# --- GitHub API helper ---

# Fetch from GitHub API with gh CLI (authenticated) or curl fallback
# Usage: github_api_get "endpoint" [max_time]
github_api_get() {
    local endpoint="$1"
    local max_time="${2:-15}"

    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        gh api "$endpoint" 2>/dev/null
    else
        curl -s --max-time "$max_time" \
            "https://api.github.com/$endpoint" 2>/dev/null
    fi
}

# --- Stats calculation functions ---

# Calculate build success rate from auto-build workflow jobs (last 30 days)
# Only counts jobs that start with "Build" to exclude detection, manifest, etc.
# Output: "success_count:total_count:rate_percent"
calculate_build_success_rate() {
    local build_success=0 build_total=0 build_success_rate=0
    local thirty_days_ago
    thirty_days_ago=$(date -u -d "30 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-30d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

    local build_runs_json
    build_runs_json=$(github_api_get "repos/oorabona/docker-containers/actions/workflows/auto-build.yaml/runs?per_page=20&created=>$thirty_days_ago" 30)

    if [[ -n "$build_runs_json" ]] && echo "$build_runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        local run_ids
        run_ids=$(echo "$build_runs_json" | jq -r '.workflow_runs[] | select(.status == "completed") | .id' 2>/dev/null)

        for run_id in $run_ids; do
            local jobs_json
            jobs_json=$(github_api_get "repos/oorabona/docker-containers/actions/runs/$run_id/jobs?per_page=50" 10)

            if [[ -n "$jobs_json" ]] && echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
                local run_build_total run_build_success
                run_build_total=$(echo "$jobs_json" | jq '[.jobs[] | select(.name | startswith("Build")) | select(.status == "completed" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
                run_build_success=$(echo "$jobs_json" | jq '[.jobs[] | select(.name | startswith("Build")) | select(.status == "completed" and .conclusion == "success")] | length' 2>/dev/null || echo "0")

                build_total=$((build_total + run_build_total))
                build_success=$((build_success + run_build_success))
            fi
        done

        [[ $build_total -gt 0 ]] && build_success_rate=$(( (build_success * 100) / build_total ))
    fi

    echo "${build_success}:${build_total}:${build_success_rate}"
}

# Global cache for per-container build status (populated once, used by get_container_build_status)
# Format: JSON object {"container_name": "status", ...} where status is success/failure/cancelled/pending
declare -g CONTAINER_BUILD_STATUS_CACHE=""

# Populate per-container build status cache from GitHub API
# Queries the most recent auto-build workflow run to get actual CI status per container
populate_container_build_status_cache() {
    log_info "Fetching per-container build status from GitHub Actions..."

    # Get the most recent completed auto-build run
    local runs_json
    runs_json=$(github_api_get "repos/oorabona/docker-containers/actions/workflows/auto-build.yaml/runs?per_page=5&status=completed" 15)

    if [[ -z "$runs_json" ]] || ! echo "$runs_json" | jq -e '.workflow_runs[0]' >/dev/null 2>&1; then
        log_warn "Could not fetch workflow runs, using lineage-based status"
        CONTAINER_BUILD_STATUS_CACHE="{}"
        return
    fi

    # Get the most recent run ID
    local run_id
    run_id=$(echo "$runs_json" | jq -r '.workflow_runs[0].id' 2>/dev/null)

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        CONTAINER_BUILD_STATUS_CACHE="{}"
        return
    fi

    # Get all jobs from this run
    local jobs_json
    jobs_json=$(github_api_get "repos/oorabona/docker-containers/actions/runs/$run_id/jobs?per_page=100" 20)

    if [[ -z "$jobs_json" ]] || ! echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
        CONTAINER_BUILD_STATUS_CACHE="{}"
        return
    fi

    # Build the cache: extract container name from job names
    # Format: "Build <container>:<variant> (<arch>)" or "Build <container> (<arch>)"
    # Group by container, take the worst status if multiple variants
    CONTAINER_BUILD_STATUS_CACHE=$(echo "$jobs_json" | jq '
        [.jobs[] |
            select(.name | test("^Build [a-z]")) |
            {
                container: (.name | sub("^Build "; "") | split(":")[0] | split(" ")[0]),
                conclusion: .conclusion
            }
        ] |
        group_by(.container) |
        map({
            key: .[0].container,
            value: (
                if any(.[]; .conclusion == "failure") then "failure"
                elif any(.[]; .conclusion == "cancelled") then "cancelled"
                elif all(.[]; .conclusion == "success") then "success"
                elif any(.[]; .conclusion == "skipped") then "skipped"
                else "pending"
                end
            )
        }) |
        from_entries
    ' 2>/dev/null || echo "{}")

    local count
    count=$(echo "$CONTAINER_BUILD_STATUS_CACHE" | jq 'length' 2>/dev/null || echo "0")
    log_info "Cached build status for $count containers from run #$run_id"
}

# Get the CI build status for a specific container
# Returns: success/failure/cancelled/pending/unknown
get_container_build_status() {
    local container="$1"

    # Populate cache on first call
    if [[ -z "$CONTAINER_BUILD_STATUS_CACHE" ]]; then
        populate_container_build_status_cache
    fi

    local status
    status=$(echo "$CONTAINER_BUILD_STATUS_CACHE" | jq -r --arg c "$container" '.[$c] // "unknown"' 2>/dev/null)

    echo "${status:-unknown}"
}

# Fetch recent workflow runs for activity display
# Output: YAML fragment for recent_activity
fetch_recent_activity() {
    local runs_json activity_yaml=""
    runs_json=$(github_api_get "repos/oorabona/docker-containers/actions/runs?per_page=5&status=completed")

    if [[ -n "$runs_json" ]] && echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        activity_yaml="recent_activity:"
        while IFS= read -r run_line; do
            [[ -z "$run_line" ]] && continue
            local run_name run_conclusion run_date run_url
            run_name=$(echo "$run_line" | cut -d'|' -f1)
            run_conclusion=$(echo "$run_line" | cut -d'|' -f2)
            run_date=$(echo "$run_line" | cut -d'|' -f3)
            run_url=$(echo "$run_line" | cut -d'|' -f4)

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

    echo "$activity_yaml"
}

# Write dashboard stats YAML file
# Args: total up_to_date updates_available build_success build_total build_success_rate activity_yaml
write_stats_file() {
    local total="$1" up_to_date="$2" updates_available="$3"
    local build_success="$4" build_total="$5" build_success_rate="$6"
    local activity_yaml="$7"

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
}

# --- Main function ---

generate_data() {
    log_info "Generating Jekyll data files..."

    cd "$SCRIPT_DIR"

    local total=0 up_to_date=0 updates_available=0
    local all_containers_json="[]"

    # Prepare containers collection directory
    mkdir -p "$CONTAINERS_DIR"
    rm -f "$CONTAINERS_DIR"/*.md

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

        # Get CI build status from GitHub API (cached)
        local build_status
        build_status=$(get_container_build_status "$container")

        # Fallback logic if CI status is unknown
        if [[ "$build_status" == "unknown" ]]; then
            if [[ "$current_version" == "no-published-version" ]]; then
                build_status="pending"
            else
                build_status="success"  # Assume success if published but no recent CI data
            fi
        fi

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

        # Build container JSON with all metadata
        local build_digest base_image
        build_digest=$(get_build_lineage_field "$container" "build_digest")
        base_image=$(get_build_lineage_field "$container" "base_image_ref")

        local container_json
        container_json=$(
            NAME="$container" \
            CV="$current_version" LV="$latest_version" \
            SC="$status_color" ST="$status_text" BS="$build_status" \
            DESC="$description" \
            GHCR="ghcr.io/oorabona/$container:$current_version" \
            DH="docker.io/oorabona/$container:$current_version" \
            BD="$build_digest" BI="$base_image" \
            PC="$pull_count" PCF="$pull_count_formatted" SC2="$star_count" \
            SA="$sizes_amd64" SR="$sizes_arm64" \
            yq -n -o json '
                .name = env(NAME) |
                .current_version = env(CV) | .latest_version = env(LV) |
                .status_color = env(SC) | .status_text = env(ST) | .build_status = env(BS) |
                .description = env(DESC) |
                .ghcr_image = env(GHCR) | .dockerhub_image = env(DH) |
                .build_digest = env(BD) | .base_image = env(BI) |
                .github_username = "oorabona" | .dockerhub_username = "oorabona" |
                .pull_count = env(PC) | .pull_count_formatted = env(PCF) | .star_count = env(SC2) |
                .size_amd64 = env(SA) | .size_arm64 = env(SR)
            ')

        # Add container-level build args from lineage
        local lineage_args_json
        lineage_args_json=$(get_build_lineage_args_json "$container")
        if [[ "$lineage_args_json" != "[]" && -n "$lineage_args_json" ]]; then
            container_json=$(echo "$container_json" | jq --argjson ba "$lineage_args_json" '. + {build_args: $ba}')
        fi

        # Add builtin_extensions from config.yaml (if present)
        local ext_config="./$container/extensions/config.yaml"
        if [[ -f "$ext_config" ]]; then
            local builtin_json
            builtin_json=$(yq -o json '.builtin_extensions // []' "$ext_config" 2>/dev/null)
            if [[ "$builtin_json" != "[]" && -n "$builtin_json" ]]; then
                container_json=$(echo "$container_json" | jq --argjson be "$builtin_json" '. + {builtin_extensions: $be}')
            fi
        fi

        # Add variants (collected once, used for both page and containers.yml)
        local container_dir="./$container"
        if has_variants "$container_dir"; then
            local variants_data
            variants_data=$(collect_variants_json "$container" "$container_dir" "$current_version" "$base_image")
            # Multi-variant: per-variant digests are in variants_data, clear container-level digest
            container_json=$(echo "$container_json" | jq --argjson v "$variants_data" '. + $v | .build_digest = "per-variant"')

            # Check for variants with missing lineage (build_digest == "unknown")
            # If any variant is missing, downgrade container build_status to "warning"
            local unknown_count
            unknown_count=$(echo "$variants_data" | jq '[
                .. | objects | select(.build_digest? == "unknown")
            ] | length')
            if [[ "$unknown_count" -gt 0 && "$build_status" == "success" ]]; then
                build_status="warning"
                container_json=$(echo "$container_json" | jq --arg bs "$build_status" '.build_status = $bs')
            fi
        else
            container_json=$(echo "$container_json" | jq '. + {has_variants: false}')
        fi

        # Generate per-container Jekyll page (uses same JSON — no duplication)
        generate_container_page "$container" "$container_json"

        # Accumulate for containers.yml
        all_containers_json=$(echo "$all_containers_json" | jq --argjson c "$container_json" '. + [$c]')
    done

    # Write containers.yml from accumulated JSON
    {
        echo "# Auto-generated container data"
        echo "# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")"
        echo ""
        echo "$all_containers_json" | yq -P
    } > "$DATA_FILE"

    # Calculate build success rate from auto-build workflow jobs (last 30 days)
    log_info "Calculating build success rate from GitHub Actions build jobs..."
    local build_stats build_success build_total build_success_rate
    build_stats=$(calculate_build_success_rate)
    IFS=':' read -r build_success build_total build_success_rate <<< "$build_stats"
    log_info "Build jobs stats (30 days): $build_success/$build_total successful (${build_success_rate}%)"

    # Fetch recent workflow runs from GitHub API
    log_info "Fetching recent workflow runs..."
    local activity_yaml
    activity_yaml=$(fetch_recent_activity)

    # Write stats file
    write_stats_file "$total" "$up_to_date" "$updates_available" \
        "$build_success" "$build_total" "$build_success_rate" "$activity_yaml"

    log_info "Generated $DATA_FILE with $total containers"
    log_info "Stats: $up_to_date/$total up-to-date, $updates_available updates, build jobs success ${build_success_rate}% ($build_success/$build_total)"
}

# Only run when executed directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_data
fi
