#!/usr/bin/env bash

# Container build utility - focused on building containers only
# Part of make script decomposition for better Single Responsibility
# Supports multi-variant containers via variants.yaml

# Source shared logging utilities
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/helpers/logging.sh"
source "$PROJECT_ROOT/helpers/variant-utils.sh"

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
# Usage: build_container <container> <version> <tag> [flavor]
# If flavor is provided, it's passed as --build-arg FLAVOR=<flavor>
build_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local flavor="${4:-}"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local dockerhub_image="docker.io/$github_username/$container"
    local ghcr_image="ghcr.io/$github_username/$container"

    # Use BUILD_PLATFORM if set (native CI runners), otherwise detect
    local platforms
    if [[ -n "${BUILD_PLATFORM:-}" ]]; then
        platforms="$BUILD_PLATFORM"
        log_success "Using native platform: $platforms"
    elif check_multiplatform_support; then
        platforms="linux/amd64,linux/arm64"
    else
        platforms="linux/amd64"
    fi
    
    # Detect container runtime for cache compatibility
    local cache_args=""
    local runtime_info=""
    local cache_image="ghcr.io/$github_username/$container:buildcache"

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        # GitHub Actions: use registry cache (persists across workflows)
        # Registry cache is more reliable than GHA cache for multi-platform builds
        # mode=max stores all layers, not just final image layers
        cache_args="--cache-from type=registry,ref=$cache_image --cache-to type=registry,ref=$cache_image,mode=max"
        runtime_info="GitHub Actions (registry cache)"
        log_success "Using registry cache: $cache_image"
    elif docker version 2>/dev/null | grep -q "Docker Engine"; then
        # Local Docker: try registry cache if logged in, otherwise inline cache
        if docker pull "$cache_image" 2>/dev/null; then
            cache_args="--cache-from type=registry,ref=$cache_image"
            runtime_info="Docker Engine (registry cache)"
        else
            cache_args=""
            runtime_info="Docker Engine (no cache - login to GHCR for cache)"
        fi
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

    # Extract major version for extension image selection (e.g., "16-alpine" -> "16")
    local pg_major
    pg_major=$(echo "$version" | grep -oE '^[0-9]+' | head -1)
    [[ -n "$pg_major" ]] && build_args="$build_args --build-arg PG_MAJOR=$pg_major"

    # Get upstream version if container has version.sh with --upstream support
    # This separates download URL version from Docker tag version
    if [[ -f "./version.sh" ]]; then
        local upstream_version
        upstream_version=$(./version.sh --upstream 2>/dev/null || true)
        if [[ -n "$upstream_version" && "$upstream_version" != "$version" ]]; then
            build_args="$build_args --build-arg UPSTREAM_VERSION=$upstream_version"
        fi
    fi

    [[ -n "$flavor" ]] && build_args="$build_args --build-arg FLAVOR=$flavor"
    [[ -n "$NPROC" ]] && build_args="$build_args --build-arg NPROC=$NPROC"
    [[ -n "${CUSTOM_BUILD_ARGS:-}" ]] && build_args="$build_args $CUSTOM_BUILD_ARGS"
    
    # Prepare tags
    local tag_args="-t $dockerhub_image:$tag -t $ghcr_image:$tag"
    if [[ "$tag" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest -t $ghcr_image:latest"
    fi
    
    # Build behavior depends on context
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        # GitHub Actions: build locally without pushing (use --load)
        # This ensures PR builds validate without polluting registries
        log_success "GitHub Actions detected - building locally for validation..."
        log_success "Runtime: $runtime_info | Platform: $platforms | Cache: ${cache_args:-none}"

        docker buildx build \
            --platform "$platforms" \
            --load \
            $cache_args \
            $build_args \
            $tag_args \
            . || {
            log_error "Build failed for $container:$tag"
            return 1
        }

        log_success "✅ Build completed - image loaded locally (no push)"
    else
        # Local development: single platform with --load
        # Images are pulled from registry if not available locally
        log_success "Building $container:$tag locally (layered image)..."
        log_success "Runtime: $runtime_info | Platform: $platforms | Cache: ${cache_args:-none}"

        docker buildx build \
            --platform "$platforms" \
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

# Build all variants for a container
# Usage: build_container_variants <container> <major_version> [specific_variant]
# If specific_variant is provided, only that variant is built
# Returns JSON array of built variants for CI consumption
#
# Flow:
#   1. major_version = "17" (passed directly, no extraction needed)
#   2. base_image = "postgres:17-alpine" (major_version + base_suffix)
#   3. output_tag = "17-full-alpine" (major_version + variant_suffix + base_suffix)
build_container_variants() {
    local container="$1"
    local major_version="$2"
    local specific_variant="${3:-}"
    local container_dir="$PROJECT_ROOT/$container"

    # Check if container has variants
    if ! has_variants "$container_dir"; then
        log_info "$container has no variants, building single image..."
        build_container "$container" "$major_version" "$major_version"
        echo "[{\"name\":\"default\",\"tag\":\"$major_version\",\"flavor\":\"\",\"status\":\"built\"}]"
        return $?
    fi

    # Get base suffix from variants.yaml (e.g., "-alpine")
    local base_sfx
    base_sfx=$(base_suffix "$container_dir")

    # Construct the base image version for FROM statement (e.g., "17-alpine")
    local base_image_version="${major_version}${base_sfx}"

    log_info "$container has variants, building multiple images..."
    log_info "Major version: $major_version | Base image: postgres:$base_image_version"

    local results="["
    local first=true
    local failed=false

    # Iterate through variants for this major version
    while IFS= read -r variant_name; do
        [[ -z "$variant_name" ]] && continue

        # Skip if specific variant requested and this isn't it
        if [[ -n "$specific_variant" && "$variant_name" != "$specific_variant" ]]; then
            continue
        fi

        local variant_tag
        variant_tag=$(variant_image_tag "$major_version" "$variant_name" "$container_dir")
        local flavor
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$major_version")
        local description
        description=$(variant_property "$container_dir" "$variant_name" "description" "$major_version")

        log_info "Building variant: $variant_name (tag: $variant_tag, flavor: $flavor)"

        # Build the variant - pass base_image_version (e.g., "17-alpine")
        local status="built"
        if ! build_container "$container" "$base_image_version" "$variant_tag" "$flavor"; then
            log_error "Failed to build variant: $variant_name"
            status="failed"
            failed=true
        else
            log_success "Built variant: $variant_name -> $container:$variant_tag"
        fi

        # Add to results
        if [[ "$first" != "true" ]]; then
            results+=","
        fi
        first=false

        results+="{\"name\":\"$variant_name\",\"tag\":\"$variant_tag\",\"flavor\":\"$flavor\",\"description\":\"$description\",\"status\":\"$status\"}"
    done < <(list_variants "$container_dir" "$major_version")

    results+="]"
    echo "$results"

    if [[ "$failed" == "true" ]]; then
        return 1
    fi
    return 0
}

# Check if a container has variants (wrapper for external use)
container_has_variants() {
    local container="$1"
    has_variants "$PROJECT_ROOT/$container"
}

# Get variant tags for a container (wrapper for external use)
get_container_variant_tags() {
    local container="$1"
    local base_version="$2"
    list_variant_tags "$PROJECT_ROOT/$container" "$base_version"
}

# Export functions for use by make script
export -f check_multiplatform_support
export -f build_container
export -f build_container_variants
export -f container_has_variants
export -f get_container_variant_tags
