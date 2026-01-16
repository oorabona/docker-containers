#!/usr/bin/env bash

# Container push utility - focused on pushing containers to registries
# Part of make script decomposition for better Single Responsibility
# Supports separate GHCR and Docker Hub pushes for resilience

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"

# Source build utilities for platform detection
source "$(dirname "$0")/scripts/build-container.sh"

# Retry with exponential backoff
# Usage: retry_with_backoff <max_attempts> <initial_delay> <command...>
retry_with_backoff() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
        ((attempt++))
    done

    log_error "All $max_attempts attempts failed"
    return 1
}

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

# Prepare common build arguments
get_build_args() {
    local version="$1"
    local build_args=""

    [[ -n "$version" ]] && build_args="$build_args --build-arg VERSION=$version"
    [[ -n "$NPROC" ]] && build_args="$build_args --build-arg NPROC=$NPROC"
    [[ -n "$CUSTOM_BUILD_ARGS" ]] && build_args="$build_args $CUSTOM_BUILD_ARGS"

    echo "$build_args"
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

    log_success "=== Pushing to GHCR (primary registry) ==="

    # Get platform configuration (sets PLATFORM_CONFIG_* globals)
    get_platform_config "$tag"
    local platforms="$PLATFORM_CONFIG_PLATFORMS"
    local platform_suffix="$PLATFORM_CONFIG_SUFFIX"
    local effective_tag="$PLATFORM_CONFIG_EFFECTIVE_TAG"

    # Prepare build arguments
    local build_args
    build_args=$(get_build_args "$version")

    # Prepare tags
    local tag_args="-t $ghcr_image:$effective_tag"

    # For multi-platform local builds (no suffix), also tag as latest if requested
    if [[ -z "$platform_suffix" && "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $ghcr_image:latest"
    fi

    log_success "Image: $ghcr_image:$effective_tag"
    log_success "Platform: $platforms"
    log_success "Build args: $build_args"

    # Build and push with retry
    retry_with_backoff 3 5 docker buildx build \
        --platform "$platforms" \
        --push \
        --provenance=false \
        $build_args \
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
# This CAN fail without failing the overall build
push_dockerhub() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local wanted="$4"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local dockerhub_image="docker.io/$github_username/$container"

    log_success "=== Pushing to Docker Hub (secondary registry) ==="

    # Get platform configuration (sets PLATFORM_CONFIG_* globals)
    get_platform_config "$tag"
    local platforms="$PLATFORM_CONFIG_PLATFORMS"
    local platform_suffix="$PLATFORM_CONFIG_SUFFIX"
    local effective_tag="$PLATFORM_CONFIG_EFFECTIVE_TAG"

    # Prepare build arguments
    local build_args
    build_args=$(get_build_args "$version")

    # Prepare tags
    local tag_args="-t $dockerhub_image:$effective_tag"

    # For multi-platform local builds (no suffix), also tag as latest if requested
    if [[ -z "$platform_suffix" && "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest"
    fi

    log_success "Image: $dockerhub_image:$effective_tag"
    log_success "Platform: $platforms"
    log_success "Build args: $build_args"

    # Build and push with retry (more attempts for Docker Hub as it's less reliable)
    retry_with_backoff 5 10 docker buildx build \
        --platform "$platforms" \
        --push \
        --provenance=false \
        $build_args \
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
