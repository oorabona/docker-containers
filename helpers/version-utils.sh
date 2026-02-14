#!/usr/bin/env bash
# Shared version detection utilities
# Sourced by: scripts/check-version.sh, generate-dashboard.sh

# Default semver pattern when container has no custom --registry-pattern
DEFAULT_VERSION_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$'

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
