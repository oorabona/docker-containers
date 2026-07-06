#!/usr/bin/env bash
# Shared version detection utilities
# Sourced by: scripts/check-version.sh, generate-dashboard.sh

# Default semver pattern when container has no custom --registry-pattern
DEFAULT_VERSION_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$'

_version_numeric_tuple() {
    local version="$1"
    if [[ "$version" =~ ^([0-9]+([.][0-9]+)*) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

_version_normalize_numeric_component() {
    local component="$1"
    while [[ "$component" == 0* && "$component" != "0" ]]; do
        component="${component#0}"
    done
    printf '%s\n' "$component"
}

# Compare leading numeric dotted tuples from version strings.
# Args: $1 = candidate version, $2 = current version
# Returns: 0 when candidate is greater, 1 when not greater, 2 when unparseable
version_is_greater() {
    local candidate="$1"
    local current="$2"
    local candidate_tuple current_tuple candidate_part current_part index max_parts
    local -a candidate_parts current_parts

    [[ -n "$candidate" && -n "$current" ]] || return 2
    candidate_tuple=$(_version_numeric_tuple "$candidate") || return 2
    current_tuple=$(_version_numeric_tuple "$current") || return 2

    local IFS=.
    read -r -a candidate_parts <<< "$candidate_tuple"
    read -r -a current_parts <<< "$current_tuple"

    max_parts="${#candidate_parts[@]}"
    if (( ${#current_parts[@]} > max_parts )); then
        max_parts="${#current_parts[@]}"
    fi

    for ((index = 0; index < max_parts; index++)); do
        candidate_part=$(_version_normalize_numeric_component "${candidate_parts[index]:-0}")
        current_part=$(_version_normalize_numeric_component "${current_parts[index]:-0}")

        if (( ${#candidate_part} > ${#current_part} )); then
            return 0
        fi
        if (( ${#candidate_part} < ${#current_part} )); then
            return 1
        fi
        if [[ "$candidate_part" > "$current_part" ]]; then
            return 0
        fi
        if [[ "$candidate_part" < "$current_part" ]]; then
            return 1
        fi
    done

    return 1
}

# Get the registry pattern for a container (must be called from within the container dir)
# Returns the container-specific pattern or the default semver pattern
get_registry_pattern() {
    local pattern
    if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
        echo "$pattern"
    else
        echo "$DEFAULT_VERSION_PATTERN"
    fi
}

# Get the current published version of a container from the registry
# Must be called from within the container directory
# Args: $1 = image name (e.g., "oorabona/postgres" or "ghcr.io/oorabona/postgres")
# Returns: version string, or empty if not found
# Note: defaults to GHCR (primary registry) when no registry prefix is provided
get_current_published_version() {
    local image="$1"
    local pattern
    pattern=$(get_registry_pattern)

    # Default to GHCR (primary registry) unless a specific registry is provided
    if [[ "${image%%/*}" != *.* ]]; then
        image="ghcr.io/$image"
    fi

    ../helpers/latest-docker-tag "$image" "$pattern" 2>/dev/null | head -1 | tr -d '\n'
}
