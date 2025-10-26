#!/usr/bin/env bash

# Container push utility - focused on pushing containers to registries
# Part of make script decomposition for better Single Responsibility

# Source shared logging utilities  
source "$(dirname "$0")/helpers/logging.sh"

# Source build utilities for platform detection
source "$(dirname "$0")/scripts/build-container.sh"

# Push container function - re-tag and push existing local image
push_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local wanted="$4"
    
    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"  
    local local_image="oorabona/$container:$version"
    local dockerhub_image="docker.io/$github_username/$container"
    local ghcr_image="ghcr.io/$github_username/$container"
    
    log_info "Building and pushing $container:$tag to registries (multi-platform)..."
    
    # Check if local image exists for reference
    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$local_image$"; then
        log_warning "Local image $local_image not found. Building from scratch..."
    else
        log_info "Using local image $local_image as reference for build"
    fi
    
    # Determine platform support
    local platforms
    if check_multiplatform_support; then
        platforms="linux/amd64,linux/arm64"
        log_info "Building for multiple platforms: AMD64 + ARM64"
    else
        platforms="linux/amd64"
        log_info "Building for single platform: AMD64 only"
    fi
    
    # Detect container runtime for caching
    local cache_args=""
    local is_docker=false
    local runtime_info=""
    
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        cache_args="--cache-from type=gha --cache-to type=gha,mode=max"
        is_docker=true
        runtime_info="GitHub Actions (Docker)"
    elif docker version 2>/dev/null | grep -q "Docker Engine"; then
        cache_args="--cache-from type=gha --cache-to type=gha,mode=max"
        is_docker=true  
        runtime_info="Docker Engine"
    elif command -v podman >/dev/null 2>&1; then
        cache_args=""
        is_docker=false
        runtime_info="Podman"
    else
        cache_args=""
        is_docker=false
        runtime_info="Unknown (no cache)"
    fi
    
    log_info "Runtime: $runtime_info | Platforms: $platforms"
    
    # Prepare build arguments (get from current environment)
    local build_args=""
    [[ -n "$version" ]] && build_args="$build_args --build-arg VERSION=$version"
    [[ -n "$NPROC" ]] && build_args="$build_args --build-arg NPROC=$NPROC"
    [[ -n "$CUSTOM_BUILD_ARGS" ]] && build_args="$build_args $CUSTOM_BUILD_ARGS"
    
    # Add any build args from .env if it exists
    if [[ -f ".env" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] || [[ -z "$key" ]] && continue
            # Add build args for extension versions and postgres settings
            if [[ "$key" =~ ^(POSTGRES_|PG|SHARED_PRELOAD_LIBRARIES) ]]; then
                build_args="$build_args --build-arg $key=$value"
            fi
        done < .env
    fi
    
    # Prepare tags - include "latest" if building latest version
    local tag_args="-t $dockerhub_image:$tag -t $ghcr_image:$tag"
    if [[ "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest -t $ghcr_image:latest"
    fi
    
    # Build and push using docker buildx (supports multi-platform)
    log_info "Building and pushing with docker buildx..."
    docker buildx build \
        --platform "$platforms" \
        --push \
        $cache_args \
        $build_args \
        $tag_args \
        . || {
        log_error "Multi-platform build and push failed for $container:$tag"
        return 1
    }
    
    # Optional squashing (enabled by default for cleaner images)
    if [[ "${SQUASH_IMAGE:-true}" == "true" ]]; then
        log_success "Replacing with squashed versions for cleaner distribution..."
        
        # Replace layered with squashed (same tag) - using relative path to helpers
        ../helpers/skopeo-squash "$dockerhub_image:$tag" "$dockerhub_image:$tag" dockerhub || {
            log_warning "Docker Hub squashing failed, keeping layered version"
        }
        
        ../helpers/skopeo-squash "$ghcr_image:$tag" "$ghcr_image:$tag" ghcr || {
            log_warning "GHCR squashing failed, keeping layered version"
        }
        
        # Handle latest tags if they exist
        if [[ "$wanted" == "latest" ]]; then
            ../helpers/skopeo-squash "$dockerhub_image:latest" "$dockerhub_image:latest" dockerhub || {
                log_warning "Docker Hub latest squashing failed, keeping layered version"
            }
            ../helpers/skopeo-squash "$ghcr_image:latest" "$ghcr_image:latest" ghcr || {
                log_warning "GHCR latest squashing failed, keeping layered version"
            }
        fi
        
        log_success "✅ Published squashed images to registries"
    else
        log_success "✅ Published layered images to registries (squashing disabled)"
    fi
}

# Export function for use by make script
export -f push_container
