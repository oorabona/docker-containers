#!/usr/bin/env bash

# Container build utility - focused on building containers only
# Part of make script decomposition for better Single Responsibility

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"

# Function to check if multi-platform builds are supported (QEMU emulation)
check_multiplatform_support() {
    # Cache the result to avoid repeated checks
    if [[ -n "${MULTIPLATFORM_SUPPORTED:-}" ]]; then
        return $([ "$MULTIPLATFORM_SUPPORTED" = "true" ] && echo 0 || echo 1)
    fi
    
    # Method 1: Check for QEMU ARM64 emulation via binfmt_misc
    if [[ -f "/proc/sys/fs/binfmt_misc/qemu-aarch64" ]] || 
       [[ -f "/proc/sys/fs/binfmt_misc/qemu-arm64" ]]; then
        MULTIPLATFORM_SUPPORTED="true"
        return 0
    fi
    
    # Method 2: Check docker buildx supported platforms  
    if command -v docker >/dev/null 2>&1; then
        local platforms
        if platforms=$(docker buildx inspect --bootstrap 2>/dev/null | grep -i "platforms:" 2>/dev/null); then
            if echo "$platforms" | grep -q "linux/arm64"; then
                MULTIPLATFORM_SUPPORTED="true"
                return 0
            fi
        fi
    fi
    
    # No multi-platform support found
    MULTIPLATFORM_SUPPORTED="false"
    return 1
}

# Build container function
build_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    
    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local dockerhub_image="docker.io/$github_username/$container"
    local ghcr_image="ghcr.io/$github_username/$container"
    
    # Determine platform support
    local platforms
    if check_multiplatform_support; then
        platforms="linux/amd64,linux/arm64"
    else
        platforms="linux/amd64"
    fi
    
    # Detect container runtime for cache compatibility
    local cache_args=""
    local runtime_info=""
    
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        # GitHub Actions: always use Docker with GHA cache
        cache_args="--cache-from type=gha --cache-to type=gha,mode=max"
        runtime_info="GitHub Actions (Docker)"
    elif docker version 2>/dev/null | grep -q "Docker Engine"; then
        # Local Docker: supports GitHub Actions cache
        cache_args="--cache-from type=gha --cache-to type=gha,mode=max"
        runtime_info="Docker Engine"
    elif command -v podman >/dev/null 2>&1; then
        # Podman: has built-in layer caching
        cache_args=""
        runtime_info="Podman"
        log_success "Using Podman with built-in layer caching"
    else
        # Fallback: no cache
        cache_args=""
        runtime_info="Unknown (no cache)"
        log_warning "No cache support detected"
    fi
    
    # Prepare build arguments
    local build_args=""
    [[ -n "$version" ]] && build_args="$build_args --build-arg VERSION=$version"
    [[ -n "$NPROC" ]] && build_args="$build_args --build-arg NPROC=$NPROC"
    [[ -n "$CUSTOM_BUILD_ARGS" ]] && build_args="$build_args $CUSTOM_BUILD_ARGS"
    
    # Prepare tags
    local tag_args="-t $dockerhub_image:$tag -t $ghcr_image:$tag"
    if [[ "$tag" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest -t $ghcr_image:latest"
    fi
    
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        # GitHub Actions: skip separate build step, use push instead
        log_success "GitHub Actions detected - using direct push workflow..."
        log_success "Skipping separate build step (will build and push in one operation)"
        return 0
    else
        # Local development: single platform with --load
        log_success "Building $container:$tag locally (layered image)..."
        log_success "Runtime: $runtime_info | Platform: linux/amd64 | Cache: ${cache_args:-none}"
        
        docker buildx build \
            --platform linux/amd64 \
            --load \
            $cache_args \
            $build_args \
            $tag_args \
            . || {
            log_error "Build failed for $container:$tag"
            return 1
        }
        
        log_success "✅ Local build completed - layered image available in Docker daemon"
    fi
}

# Export functions for use by make script
export -f check_multiplatform_support
export -f build_container
