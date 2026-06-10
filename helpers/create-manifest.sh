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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logging.sh"
# shellcheck source=retry.sh
source "$SCRIPT_DIR/retry.sh"

# Compute tag arguments for manifest creation
# Reads from env: TAG, VERSION, FULL_VERSION, VARIANT, IS_DEFAULT, IS_LATEST_VERSION
# Args: $1 = target image (e.g., ghcr.io/owner/container)
# Output: tag arguments string for $DOCKER buildx imagetools create
_compute_tag_args() {
    local target_image="$1"

    # Rolling version tag is always included (e.g., 18-alpine)
    local tag_args="-t $target_image:$TAG"

    # Version-specific tag (e.g., 18.2-alpine alongside rolling 18-alpine)
    # Enables dashboard version tracking via registry pattern matching
    # Guard: TAG must start with VERSION to safely strip the prefix (P3 fix)
    if [[ -n "${FULL_VERSION:-}" && "$FULL_VERSION" != "$TAG" && "$TAG" == "$VERSION"* ]]; then
        local rest="${TAG#$VERSION}"
        local full_numeric
        full_numeric=$(echo "$FULL_VERSION" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
        if [[ -n "$full_numeric" ]]; then
            local full_tag="${full_numeric}${rest}"
            if [[ "$full_tag" != "$TAG" ]]; then
                tag_args="$tag_args -t $target_image:$full_tag"
                echo "::notice::Adding version-specific tag: $full_tag" >&2
            fi
        fi
    fi

    # Major-version rolling tag (e.g., 18-alpine-vector derived from TAG=18.3-alpine-vector).
    # Triggers when VERSION matches a clean numeric pattern (X.Y or X.Y.Z).
    # This protects against future divergence if the matrix ever produces a TAG in
    # full-version form (the inverse of the FULL_VERSION-derived block above).
    # Guard: TAG must start with VERSION to safely strip the prefix (P3 fix)
    if [[ "${VERSION:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$TAG" == "$VERSION"* ]]; then
        local major="${VERSION%%.*}"
        local rest_from_tag="${TAG#"$VERSION"}"
        local rolling_tag="${major}${rest_from_tag}"
        if [[ "$rolling_tag" != "$TAG" ]]; then
            tag_args="$tag_args -t $target_image:$rolling_tag"
            echo "::notice::Adding major-version rolling tag: $rolling_tag" >&2
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

# Compute ONLY the version-specific (most precise) tag argument.
# Used by fallback paths to avoid polluting rolling/latest tags with single-arch manifests.
#
# Logic mirrors the FULL_VERSION-derived block of `_compute_tag_args`:
#   - If FULL_VERSION provides a numeric prefix more specific than TAG → use the
#     derived full_tag (e.g., 18.3-alpine-vector when TAG=18-alpine-vector).
#   - Else → TAG itself IS the version-specific form (terraform case).
#
# Args: $1 = target image (e.g., ghcr.io/owner/container)
# Output: a single `-t target:tag` argument string (no rolling/latest aliases)
_compute_version_specific_tag_args() {
    local target_image="$1"

    # Path A: derive version-specific from FULL_VERSION
    #   e.g., 18.3-alpine-vector from TAG=18-alpine-vector + FULL_VERSION=18.3-alpine
    # Guard: TAG must start with VERSION to safely strip the prefix (P3 fix)
    if [[ -n "${FULL_VERSION:-}" && "$FULL_VERSION" != "$TAG" && "$TAG" == "$VERSION"* ]]; then
        local rest="${TAG#"$VERSION"}"
        local full_numeric
        full_numeric=$(echo "$FULL_VERSION" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
        if [[ -n "$full_numeric" ]]; then
            local full_tag="${full_numeric}${rest}"
            if [[ "$full_tag" != "$TAG" ]]; then
                echo "-t $target_image:$full_tag"
                return 0
            fi
        fi
    fi

    # Path B: VERSION is a single major integer → TAG IS the rolling form.
    # No precise anchor can be derived without FULL_VERSION; refuse so the caller
    # skips the single-arch fallback and avoids polluting the rolling tag (P2 fix).
    if [[ "${VERSION:-}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Path C: TAG itself is version-specific (e.g., terraform-style VERSION=1.15.3-alpine)
    echo "-t $target_image:$TAG"
    return 0
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

    local tag_args version_specific_tag_args
    tag_args=$(_compute_tag_args "$target_image")
    version_specific_tag_args=$(_compute_version_specific_tag_args "$target_image" 2>/dev/null) || true

    # Try multi-arch manifest first (amd64 + arm64).
    # retry_with_backoff 3 10: imagetools create is idempotent (same manifest list on retry).
    local err_output
    if err_output=$(retry_with_backoff 3 10 $DOCKER buildx imagetools create $tag_args \
        "$source_image:$TAG-amd64" \
        "$source_image:$TAG-arm64" 2>&1); then
        echo "::notice::Multi-arch manifest created successfully for $target_image:$TAG"
        return 0
    fi
    echo "::warning::Multi-arch attempt failed: $err_output"

    # Fallback amd64-only — skip if no safe version-specific anchor (P2 fix)
    if [[ -n "$version_specific_tag_args" ]]; then
        # retry_with_backoff 3 10: idempotent — recreates the same single-arch manifest.
        if err_output=$(retry_with_backoff 3 10 $DOCKER buildx imagetools create $version_specific_tag_args \
            "$source_image:$TAG-amd64" 2>&1); then
            echo "::warning::Manifest created with amd64 only for $target_image:$TAG (version-specific tag only; rolling/latest preserved)"
            return 0
        fi
        echo "::warning::amd64-only attempt failed: $err_output"
    else
        echo "::warning::Skipping amd64-only fallback for $target_image:$TAG (no version-specific anchor — would pollute rolling tag)"
    fi

    # Fallback arm64-only — skip if no safe version-specific anchor (P2 fix)
    if [[ -n "$version_specific_tag_args" ]]; then
        # retry_with_backoff 3 10: idempotent — recreates the same single-arch manifest.
        if err_output=$(retry_with_backoff 3 10 $DOCKER buildx imagetools create $version_specific_tag_args \
            "$source_image:$TAG-arm64" 2>&1); then
            echo "::warning::Manifest created with arm64 only for $target_image:$TAG (version-specific tag only; rolling/latest preserved)"
            return 0
        fi
        echo "::warning::arm64-only attempt failed: $err_output"
    else
        echo "::warning::Skipping arm64-only fallback for $target_image:$TAG (no version-specific anchor — would pollute rolling tag)"
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
