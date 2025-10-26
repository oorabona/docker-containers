#!/usr/bin/env bash

# Container build utility - simplified using docker compose
# Part of make script decomposition for better Single Responsibility

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"

# Build container function using docker compose
build_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    
    log_info "Building $container:$tag using docker compose..."
    
    # Ensure we have a docker-compose.yml in current directory
    if [[ ! -f "docker-compose.yml" ]]; then
        log_error "No docker-compose.yml found in $(pwd)"
        return 1
    fi
    
    # Export variables for docker-compose
    export VERSION="$version"
    export TAG="$tag" 
    export NPROC="${NPROC:-$(nproc)}"
    # Fixed namespace: oorabona/ (no variable needed)
    export DOCKER_BUILDKIT=1  # Enable BuildKit for multi-platform support
    
    # Export custom build args if they exist (e.g., for PostgreSQL)
    if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
        # Parse CUSTOM_BUILD_ARGS and export as environment variables
        # Convert "--build-arg KEY=VALUE" to "export KEY=VALUE"
        eval "$(echo "$CUSTOM_BUILD_ARGS" | sed -E 's/--build-arg ([^=]+)=([^ ]+)/export \1="\2";/g')"
    fi
    
    # Check if container has docker-compose.yml
    if [[ -f "docker-compose.yml" ]]; then
        log_info "Using container-specific docker-compose.yml"
        
        # Build using docker compose (handles platforms, cache, etc.)
        # Force rebuild without cache for Podman compatibility
        if docker compose build --no-cache; then
            log_success "✅ Docker compose build completed for $container:$tag"
            
            # Get the expected image name from docker-compose configuration
            local expected_image
            expected_image=$(docker compose config --format json | jq -r '.services | to_entries[0].value.image // empty')
            
            # Find the actual built image (podman/docker often tags differently)
            # Look for all possible image names that podman/docker might create
            local actual_images=(
                "localhost/$container:$version"
                "docker.io/library/$container:$version" 
                "$container:$version"
            )
            
            local found_image=""
            for img in "${actual_images[@]}"; do
                if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$img$"; then
                    found_image="$img"
                    log_info "Found built image: $found_image"
                    break
                fi
            done
            
            # Re-tag with correct namespace if an image was found
            if [[ -n "$found_image" && -n "$expected_image" ]]; then
                log_info "Re-tagging $found_image -> $expected_image"
                docker tag "$found_image" "$expected_image" || log_warning "Failed to re-tag image"
                
                # Also create the standard oorabona namespace tag
                local standard_tag="oorabona/$container:$version"
                if [[ "$standard_tag" != "$expected_image" ]]; then
                    log_info "Creating standard tag: $standard_tag"
                    docker tag "$found_image" "$standard_tag" || log_warning "Failed to create standard tag"
                fi
            fi
            
            # Tag the built image with version if different from 'latest'
            if [[ "$tag" != "latest" && "$tag" != "$version" ]]; then
                if [[ -n "$expected_image" ]]; then
                    docker tag "$expected_image" "${expected_image%:*}:$tag" || log_warning "Failed to tag image with $tag"
                fi
            fi
        else
            log_error "Docker compose build failed for $container"
            return 1
        fi
    else
        log_warning "No docker-compose.yml found, falling back to direct docker build"
        
        # Fallback for containers without compose file
        local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
        local image_name="${DOCKER_REGISTRY:-}$github_username/$container:$tag"
        
        if docker build -t "$image_name" .; then
            log_success "✅ Direct docker build completed for $container:$tag"
        else
            log_error "Direct docker build failed for $container"
            return 1
        fi
    fi
    
    return 0
}

# Export function for use by make script
export -f build_container
