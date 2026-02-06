#!/usr/bin/env bash

# Check 3rd party dependency versions across all containers
# Compares pinned versions in config.yaml with latest upstream releases
#
# Usage:
#   check-dependency-versions.sh [container-name]   # Check specific container
#   check-dependency-versions.sh --all               # Check all containers
#   check-dependency-versions.sh --dry-run [target]  # Show planned updates without modifying
#
# Output modes:
#   --json      Machine-readable JSON (default for CI / piped output)
#   --summary   Human-readable table (default for terminal)
#
# Exit code: always 0 (errors collected in output, not fatal)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/helpers/logging.sh"

# Classify semver change type between two versions
# Returns: major, minor, patch, or unknown
classify_version_change() {
    local current="$1"
    local latest="$2"

    # Split on dots
    IFS='.' read -ra cur_parts <<< "$current"
    IFS='.' read -ra new_parts <<< "$latest"

    local cur_major="${cur_parts[0]:-0}"
    local cur_minor="${cur_parts[1]:-0}"
    local new_major="${new_parts[0]:-0}"
    local new_minor="${new_parts[1]:-0}"

    if [[ "$cur_major" != "$new_major" ]]; then
        echo "major"
    elif [[ "$cur_minor" != "$new_minor" ]]; then
        echo "minor"
    else
        echo "patch"
    fi
}

# Build source URL for a dependency update
build_source_url() {
    local type="$1"
    local source="$2"
    local version="$3"

    case "$type" in
        github-release|github-tag)
            echo "https://github.com/${source}/releases/tag/v${version}"
            ;;
        pypi)
            echo "https://pypi.org/project/${source}/${version}/"
            ;;
        rubygems)
            echo "https://rubygems.org/gems/${source}/versions/${version}"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Discover containers that have dependency_sources in config.yaml
discover_containers() {
    local containers=()

    for config in "$PROJECT_ROOT"/*/config.yaml; do
        local container_dir
        container_dir=$(dirname "$config")
        local container_name
        container_name=$(basename "$container_dir")

        # Check if config has dependency_sources section
        if yq -e '.dependency_sources' "$config" &>/dev/null; then
            containers+=("$container_name")
        fi
    done

    # Always include postgres (uses extensions/config.yaml, not dependency_sources)
    if [[ -f "$PROJECT_ROOT/postgres/version-extension.sh" ]]; then
        containers+=("postgres")
    fi

    printf '%s\n' "${containers[@]}" | sort -u
}

# Pre-flight: validate that all build_args have dependency_sources entries (INV-05)
preflight_check() {
    local container="$1"
    local config="$PROJECT_ROOT/${container}/config.yaml"

    [[ -f "$config" ]] || return 0

    # Get all build_args keys
    local build_args
    build_args=$(yq -r '.build_args // {} | keys | .[]' "$config" 2>/dev/null) || return 0

    # Get all dependency_sources keys
    local dep_sources
    dep_sources=$(yq -r '.dependency_sources // {} | keys | .[]' "$config" 2>/dev/null) || true

    # Check each build_arg has a dependency_sources entry
    local missing=0
    while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        if ! echo "$dep_sources" | grep -qx "$arg"; then
            log_error "[${container}] build_arg '${arg}' has no dependency_sources entry (INV-05)"
            missing=$((missing + 1))
        fi
    done <<< "$build_args"

    if [[ "$missing" -gt 0 ]]; then
        log_error "[${container}] ${missing} build_arg(s) missing from dependency_sources — aborting"
        return 1
    fi
}

# Check dependencies for a container using dependency_sources config
check_container_deps() {
    local container="$1"
    local config="$PROJECT_ROOT/${container}/config.yaml"

    local updates_json="[]"
    local errors_json="[]"

    # Read dependency_sources entries
    local dep_names
    dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$config" 2>/dev/null) || {
        errors_json=$(echo "$errors_json" | jq --arg msg "Failed to read dependency_sources from ${container}/config.yaml" '. + [$msg]')
        _emit_container_result "$container" "$updates_json" "$errors_json"
        return
    }

    while IFS= read -r dep_name; do
        [[ -z "$dep_name" ]] && continue

        # Check if monitoring is disabled (monitor: false in YAML)
        # Note: can't use `// "true"` fallback — yq treats boolean false as falsy
        local is_disabled
        is_disabled=$(yq -r "(.dependency_sources.${dep_name}.monitor) == false" "$config")
        if [[ "$is_disabled" == "true" ]]; then
            continue
        fi

        local dep_type
        dep_type=$(yq -r ".dependency_sources.${dep_name}.type // \"\"" "$config")

        # Get current version from build_args
        local current_version
        current_version=$(yq -r ".build_args.${dep_name} // \"\"" "$config")

        if [[ -z "$current_version" || "$current_version" == "null" ]]; then
            errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: no current version in build_args" '. + [$msg]')
            continue
        fi

        # Query latest version based on type
        local latest_version=""
        local source_ref=""

        case "$dep_type" in
            github-release)
                local repo strip_v tag_pattern
                repo=$(yq -r ".dependency_sources.${dep_name}.repo // \"\"" "$config")
                strip_v=$(yq -r ".dependency_sources.${dep_name}.strip_v // false" "$config")
                tag_pattern=$(yq -r ".dependency_sources.${dep_name}.tag_pattern // \"\"" "$config")
                source_ref="$repo"

                local helper_args=("$repo")
                [[ "$strip_v" == "true" ]] && helper_args+=("--strip-v")
                [[ -n "$tag_pattern" && "$tag_pattern" != "null" ]] && helper_args+=("--tag-pattern" "$tag_pattern")

                latest_version=$("$PROJECT_ROOT/helpers/latest-github-release" "${helper_args[@]}" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: GitHub API error for ${repo}" '. + [$msg]')
                    continue
                }
                ;;
            github-tag)
                local repo strip_v
                repo=$(yq -r ".dependency_sources.${dep_name}.repo // \"\"" "$config")
                strip_v=$(yq -r ".dependency_sources.${dep_name}.strip_v // false" "$config")
                source_ref="$repo"

                local helper_args=("$repo")
                [[ "$strip_v" == "true" ]] && helper_args+=("--strip-v")

                latest_version=$("$PROJECT_ROOT/helpers/latest-github-release" "${helper_args[@]}" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: GitHub API error for ${repo}" '. + [$msg]')
                    continue
                }
                ;;
            pypi)
                local package
                package=$(yq -r ".dependency_sources.${dep_name}.package // \"\"" "$config")
                source_ref="$package"

                latest_version=$("$PROJECT_ROOT/helpers/latest-pypi-version" "$package" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: PyPI API error for ${package}" '. + [$msg]')
                    continue
                }
                ;;
            rubygems)
                local gem
                gem=$(yq -r ".dependency_sources.${dep_name}.gem // \"\"" "$config")
                source_ref="$gem"

                latest_version=$("$PROJECT_ROOT/helpers/latest-rubygems-version" "$gem" 2>/dev/null) || {
                    errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: RubyGems API error for ${gem}" '. + [$msg]')
                    continue
                }
                ;;
            *)
                errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: unknown source type '${dep_type}'" '. + [$msg]')
                continue
                ;;
        esac

        # Compare versions
        if [[ -z "$latest_version" ]]; then
            errors_json=$(echo "$errors_json" | jq --arg msg "${dep_name}: empty version returned" '. + [$msg]')
            continue
        fi

        if [[ "$current_version" != "$latest_version" ]]; then
            local change_type
            change_type=$(classify_version_change "$current_version" "$latest_version")
            local source_url
            source_url=$(build_source_url "$dep_type" "$source_ref" "$latest_version")

            updates_json=$(echo "$updates_json" | jq \
                --arg name "$dep_name" \
                --arg current "$current_version" \
                --arg latest "$latest_version" \
                --arg source_url "$source_url" \
                --arg change_type "$change_type" \
                '. + [{"name": $name, "current": $current, "latest": $latest, "source_url": $source_url, "change_type": $change_type}]')
        fi
    done <<< "$dep_names"

    _emit_container_result "$container" "$updates_json" "$errors_json"
}

# Check postgres extensions via version-extension.sh
check_postgres_deps() {
    local updates_json="[]"
    local errors_json="[]"

    local ext_output
    if ! ext_output=$("$PROJECT_ROOT/postgres/version-extension.sh" --all --json 2>/dev/null); then
        errors_json=$(echo "$errors_json" | jq '. + ["version-extension.sh --all --json failed"]')
        _emit_container_result "postgres" "$updates_json" "$errors_json"
        return
    fi

    # Parse the JSON array from version-extension.sh
    local count
    count=$(echo "$ext_output" | jq 'length' 2>/dev/null) || {
        errors_json=$(echo "$errors_json" | jq '. + ["Failed to parse version-extension.sh JSON output"]')
        _emit_container_result "postgres" "$updates_json" "$errors_json"
        return
    }

    for ((i = 0; i < count; i++)); do
        local ext_name configured latest needs_update repo
        ext_name=$(echo "$ext_output" | jq -r ".[$i].extension")
        configured=$(echo "$ext_output" | jq -r ".[$i].configured")
        latest=$(echo "$ext_output" | jq -r ".[$i].latest")
        needs_update=$(echo "$ext_output" | jq -r ".[$i].needs_update")
        repo=$(echo "$ext_output" | jq -r ".[$i].repo")

        if [[ "$needs_update" == "true" && -n "$latest" && "$latest" != "unknown" ]]; then
            local change_type
            change_type=$(classify_version_change "$configured" "$latest")
            local source_url="https://github.com/${repo}/releases/tag/v${latest}"

            updates_json=$(echo "$updates_json" | jq \
                --arg name "$ext_name" \
                --arg current "$configured" \
                --arg latest "$latest" \
                --arg source_url "$source_url" \
                --arg change_type "$change_type" \
                '. + [{"name": $name, "current": $current, "latest": $latest, "source_url": $source_url, "change_type": $change_type}]')
        elif [[ "$latest" == "unknown" || -z "$latest" ]]; then
            errors_json=$(echo "$errors_json" | jq --arg msg "${ext_name}: failed to fetch latest version" '. + [$msg]')
        fi
    done

    _emit_container_result "postgres" "$updates_json" "$errors_json"
}

# Emit a container result JSON object
_emit_container_result() {
    local container="$1"
    local updates="$2"
    local errors="$3"
    local update_count
    update_count=$(echo "$updates" | jq 'length')

    jq -n \
        --arg container "$container" \
        --argjson updates "$updates" \
        --argjson errors "$errors" \
        --argjson update_count "$update_count" \
        '{container: $container, updates: $updates, errors: $errors, update_count: $update_count}'
}

# Format results as human-readable summary table
format_summary() {
    local results="$1"
    local total_updates total_errors

    total_updates=$(echo "$results" | jq '[.[].update_count] | add // 0')
    total_errors=$(echo "$results" | jq '[.[].errors | length] | add // 0')

    echo ""
    echo "=== Dependency Version Check ==="
    echo ""

    echo "$results" | jq -r '.[] | select(.update_count > 0 or (.errors | length) > 0) |
        "Container: \(.container)",
        "  Updates: \(.update_count)",
        (.updates[] | "    \(.name): \(.current) → \(.latest) (\(.change_type))"),
        (if (.errors | length) > 0 then
            "  Errors:",
            (.errors[] | "    ⚠ \(.)")
        else empty end),
        ""'

    # Summary line
    if [[ "$total_updates" -eq 0 && "$total_errors" -eq 0 ]]; then
        echo "✅ All dependencies are up to date."
    else
        echo "Summary: ${total_updates} update(s) available, ${total_errors} error(s)"
    fi
    echo ""
}

# Main
main() {
    local target=""
    local check_all=false
    local dry_run=false
    local output_mode=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                check_all=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --json)
                output_mode="json"
                shift
                ;;
            --summary)
                output_mode="summary"
                shift
                ;;
            -h|--help)
                echo "Usage: $(basename "$0") [OPTIONS] [container-name]"
                echo ""
                echo "Check 3rd party dependency versions across containers."
                echo ""
                echo "Options:"
                echo "  --all       Check all containers with dependency monitoring"
                echo "  --dry-run   Show planned updates without modifying files"
                echo "  --json      Output machine-readable JSON"
                echo "  --summary   Output human-readable summary table"
                echo "  -h, --help  Show this help"
                echo ""
                echo "Examples:"
                echo "  $(basename "$0") terraform      # Check terraform deps"
                echo "  $(basename "$0") --all          # Check all containers"
                echo "  $(basename "$0") --all --json   # JSON output for CI"
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done

    # Default output mode: JSON if piped, summary if terminal
    if [[ -z "$output_mode" ]]; then
        if [[ -t 1 ]]; then
            output_mode="summary"
        else
            output_mode="json"
        fi
    fi

    # Determine containers to check
    local containers=()
    if [[ "$check_all" == "true" ]]; then
        mapfile -t containers < <(discover_containers)
    elif [[ -n "$target" ]]; then
        containers=("$target")
    else
        log_error "Specify a container name or use --all"
        echo "Run '$(basename "$0") --help' for usage information."
        exit 1
    fi

    # Collect results
    local results="[]"

    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry-run mode — no files will be modified" >&2
    fi

    for container in "${containers[@]}"; do
        log_info "Checking dependencies for ${container}..." >&2

        # Pre-flight validation (non-postgres only)
        if [[ "$container" != "postgres" ]]; then
            preflight_check "$container"
        fi

        # Check dependencies
        local result
        if [[ "$container" == "postgres" ]]; then
            result=$(check_postgres_deps)
        else
            result=$(check_container_deps "$container")
        fi

        results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
    done

    # Output
    if [[ "$output_mode" == "json" ]]; then
        echo "$results" | jq .
    else
        format_summary "$results"
    fi

    # Always exit 0 — errors are in the output
    exit 0
}

main "$@"
