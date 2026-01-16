#!/usr/bin/env bash

# Container push utility - focused on pushing containers to registries
# Part of make script decomposition for better Single Responsibility

# Source shared logging utilities  
source "$(dirname "$0")/helpers/logging.sh"

# Source build utilities for platform detection
source "$(dirname "$0")/scripts/build-container.sh"

# Push container function
push_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local wanted="$4"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local dockerhub_image="docker.io/$github_username/$container"
    local ghcr_image="ghcr.io/$github_username/$container"

    # Use BUILD_PLATFORM if set (native CI runners), otherwise detect
    local platforms
    local platform_suffix=""
    if [[ -n "${BUILD_PLATFORM:-}" ]]; then
        platforms="$BUILD_PLATFORM"
        # Extract arch from platform (e.g., linux/amd64 -> amd64)
        local arch="${platforms#linux/}"
        platform_suffix="-${arch}"
        log_success "Pushing $container:$tag$platform_suffix for native platform: $platforms"
    elif check_multiplatform_support; then
        platforms="linux/amd64,linux/arm64"
        log_success "Building and pushing $container:$tag (multi-platform: AMD64 + ARM64)..."
    else
        platforms="linux/amd64"
        log_success "Building and pushing $container:$tag (AMD64 only)..."
    fi
    
    # Detect container runtime
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
    
    log_success "Runtime: $runtime_info | Docker mode: $is_docker | Cache: ${cache_args:-none}"
    
    # Prepare build arguments
    local build_args=""
    [[ -n "$version" ]] && build_args="$build_args --build-arg VERSION=$version"
    [[ -n "$NPROC" ]] && build_args="$build_args --build-arg NPROC=$NPROC"
    [[ -n "$CUSTOM_BUILD_ARGS" ]] && build_args="$build_args $CUSTOM_BUILD_ARGS"
    
    # Prepare tags - use platform suffix for native CI builds to avoid overwrites
    local effective_tag="${tag}${platform_suffix}"
    local tag_args="-t $dockerhub_image:$effective_tag -t $ghcr_image:$effective_tag"

    # For multi-platform local builds (no suffix), also tag as latest if requested
    if [[ -z "$platform_suffix" && "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest -t $ghcr_image:latest"
    fi
    
    if [[ "$is_docker" == "true" ]]; then
        # Docker buildx: supports direct push
        log_success "Using Docker buildx with --push flag..."
        docker buildx build \
            --platform "$platforms" \
            --push \
            $cache_args \
            $build_args \
            $tag_args \
            . || {
            log_error "Push failed for $container:$tag"
            return 1
        }
    else
        # Podman: build then push separately
        log_success "Using Podman build + separate push..."
        docker buildx build \
            --platform "$platforms" \
            $cache_args \
            $build_args \
            $tag_args \
            . || {
            log_error "Build failed for $container:$tag"
            return 1
        }
        
        # Push each tag separately
        log_success "Pushing built images..."
        docker push "$dockerhub_image:$tag" || {
            log_error "Failed to push $dockerhub_image:$tag"
            return 1
        }
        docker push "$ghcr_image:$tag" || {
            log_error "Failed to push $ghcr_image:$tag"  
            return 1
        }
        
        # Push latest tags if they were created
        if [[ "$wanted" == "latest" ]]; then
            docker push "$dockerhub_image:latest" || {
                log_error "Failed to push $dockerhub_image:latest"
                return 1
            }
            docker push "$ghcr_image:latest" || {
                log_error "Failed to push $ghcr_image:latest"
                return 1
            }
        fi
    fi
    
    # Optional squashing (enabled by default for cleaner images)
    # Skip squashing for platform-specific tags (will be done on final manifest)
    if [[ "${SQUASH_IMAGE:-true}" == "true" && -z "$platform_suffix" ]]; then
        log_success "Replacing with squashed versions for cleaner distribution..."

        # Replace layered with squashed (same tag) - using relative path to helpers
        ../helpers/skopeo-squash "$dockerhub_image:$effective_tag" "$dockerhub_image:$effective_tag" dockerhub || {
            log_warning "Docker Hub squashing failed, keeping layered version"
        }

        ../helpers/skopeo-squash "$ghcr_image:$effective_tag" "$ghcr_image:$effective_tag" ghcr || {
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
    elif [[ -n "$platform_suffix" ]]; then
        log_success "✅ Published platform-specific image $effective_tag (squashing deferred to manifest)"
    else
        log_success "✅ Published layered images to registries (squashing disabled)"
    fi
}

# Export function for use by make script
export -f push_container
