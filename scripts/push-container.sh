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

# Count distinct linux/* platforms from "docker buildx imagetools inspect" output.
# Shared by both _guard_local_single_arch_push and _ghcr_source_is_single_arch.
# Prints the count; returns 0 on success, 1 if inspect failed (tag absent /
# registry unreachable).
_count_linux_platforms() {
    local ref="$1"

    local inspect_out
    inspect_out=$($DOCKER buildx imagetools inspect "$ref" 2>&1) || return 1

    printf '%s\n' "$inspect_out" \
        | grep -oE 'linux/(amd64|arm64|arm/v[0-9]+|386|s390x|ppc64le|riscv64)' \
        | sort -u \
        | wc -l
}

# Returns 0 (true) if the ref is confirmed multi-arch (>1 linux/* platforms).
# Returns 1 (false) for single-arch, absent, or any probe failure.
# Used to decide whether a skopeo --all copy is safe to skip the target guard:
# only a positively-confirmed multi-arch GHCR source is safe to mirror without
# guarding the target (it faithfully reproduces multi-arch on the destination).
# Any uncertainty — including probe failure — falls through to the target guard.
_ghcr_source_is_multiarch() {
    local ref="$1"

    local count
    count=$(_count_linux_platforms "$ref") || return 1

    [[ "$count" -gt 1 ]]
}

# Guard against a local single-arch bare-tag push clobbering a published
# multi-arch OCI image index.  Only fires when ALL of these are true:
#   - Running outside CI (GITHUB_ACTIONS unset or not "true")
#   - Single-arch local build (platform_suffix is empty, no QEMU)
#   - ALLOW_MULTIARCH_CLOBBER is NOT set to 1 or true
# Probes the target ref with "docker buildx imagetools inspect".
# Fail-open: if the ref is absent or the registry is unreachable the push is
# allowed.  Only a positively-confirmed multi-platform manifest blocks.
# Returns: 0 = safe to push, 1 = blocked (clobber detected)
_guard_local_single_arch_push() {
    local ref="$1"

    # No-op in CI
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        return 0
    fi

    # Override: operator explicitly allows the clobber
    if [[ "${ALLOW_MULTIARCH_CLOBBER:-0}" == "1" || "${ALLOW_MULTIARCH_CLOBBER:-}" == "true" ]]; then
        log_warning "ALLOW_MULTIARCH_CLOBBER override active — skipping multi-arch clobber guard for $ref"
        return 0
    fi

    # Count distinct non-unknown linux/* platform entries reported by inspect.
    local platform_count
    platform_count=$(_count_linux_platforms "$ref") || {
        # inspect failed — tag absent or registry unreachable; fail-open
        return 0
    }

    if [[ "$platform_count" -gt 1 ]]; then
        log_error "REFUSED: $ref is a multi-platform manifest ($platform_count platforms)."
        log_error "A local single-arch push would overwrite the multi-arch OCI index"
        log_error "and break consumers on the other architecture(s)."
        log_error "Escape hatches:"
        log_error "  (a) Let CI publish the canonical tag via GitHub Actions."
        log_error "  (b) Push to a namespace you own: GITHUB_REPOSITORY_OWNER=<you> ./make push ..."
        log_error "  (c) Override intentionally:   ALLOW_MULTIARCH_CLOBBER=1 ./make push ..."
        return 1
    fi

    # Single-arch or empty manifest — no clobber risk
    return 0
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

# Prepare common build arguments (delegates to shared prepare_build_args)
get_build_args() {
    local version="$1"
    prepare_build_args "$version" "" || return 1
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
    build_args=$(get_build_args "$version") || {
        log_error "build arg preparation failed (invalid build_args/cache config); aborting GHCR push"
        return 1
    }
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

    # Guard: refuse if a local single-arch push would clobber a multi-arch tag.
    # Fires only when ALL of:
    #   - no arch suffix (bare-tag path)
    #   - single-arch build (not the QEMU multi-platform linux/amd64,linux/arm64 path)
    # Probes every tag that will be pushed (effective_tag and, when wanted=latest, :latest).
    if [[ -z "$platform_suffix" && "$platforms" == "linux/amd64" ]]; then
        _guard_local_single_arch_push "$ghcr_image:$effective_tag" || return 1
        if [[ "$wanted" == "latest" ]]; then
            _guard_local_single_arch_push "$ghcr_image:latest" || return 1
        fi
    fi

    # Build and push with retry (includes cache update)
    retry_with_backoff 3 5 $DOCKER buildx build \
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
    if [[ "${SQUASH_IMAGE:-false}" == "true" && -z "$platform_suffix" && "${DRY_RUN:-false}" != "true" ]]; then
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

        # Source-aware clobber guard for the skopeo path:
        # skopeo copy --all mirrors whatever the GHCR source contains.  When
        # the GHCR source is single-arch (or when the source probe fails for
        # any reason) and the Docker Hub target is currently multi-arch, --all
        # would overwrite the multi-arch index with a single-arch image.
        # Apply the target guard unless the GHCR source is positively confirmed
        # to be multi-arch (the only case where --all is a safe faithful mirror).
        # Fail-closed on probe failure: uncertainty about the source defaults
        # to guarding the target.
        if ! _ghcr_source_is_multiarch "$ghcr_image:$effective_tag"; then
            _guard_local_single_arch_push "$dockerhub_image:$effective_tag" || return 1
        fi

        # Copy the tagged image
        if retry_with_backoff 5 10 $SKOPEO copy \
            --all \
            "docker://$ghcr_image:$effective_tag" \
            "docker://$dockerhub_image:$effective_tag"; then

            log_success "Docker Hub push via skopeo: $dockerhub_image:$effective_tag"

            # Also copy as :latest if requested
            if [[ "$wanted" == "latest" ]]; then
                # Guard the :latest target unless the GHCR source is confirmed multi-arch
                if ! _ghcr_source_is_multiarch "$ghcr_image:$effective_tag"; then
                    _guard_local_single_arch_push "$dockerhub_image:latest" || return 1
                fi
                $SKOPEO copy --all \
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
    build_args=$(get_build_args "$version") || {
        log_error "build arg preparation failed (invalid build_args/cache config); aborting Docker Hub push"
        return 1
    }
    local label_args
    label_args=$(get_label_args)

    local tag_args="-t $dockerhub_image:$effective_tag"
    if [[ -z "$platform_suffix" && "$wanted" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest"
    fi

    local cache_args="--cache-from type=registry,ref=$cache_image"

    log_success "Image: $dockerhub_image:$effective_tag"
    log_success "Platform: $platforms"

    # Guard: a local single-arch buildx fallback must not overwrite a published
    # multi-arch Docker Hub tag (mirrors the GHCR guard in push_ghcr). Fires only
    # on the bare-tag single-arch local path; no-op in CI and the QEMU multi-arch path.
    if [[ -z "$platform_suffix" && "$platforms" == "linux/amd64" ]]; then
        _guard_local_single_arch_push "$dockerhub_image:$effective_tag" || return 1
        if [[ "$wanted" == "latest" ]]; then
            _guard_local_single_arch_push "$dockerhub_image:latest" || return 1
        fi
    fi

    retry_with_backoff 5 10 $DOCKER buildx build \
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
    if [[ "${SQUASH_IMAGE:-false}" == "true" && -z "$platform_suffix" && "${DRY_RUN:-false}" != "true" ]]; then
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
