#!/usr/bin/env bash
# Build cache utilities for smart rebuild detection
# Computes build digests and checks registry to avoid unnecessary rebuilds

set -euo pipefail

# Source logging if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f log_info &>/dev/null; then
    source "$SCRIPT_DIR/logging.sh"
fi

# Label used to store build digest in images
BUILD_DIGEST_LABEL="org.opencontainers.image.build-digest"

# Compute a build digest from source files
# Usage: compute_build_digest <dockerfile> [variants_yaml] [flavor]
# Returns: SHA256 hash of concatenated file contents + metadata
compute_build_digest() {
    local dockerfile="$1"
    local variants_yaml="${2:-}"
    local flavor="${3:-}"

    local digest_input=""

    # Add Dockerfile content
    if [[ -f "$dockerfile" ]]; then
        digest_input+=$(cat "$dockerfile")
    fi

    # Add variants.yaml content if exists (affects build configuration)
    if [[ -n "$variants_yaml" && -f "$variants_yaml" ]]; then
        digest_input+=$(cat "$variants_yaml")
    fi

    # Add flavor to distinguish variant builds
    digest_input+="FLAVOR:$flavor"

    # Add extensions config if exists (for containers with extensions)
    if [[ -f "extensions/config.yaml" ]]; then
        digest_input+=$(cat "extensions/config.yaml")
    fi

    # Compute SHA256 and take first 12 chars for brevity
    echo -n "$digest_input" | sha256sum | cut -c1-12
}

# Check if an image exists in registry with matching digest
# Usage: image_needs_rebuild <image> <expected_digest>
# Returns: 0 if rebuild needed (image missing or digest mismatch), 1 if skip OK
image_needs_rebuild() {
    local image="$1"
    local expected_digest="$2"

    # Check if image exists in registry
    if ! docker manifest inspect "$image" &>/dev/null; then
        log_info "Image not in registry: $image"
        return 0  # Needs rebuild
    fi

    # Image exists, check digest label
    # Note: docker manifest inspect doesn't include labels, need to pull config
    local stored_digest
    stored_digest=$(docker buildx imagetools inspect "$image" --format '{{index .Config.Labels "'"$BUILD_DIGEST_LABEL"'"}}' 2>/dev/null || echo "")

    if [[ -z "$stored_digest" ]]; then
        log_info "No build digest label found on: $image"
        return 0  # Needs rebuild (no digest to compare)
    fi

    if [[ "$stored_digest" != "$expected_digest" ]]; then
        log_info "Digest mismatch for $image: stored=$stored_digest expected=$expected_digest"
        return 0  # Needs rebuild
    fi

    log_success "Digest match for $image - skipping rebuild"
    return 1  # Skip rebuild
}

# Check if image exists in registry (simple existence check)
# Usage: image_exists_in_registry <image>
# Returns: 0 if exists, 1 if not
image_exists_in_registry() {
    local image="$1"
    docker manifest inspect "$image" &>/dev/null
}

# Get build args for adding digest label
# Usage: get_digest_label_args <digest>
get_digest_label_args() {
    local digest="$1"
    echo "--label $BUILD_DIGEST_LABEL=$digest"
}

# Full check: should we skip this build?
# Usage: should_skip_build <image> <dockerfile> [variants_yaml] [flavor] [force_rebuild]
# Returns: 0 if should skip, 1 if should build
# Sets BUILD_DIGEST variable for use in build
should_skip_build() {
    local image="$1"
    local dockerfile="$2"
    local variants_yaml="${3:-}"
    local flavor="${4:-}"
    local force_rebuild="${5:-false}"

    # Always build if force_rebuild is set
    if [[ "$force_rebuild" == "true" ]]; then
        log_info "Force rebuild requested"
        BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$variants_yaml" "$flavor")
        export BUILD_DIGEST
        return 1  # Should build
    fi

    # Compute digest
    BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$variants_yaml" "$flavor")
    export BUILD_DIGEST

    # Check if rebuild needed
    if image_needs_rebuild "$image" "$BUILD_DIGEST"; then
        return 1  # Should build
    fi

    return 0  # Should skip
}

# Export functions
export -f compute_build_digest
export -f image_needs_rebuild
export -f image_exists_in_registry
export -f get_digest_label_args
export -f should_skip_build
export BUILD_DIGEST_LABEL
