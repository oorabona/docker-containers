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
source "$PROJECT_ROOT/helpers/build-cache-utils.sh"
source "$PROJECT_ROOT/helpers/build-args-utils.sh"
source "$PROJECT_ROOT/helpers/extension-utils.sh"

# Function to check if multi-platform builds are supported (QEMU emulation)
check_multiplatform_support() {
    # Cache the result to avoid repeated checks
    if [[ -n "${MULTIPLATFORM_SUPPORTED:-}" ]]; then
        [[ "$MULTIPLATFORM_SUPPORTED" = "true" ]] && return 0 || return 1
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

# Resolve build platforms based on environment and capabilities
# Sets: _PLATFORMS
_resolve_platforms() {
    if [[ -n "${BUILD_PLATFORM:-}" ]]; then
        _PLATFORMS="$BUILD_PLATFORM"
        log_success "Using native platform: $_PLATFORMS"
    elif check_multiplatform_support; then
        _PLATFORMS="linux/amd64,linux/arm64"
    else
        _PLATFORMS="linux/amd64"
    fi
}

# Configure build cache based on runtime environment
# Sets: _CACHE_ARGS, _RUNTIME_INFO
_configure_cache() {
    local cache_image="$1"

    _CACHE_ARGS=""
    _RUNTIME_INFO=""

    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        _CACHE_ARGS="--cache-from type=registry,ref=$cache_image --cache-to type=registry,ref=$cache_image,mode=max"
        _RUNTIME_INFO="GitHub Actions (registry cache)"
        log_success "Using registry cache: $cache_image"
    elif docker version 2>/dev/null | grep -q "Docker Engine"; then
        if docker pull "$cache_image" 2>/dev/null; then
            _CACHE_ARGS="--cache-from type=registry,ref=$cache_image"
            _RUNTIME_INFO="Docker Engine (registry cache)"
        else
            _RUNTIME_INFO="Docker Engine (no cache - login to GHCR for cache)"
        fi
    elif command -v podman >/dev/null 2>&1; then
        _RUNTIME_INFO="Podman"
        log_success "Using Podman with built-in layer caching"
    else
        _RUNTIME_INFO="Unknown (no cache)"
        log_warning "No cache support detected"
    fi
}

# Prepare all build arguments from version, flavor, config, and environment
# Sets: _BUILD_ARGS, _MAJOR_VERSION, _UPSTREAM_VERSION
_prepare_build_args() {
    local version="$1"
    local flavor="$2"

    _BUILD_ARGS=""
    [[ -n "$version" ]] && _BUILD_ARGS="--build-arg VERSION=$version"

    _MAJOR_VERSION=$(echo "$version" | grep -oE '^[0-9]+' | head -1 || true)
    [[ -n "$_MAJOR_VERSION" ]] && _BUILD_ARGS="$_BUILD_ARGS --build-arg MAJOR_VERSION=$_MAJOR_VERSION"

    _UPSTREAM_VERSION=""
    if [[ -f "./version.sh" ]]; then
        _UPSTREAM_VERSION=$(./version.sh --upstream 2>/dev/null || true)
        if [[ -n "$_UPSTREAM_VERSION" && "$_UPSTREAM_VERSION" != "$version" ]]; then
            _BUILD_ARGS="$_BUILD_ARGS --build-arg UPSTREAM_VERSION=$_UPSTREAM_VERSION"
        fi
    fi

    [[ -n "$flavor" ]] && _BUILD_ARGS="$_BUILD_ARGS --build-arg FLAVOR=$flavor"
    [[ -n "${NPROC:-}" ]] && _BUILD_ARGS="$_BUILD_ARGS --build-arg NPROC=$NPROC"

    local config_build_args
    config_build_args=$(build_args_flags ".")
    if [[ -n "$config_build_args" ]]; then
        _BUILD_ARGS="$_BUILD_ARGS $config_build_args"
        log_info "Loaded build args from config.yaml"
    fi

    if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
        _BUILD_ARGS="$_BUILD_ARGS $CUSTOM_BUILD_ARGS"
    fi
}

# Resolve base image reference from config.yaml or Dockerfile, substitute variables
# Sets: _BASE_IMAGE_REF, _BASE_DIGEST, adds to label_args
_resolve_base_image() {
    local dockerfile="$1"
    local version="$2"
    local label_args_var="$3"  # name of the label_args variable to append to

    _BASE_IMAGE_REF=""
    if [[ -f "./config.yaml" ]]; then
        _BASE_IMAGE_REF=$(yq -r '.base_image // ""' ./config.yaml 2>/dev/null || true)
    fi
    if [[ -z "$_BASE_IMAGE_REF" ]]; then
        _BASE_IMAGE_REF=$(grep -E '^FROM ' "$dockerfile" | grep -v ' AS ' | tail -1 | awk '{print $2}' || true)
        [[ -z "$_BASE_IMAGE_REF" ]] && _BASE_IMAGE_REF=$(grep -E '^FROM ' "$dockerfile" | tail -1 | awk '{print $2}' || true)
    fi

    # Substitute known variables into the base image template
    if [[ "$_BASE_IMAGE_REF" =~ \$ ]]; then
        _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{VERSION\}/$version}"
        _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$VERSION/$version}"
        [[ -n "${_MAJOR_VERSION:-}" ]] && _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{MAJOR_VERSION\}/$_MAJOR_VERSION}"
        [[ -n "${_UPSTREAM_VERSION:-}" ]] && _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{UPSTREAM_VERSION\}/$_UPSTREAM_VERSION}"
        # Resolve Dockerfile ARG defaults (e.g. ARG BASE_IMAGE=postgres)
        while IFS= read -r arg_line; do
            local arg_name="${arg_line%%=*}"
            local arg_default="${arg_line#*=}"
            arg_default="${arg_default%\"}"
            arg_default="${arg_default#\"}"
            arg_default="${arg_default%\'}"
            arg_default="${arg_default#\'}"
            [[ -z "$arg_name" || "$arg_name" == "$arg_line" ]] && continue
            if [[ "$_BASE_IMAGE_REF" == *"\${$arg_name}"* || "$_BASE_IMAGE_REF" == *"\$$arg_name"* ]]; then
                _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{$arg_name\}/$arg_default}"
                _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$$arg_name/$arg_default}"
            fi
        done < <(grep -E '^ARG [A-Z_]+=' "$dockerfile" | sed 's/^ARG //' || true)
        if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
            while read -r arg_val; do
                local arg_name="${arg_val%%=*}"
                local arg_value="${arg_val#*=}"
                _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$\{$arg_name\}/$arg_value}"
                _BASE_IMAGE_REF="${_BASE_IMAGE_REF//\$$arg_name/$arg_value}"
            done < <(echo "$CUSTOM_BUILD_ARGS" | grep -oP '(?<=--build-arg )\S+' || true)
        fi
    fi

    # Resolve digest if we have a concrete image reference
    _BASE_DIGEST=""
    if [[ -n "$_BASE_IMAGE_REF" && ! "$_BASE_IMAGE_REF" =~ \$ ]]; then
        _BASE_DIGEST=$(docker manifest inspect "$_BASE_IMAGE_REF" 2>/dev/null | grep -o '"sha256:[a-f0-9]*"' | head -1 | tr -d '"' || true)
        if [[ -n "$_BASE_DIGEST" ]]; then
            eval "$label_args_var=\"\$$label_args_var --label org.opencontainers.image.base.digest=\$_BASE_DIGEST\""
            log_info "Base image $_BASE_IMAGE_REF pinned: ${_BASE_DIGEST:0:19}..."
        fi
    fi
}

# Emit build lineage JSON for traceability
_emit_build_lineage() {
    local container="$1" version="$2" tag="$3" flavor="$4" dockerfile="$5"
    local platforms="$6" runtime_info="$7" dockerhub_image="$8" ghcr_image="$9"

    local lineage_dir="${PROJECT_ROOT:-.}/.build-lineage"
    mkdir -p "$lineage_dir"
    local lineage_file="$lineage_dir/${container}${flavor:+-$flavor}.json"
    local build_ts
    build_ts=$(date -Iseconds)
    local image_id
    image_id=$(docker images --no-trunc -q "$dockerhub_image:$tag" 2>/dev/null | head -1 || true)

    local build_args_json="{}"
    if [[ -f "./config.yaml" ]]; then
        build_args_json=$(yq -r '(.build_args // {}) | to_entries | map("\"" + .key + "\": \"" + .value + "\"") | join(",") | "{" + . + "}"' ./config.yaml 2>/dev/null || true)
        [[ -z "$build_args_json" || "$build_args_json" == "{}" ]] && build_args_json="{}"
    fi

    cat > "$lineage_file" <<LINEAGE_EOF
{
  "container": "$container",
  "version": "$version",
  "tag": "$tag",
  "flavor": "${flavor:-}",
  "dockerfile": "$dockerfile",
  "platform": "$platforms",
  "runtime": "$runtime_info",
  "image_id": "${image_id:-unknown}",
  "build_digest": "${BUILD_DIGEST:-unknown}",
  "base_image_ref": "${_BASE_IMAGE_REF:-unknown}",
  "base_image_digest": "${_BASE_DIGEST:-unresolved}",
  "built_at": "$build_ts",
  "github_actions": ${GITHUB_ACTIONS:-false},
  "images": {
    "dockerhub": "$dockerhub_image:$tag",
    "ghcr": "$ghcr_image:$tag"
  },
  "build_args": $build_args_json
}
LINEAGE_EOF
    log_info "Build lineage: $lineage_file"
}

# Build container function
# Usage: build_container <container> <version> <tag> [flavor] [dockerfile]
# If flavor is provided, it's passed as --build-arg FLAVOR=<flavor>
# If dockerfile is provided, uses -f <dockerfile> instead of default Dockerfile
build_container() {
    local container="$1"
    local version="$2"
    local tag="$3"
    local flavor="${4:-}"
    local dockerfile="${5:-Dockerfile}"

    local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
    local dockerhub_image="docker.io/$github_username/$container"
    local ghcr_image="ghcr.io/$github_username/$container"

    # Reset BUILD_DIGEST so each variant computes its own
    unset BUILD_DIGEST

    # Smart rebuild detection: skip if image exists with matching digest
    if [[ "${SKIP_EXISTING_BUILDS:-false}" == "true" && "${FORCE_REBUILD:-false}" != "true" ]]; then
        if should_skip_build "$ghcr_image:$tag" "$dockerfile" "$flavor" "false"; then
            log_success "⏭️  Skipping $container:$tag - image exists with matching digest"
            return 0
        fi
        log_info "Build digest: $BUILD_DIGEST"
    fi

    _resolve_platforms
    _configure_cache "ghcr.io/$github_username/$container:buildcache"
    _prepare_build_args "$version" "$flavor"

    # Prepare tags
    local tag_args="-t $dockerhub_image:$tag -t $ghcr_image:$tag"
    if [[ "$tag" == "latest" ]]; then
        tag_args="$tag_args -t $dockerhub_image:latest -t $ghcr_image:latest"
    fi

    # Compute build digest label for smart rebuild detection
    local label_args=""
    if [[ -z "${BUILD_DIGEST:-}" ]]; then
        BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$flavor")
    fi
    label_args="--label $BUILD_DIGEST_LABEL=$BUILD_DIGEST"

    _resolve_base_image "$dockerfile" "$version" "label_args"

    # Generate Dockerfile from template if it contains extension markers
    local _generated_dockerfile=""
    if grep -q '@@EXTENSION_STAGES@@' "$dockerfile" 2>/dev/null; then
        local ext_config="$PROJECT_ROOT/$container/extensions/config.yaml"
        if [[ -f "$ext_config" ]]; then
            _generated_dockerfile=$(mktemp "${TMPDIR:-/tmp}/Dockerfile.${container}.XXXXXX") || {
                log_error "Failed to create temp file for generated Dockerfile"
                return 1
            }
            if ! generate_dockerfile "$ext_config" "$dockerfile" "${flavor:-base}" "$_MAJOR_VERSION" > "$_generated_dockerfile"; then
                log_error "Failed to generate Dockerfile for flavor=${flavor:-base} pg=$_MAJOR_VERSION"
                rm -f "$_generated_dockerfile"
                return 1
            fi
            log_info "Generated Dockerfile for flavor=${flavor:-base} pg=$_MAJOR_VERSION"
            dockerfile="$_generated_dockerfile"
        else
            log_error "Dockerfile has extension markers but no $ext_config found"
            return 1
        fi
    fi

    # Execute docker build
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log_success "GitHub Actions detected - building locally for validation..."
        log_success "Runtime: $_RUNTIME_INFO | Platform: $_PLATFORMS | Dockerfile: $dockerfile"

        docker buildx build \
            -f "$dockerfile" \
            --platform "$_PLATFORMS" \
            --load \
            $_CACHE_ARGS \
            $_BUILD_ARGS \
            $label_args \
            $tag_args \
            . || {
            log_error "Build failed for $container:$tag"
            [[ -n "$_generated_dockerfile" ]] && rm -f "$_generated_dockerfile"
            return 1
        }

        log_success "✅ Build completed - image loaded locally (no push)"
    else
        log_success "Building $container:$tag locally (Dockerfile: $dockerfile)..."
        log_success "Runtime: $_RUNTIME_INFO | Platform: $_PLATFORMS"

        docker buildx build \
            -f "$dockerfile" \
            --platform "$_PLATFORMS" \
            --load \
            --pull=never \
            $_CACHE_ARGS \
            $_BUILD_ARGS \
            $label_args \
            $tag_args \
            . || {
            log_error "Build failed for $container:$tag"
            [[ -n "$_generated_dockerfile" ]] && rm -f "$_generated_dockerfile"
            return 1
        }

        log_success "✅ Local build completed - layered image available in Docker daemon"
    fi

    _emit_build_lineage "$container" "$version" "$tag" "$flavor" "$dockerfile" \
        "$_PLATFORMS" "$_RUNTIME_INFO" "$dockerhub_image" "$ghcr_image"

    # Cleanup generated Dockerfile
    [[ -n "$_generated_dockerfile" ]] && rm -f "$_generated_dockerfile"
}

# Build all variants for a container
# Usage: build_container_variants <container> <major_version> [specific_variant]
# If specific_variant is provided, only that variant is built
# Returns JSON array of built variants for CI consumption
#
# Flow:
#   1. major_version = "17" (passed directly, no extraction needed)
#   2. base_image = "<container>:17-alpine" (major_version + base_suffix)
#   3. output_tag = "17-full-alpine" (major_version + variant_suffix + base_suffix)
build_container_variants() {
    local container="$1"
    local major_version="$2"
    local specific_variant="${3:-}"
    local container_dir="$PROJECT_ROOT/$container"

    # Check if container has variants
    if ! has_variants "$container_dir"; then
        log_info "$container has no variants, building single image..."
        local rc=0
        build_container "$container" "$major_version" "$major_version" || rc=$?
        echo "[{\"name\":\"default\",\"tag\":\"$major_version\",\"flavor\":\"\",\"status\":\"built\"}]"
        return $rc
    fi

    # Get base suffix from variants.yaml (e.g., "-alpine")
    local base_sfx
    base_sfx=$(base_suffix "$container_dir")

    # Get custom dockerfile for this version (if any)
    local dockerfile
    dockerfile=$(version_dockerfile "$container_dir" "$major_version")
    [[ -z "$dockerfile" ]] && dockerfile="Dockerfile"

    # Construct the base image version for FROM statement (e.g., "17-alpine")
    local base_image_version="${major_version}${base_sfx}"

    log_info "$container has variants, building multiple images..."
    log_info "Major version: $major_version | Base version: $base_image_version | Dockerfile: $dockerfile"

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

        # Build the variant - pass base_image_version (e.g., "17-alpine") and dockerfile
        local status="built"
        if ! build_container "$container" "$base_image_version" "$variant_tag" "$flavor" "$dockerfile"; then
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
