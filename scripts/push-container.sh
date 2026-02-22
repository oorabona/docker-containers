#!/usr/bin/env bash

# Container push utility - focused on pushing containers to registries
# Part of make script decomposition for better Single Responsibility
# Supports separate GHCR and Docker Hub pushes for resilience

# Source shared logging utilities
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/helpers/logging.sh"
source "$PROJECT_ROOT/helpers/retry.sh"

# Source build utilities for platform detection
source "$SCRIPT_DIR/build-container.sh"

# Get platform configuration - sets global variables
# After calling: PLATFORM_CONFIG_PLATFORMS, PLATFORM_CONFIG_SUFFIX, PLATFORM_CONFIG_EFFECTIVE_TAG
get_platform_config() {
    local tag="$1"

    # Use BUILD_PLATFORM if set (native CI runners), otherwise detect
    if [[ -n "${BUILD_PLATFORM:-}" ]]; then
        PLATFORM_CONFIG_PLATFORMS="$BUILD_PLATFORM"
        local arch="${PLATFORM_CONFIG_PLATFORMS#linux/}"
        PLATFORM_CONFIG_SUFFIX="-${arch}"
        PLATFORM_CONFIG_EFFECTIVE_TAG="${tag}${PLATFORM_CONFIG_SUFFIX}"
        log_success "Native platform: $PLATFORM_CONFIG_PLATFORMS (tag: $PLATFORM_CONFIG_EFFECTIVE_TAG)"
    elif check_multiplatform_support; then
        PLATFORM_CONFIG_PLATFORMS="linux/amd64,linux/arm64"
        PLATFORM_CONFIG_SUFFIX=""
        PLATFORM_CONFIG_EFFECTIVE_TAG="$tag"
        log_success "Multi-platform: $PLATFORM_CONFIG_PLATFORMS"
    else
        PLATFORM_CONFIG_PLATFORMS="linux/amd64"
        PLATFORM_CONFIG_SUFFIX=""
        PLATFORM_CONFIG_EFFECTIVE_TAG="$tag"
        log_success "Single platform: $PLATFORM_CONFIG_PLATFORMS"
    fi
}

# Prepare common build arguments (delegates to shared prepare_build_args)
get_build_args() {
    local version="$1"
    prepare_build_args "$version" ""
    echo "$_BUILD_ARGS"
}

# Get label args for build digest tracking
# shellcheck disable=SC2120  # Args have defaults, callers use defaults
get_label_args() {
    local dockerfile="${1:-Dockerfile}"
    local flavor="${2:-}"

    local digest
    digest=$(compute_build_digest "$dockerfile" "$flavor")
    echo "--label $BUILD_DIGEST_LABEL=$digest"
}

# Push to GHCR (GitHub Container Registry) - PRIMARY REGISTRY
# This should NOT fail as GHCR is on GitHub infrastructure
push_ghcr() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local wanted="$4"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local ghcr_image="ghcr.io/$github_username/$container"
    local cache_image="ghcr.io/$github_username/$container:buildcache"

    log_success "=== Pushing to GHCR (primary registry) ==="

    # Get platform configuration (sets PLATFORM_CONFIG_* globals)
    get_platform_config "$tag"
    local platforms="$PLATFORM_CONFIG_PLATFORMS"
    local platform_suffix="$PLATFORM_CONFIG_SUFFIX"
    local effective_tag="$PLATFORM_CONFIG_EFFECTIVE_TAG"

    # Prepare build arguments and labels
    local build_args
    build_args=$(get_build_args "$version")
    local label_args
    label_args=$(get_label_args)

    # Prepare tags
    local tag_args="-t $ghcr_image:$effective_tag"

    # For multi-platform local builds (no suffix), also tag as latest if requested
    if [[ -z "$platform_suffix" && "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $ghcr_image:latest"
    fi

    # Registry cache configuration (read and write)
    local cache_args="--cache-from type=registry,ref=$cache_image --cache-to type=registry,ref=$cache_image,mode=max"

    log_success "Image: $ghcr_image:$effective_tag"
    log_success "Platform: $platforms"
    log_success "Build args: $build_args"
    log_success "Cache: $cache_image"

    # Build and push with retry (includes cache update)
    retry_with_backoff 3 5 docker buildx build \
        --platform "$platforms" \
        --push \
        --provenance=mode=min \
        --sbom=true \
        $cache_args \
        $build_args \
        $label_args \
        $tag_args \
        . || {
        log_error "GHCR push failed for $container:$effective_tag"
        return 1
    }

    log_success "GHCR push successful: $ghcr_image:$effective_tag"

    # Handle squashing for non-platform-specific builds
    if [[ "${SQUASH_IMAGE:-false}" == "true" && -z "$platform_suffix" ]]; then
        log_success "Squashing GHCR image..."
        ../helpers/skopeo-squash "$ghcr_image:$effective_tag" "$ghcr_image:$effective_tag" ghcr || {
            log_warning "GHCR squashing failed, keeping layered version"
        }
    fi

    return 0
}

# Push to Docker Hub - SECONDARY REGISTRY
# Uses skopeo copy from GHCR (preferred) or buildx rebuild (fallback)
# This CAN fail without failing the overall build
push_dockerhub() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local wanted="$4"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local ghcr_image="ghcr.io/$github_username/$container"
    local dockerhub_image="docker.io/$github_username/$container"

    log_success "=== Pushing to Docker Hub (secondary registry) ==="

    # Get platform configuration (sets PLATFORM_CONFIG_* globals)
    get_platform_config "$tag"
    local effective_tag="$PLATFORM_CONFIG_EFFECTIVE_TAG"

    # Preferred: skopeo copy from GHCR (no rebuild, exact same image)
    if command -v skopeo >/dev/null 2>&1; then
        log_info "Using skopeo copy: GHCR → Docker Hub (no rebuild)"

        # Copy the tagged image
        if retry_with_backoff 5 10 skopeo copy \
            --all \
            "docker://$ghcr_image:$effective_tag" \
            "docker://$dockerhub_image:$effective_tag"; then

            log_success "Docker Hub push via skopeo: $dockerhub_image:$effective_tag"

            # Also copy as :latest if requested
            if [[ "$wanted" == "latest" ]]; then
                skopeo copy --all \
                    "docker://$ghcr_image:$effective_tag" \
                    "docker://$dockerhub_image:latest" 2>/dev/null || \
                    log_warning "Failed to tag latest on Docker Hub"
            fi

            return 0
        fi

        log_warning "skopeo copy failed, falling back to buildx push"
    fi

    # Fallback: rebuild and push via buildx
    local cache_image="$ghcr_image:buildcache"
    local platforms="$PLATFORM_CONFIG_PLATFORMS"
    local platform_suffix="$PLATFORM_CONFIG_SUFFIX"

    local build_args
    build_args=$(get_build_args "$version")
    local label_args
    label_args=$(get_label_args)

    local tag_args="-t $dockerhub_image:$effective_tag"
    if [[ -z "$platform_suffix" && "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest"
    fi

    local cache_args="--cache-from type=registry,ref=$cache_image"

    log_success "Image: $dockerhub_image:$effective_tag"
    log_success "Platform: $platforms"

    retry_with_backoff 5 10 docker buildx build \
        --platform "$platforms" \
        --push \
        --provenance=mode=min \
        --sbom=true \
        $cache_args \
        $build_args \
        $label_args \
        $tag_args \
        . || {
        log_error "Docker Hub push failed for $container:$effective_tag"
        return 1
    }

    log_success "Docker Hub push successful: $dockerhub_image:$effective_tag"

    # Handle squashing for non-platform-specific builds
    if [[ "${SQUASH_IMAGE:-false}" == "true" && -z "$platform_suffix" ]]; then
        log_success "Squashing Docker Hub image..."
        ../helpers/skopeo-squash "$dockerhub_image:$effective_tag" "$dockerhub_image:$effective_tag" dockerhub || {
            log_warning "Docker Hub squashing failed, keeping layered version"
        }
    fi

    return 0
}

# Legacy function for backward compatibility
# Pushes to both registries, GHCR first (required), Docker Hub second (optional)
push_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local wanted="$4"

    log_success "=== Pushing to all registries ==="

    # GHCR is primary - must succeed
    if ! push_ghcr "$container" "$version" "$tag" "$wanted"; then
        log_error "Primary registry (GHCR) push failed - aborting"
        return 1
    fi

    # Docker Hub is secondary - can fail
    if ! push_dockerhub "$container" "$version" "$tag" "$wanted"; then
        log_warning "Secondary registry (Docker Hub) push failed - continuing anyway"
        log_warning "Images are available on GHCR: ghcr.io/${GITHUB_REPOSITORY_OWNER:-oorabona}/$container"
    fi

    return 0
}

# Export functions for use by make script
export -f retry_with_backoff
export -f get_platform_config
export -f get_build_args
export -f push_ghcr
export -f push_dockerhub
export -f push_container
