#!/usr/bin/env bash
# Multi-arch manifest creation helper
# Consolidates manifest logic used by auto-build.yaml and recreate-manifests.yaml
#
# Requires env vars: TAG, VERSION, FULL_VERSION, VARIANT, IS_DEFAULT, IS_LATEST_VERSION
#
# Usage:
#   source helpers/create-manifest.sh
#   create_registry_manifest <target_image> <source_image> [fail_on_error]
#
# Example:
#   create_registry_manifest "ghcr.io/owner/container" "ghcr.io/owner/container" true
#   create_registry_manifest "docker.io/owner/container" "ghcr.io/owner/container" false

set -euo pipefail

# Compute tag arguments for manifest creation
# Reads from env: TAG, VERSION, FULL_VERSION, VARIANT, IS_DEFAULT, IS_LATEST_VERSION
# Args: $1 = target image (e.g., ghcr.io/owner/container)
# Output: tag arguments string for docker buildx imagetools create
_compute_tag_args() {
    local target_image="$1"

    # Rolling version tag is always included (e.g., 18-alpine)
    local tag_args="-t $target_image:$TAG"

    # Version-specific tag (e.g., 18.2-alpine alongside rolling 18-alpine)
    # Enables dashboard version tracking via registry pattern matching
    if [[ -n "${FULL_VERSION:-}" && "$FULL_VERSION" != "$TAG" ]]; then
        local rest="${TAG#$VERSION}"
        local full_numeric
        full_numeric=$(echo "$FULL_VERSION" | grep -oP '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
        if [[ -n "$full_numeric" ]]; then
            local full_tag="${full_numeric}${rest}"
            if [[ "$full_tag" != "$TAG" ]]; then
                tag_args="$tag_args -t $target_image:$full_tag"
                echo "::notice::Adding version-specific tag: $full_tag"
            fi
        fi
    fi

    # Rolling tags only for the latest version
    # Add :latest tag for default variant of the latest version
    if [[ "${IS_DEFAULT:-}" == "true" && "${IS_LATEST_VERSION:-}" == "true" ]]; then
        tag_args="$tag_args -t $target_image:latest"
    fi

    # Add :latest-{variant} tag for non-default variants of the latest version
    if [[ -n "${VARIANT:-}" && "${IS_DEFAULT:-}" != "true" && "${IS_LATEST_VERSION:-}" == "true" ]]; then
        tag_args="$tag_args -t $target_image:latest-$VARIANT"
    fi

    echo "$tag_args"
}

# Create multi-arch manifest with automatic fallback to single platform
# Args:
#   $1 = target image base (e.g., ghcr.io/owner/container)
#   $2 = source image base (e.g., ghcr.io/owner/container) — arch-specific tags are here
#   $3 = fail_on_error (true/false, default: true)
create_registry_manifest() {
    local target_image="$1"
    local source_image="$2"
    local fail_on_error="${3:-true}"

    local tag_args
    tag_args=$(_compute_tag_args "$target_image")

    # Try multi-arch manifest first (amd64 + arm64)
    if docker buildx imagetools create $tag_args \
        "$source_image:$TAG-amd64" \
        "$source_image:$TAG-arm64" 2>/dev/null; then
        echo "::notice::Multi-arch manifest created successfully for $target_image:$TAG"
        return 0
    fi

    # Fallback to single platform (amd64)
    if docker buildx imagetools create $tag_args \
        "$source_image:$TAG-amd64" 2>/dev/null; then
        echo "::warning::Manifest created with amd64 only for $target_image:$TAG (arm64 not available)"
        return 0
    fi

    # Fallback to single platform (arm64)
    if docker buildx imagetools create $tag_args \
        "$source_image:$TAG-arm64" 2>/dev/null; then
        echo "::warning::Manifest created with arm64 only for $target_image:$TAG (amd64 not available)"
        return 0
    fi

    # All attempts failed
    if [[ "$fail_on_error" == "true" ]]; then
        echo "::error::No arch-specific images found for $target_image:$TAG"
        return 1
    else
        echo "::warning::Manifest creation failed for $target_image:$TAG"
        return 0
    fi
}
