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

# Debug logging for digest computation (silent unless DIGEST_DEBUG=1)
_digest_log() {
    if [[ "${DIGEST_DEBUG:-}" == "1" ]]; then
        log_info "$@"
    fi
}

# Compute a per-flavor build digest from source files
# Auto-detects container type from cwd and collects only the inputs
# relevant to the specified flavor.
#
# Container type detection (checked in order):
#   1. flavors/<flavor>.yaml exists → postgres-style (flavor file + extension versions)
#   2. variants.yaml with build_args_include → terraform-style (variant args from config.yaml)
#   3. config.yaml with build_args → simple container with versioned args
#   4. None of the above → Dockerfile-only
#
# Usage: compute_build_digest <dockerfile> <flavor>
# Returns: 12-char hex SHA256 prefix
#
# Note: CUSTOM_BUILD_ARGS is included in the digest if set.
# Do not pass secrets via CUSTOM_BUILD_ARGS — they will be hashed
# and logged when DIGEST_DEBUG=1.
compute_build_digest() {
    local dockerfile="$1"
    local flavor="${2:-}"

    local -a digest_inputs=()

    # --- Input 1: Dockerfile content ---
    if [[ -f "$dockerfile" ]]; then
        digest_inputs+=("FILE:Dockerfile=$(cat "$dockerfile")")
        _digest_log "  digest input: Dockerfile ($(wc -c < "$dockerfile") bytes)"
    else
        log_warning "  digest input: Dockerfile not found at $dockerfile"
        digest_inputs+=("FILE:Dockerfile=")
    fi

    # --- Detect container type and collect flavor-specific inputs ---

    if [[ -n "$flavor" && -f "flavors/${flavor}.yaml" ]]; then
        # TYPE 1: Postgres-style — flavor file + per-extension versions
        _digest_log "  digest type: postgres-style (flavors/${flavor}.yaml)"

        # Add flavor file content
        digest_inputs+=("FILE:flavor=$(cat "flavors/${flavor}.yaml")")
        _digest_log "  digest input: flavors/${flavor}.yaml"

        # Extract extension list from flavor file, get version for each
        local extensions
        if command -v yq &>/dev/null; then
            extensions=$(yq -r '.extensions[]' "flavors/${flavor}.yaml" 2>/dev/null || true)
        else
            log_warning "  yq not available, falling back to raw flavor file content"
            extensions=""
        fi

        if [[ -n "$extensions" && -f "extensions/config.yaml" ]]; then
            local ext_pairs=""
            local ext
            for ext in $extensions; do
                local version
                if command -v yq &>/dev/null; then
                    version=$(yq -r ".extensions.${ext}.version // \"unknown\"" "extensions/config.yaml" 2>/dev/null)
                else
                    version="unknown"
                fi
                if [[ "$version" == "unknown" ]]; then
                    log_warning "  extension '$ext' listed in flavors/${flavor}.yaml but not found in extensions/config.yaml"
                fi
                ext_pairs+="${ext}=${version}"$'\n'
                _digest_log "  digest input: ${ext}=${version}"
            done
            # Sort for determinism
            digest_inputs+=("$(echo -n "$ext_pairs" | sort)")
        fi

    elif [[ -f "variants.yaml" ]] && _has_build_args_include; then
        # TYPE 2: Terraform-style — build_args_include per variant from config.yaml
        _digest_log "  digest type: terraform-style (variants.yaml + config.yaml)"

        local args
        if command -v yq &>/dev/null; then
            args=$(yq -r ".versions[].variants[] | select(.flavor == \"$flavor\") | .build_args_include[]" variants.yaml 2>/dev/null || true)
        else
            log_warning "  yq not available, falling back to raw variants.yaml content"
            digest_inputs+=("FILE:variants=$(cat variants.yaml)")
            args=""
        fi

        if [[ -z "$args" ]]; then
            log_warning "  no build_args found for flavor '$flavor'"
        fi

        if [[ -n "$args" && -f "config.yaml" ]]; then
            local arg_pairs=""
            local arg
            for arg in $args; do
                local value
                if command -v yq &>/dev/null; then
                    value=$(yq -r ".build_args.${arg} // \"unknown\"" "config.yaml" 2>/dev/null)
                else
                    value="unknown"
                fi
                if [[ "$value" == "unknown" ]]; then
                    log_warning "  build arg '$arg' not found in config.yaml for flavor '$flavor'"
                fi
                arg_pairs+="${arg}=${value}"$'\n'
                _digest_log "  digest input: ${arg}=${value}"
            done
            # Sort for determinism
            digest_inputs+=("$(echo -n "$arg_pairs" | sort)")
        fi

    elif [[ -f "config.yaml" ]] && _has_build_args; then
        # TYPE 3: Simple container — all build_args from config.yaml
        _digest_log "  digest type: simple (config.yaml build_args)"

        local arg_pairs=""
        if command -v yq &>/dev/null; then
            local keys
            keys=$(yq -r '.build_args | keys | .[]' "config.yaml" 2>/dev/null || true)
            local key
            for key in $keys; do
                local value
                value=$(yq -r ".build_args.${key}" "config.yaml" 2>/dev/null)
                arg_pairs+="${key}=${value}"$'\n'
                _digest_log "  digest input: ${key}=${value}"
            done
        else
            log_warning "  yq not available, falling back to raw config.yaml content"
            digest_inputs+=("FILE:config=$(cat config.yaml)")
        fi

        if [[ -n "$arg_pairs" ]]; then
            digest_inputs+=("$(echo -n "$arg_pairs" | sort)")
        fi

    else
        # TYPE 4: Dockerfile-only
        _digest_log "  digest type: dockerfile-only"
    fi

    # --- Input: CUSTOM_BUILD_ARGS (if set) ---
    if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
        digest_inputs+=("CUSTOM_BUILD_ARGS=${CUSTOM_BUILD_ARGS}")
        _digest_log "  digest input: CUSTOM_BUILD_ARGS=${CUSTOM_BUILD_ARGS}"
    fi

    # --- Compute hash ---
    local concatenated
    concatenated=$(printf '%s\n' "${digest_inputs[@]}")
    echo -n "$concatenated" | sha256sum | cut -c1-12
}

# Helper: check if any variant in variants.yaml has build_args_include entries
_has_build_args_include() {
    if command -v yq &>/dev/null; then
        yq -e '.versions[].variants[] | select(.build_args_include | length > 0)' variants.yaml &>/dev/null
    else
        grep -q 'build_args_include' variants.yaml 2>/dev/null
    fi
}

# Helper: check if config.yaml has non-empty build_args
_has_build_args() {
    if command -v yq &>/dev/null; then
        local count
        count=$(yq -r '.build_args | length' "config.yaml" 2>/dev/null)
        [[ -n "$count" && "$count" -gt 0 ]]
    else
        grep -q 'build_args:' config.yaml 2>/dev/null
    fi
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
# Usage: should_skip_build <image> <dockerfile> <flavor> [force_rebuild]
# Returns: 0 if should skip, 1 if should build
# Sets BUILD_DIGEST variable for use in build
should_skip_build() {
    local image="$1"
    local dockerfile="$2"
    local flavor="${3:-}"
    local force_rebuild="${4:-false}"

    # Always build if force_rebuild is set
    if [[ "$force_rebuild" == "true" ]]; then
        log_info "Force rebuild requested"
        BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$flavor")
        export BUILD_DIGEST
        return 1  # Should build
    fi

    # Compute digest
    BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$flavor")
    export BUILD_DIGEST

    # Check if rebuild needed
    if image_needs_rebuild "$image" "$BUILD_DIGEST"; then
        return 1  # Should build
    fi

    return 0  # Should skip
}

# Export functions
export -f compute_build_digest
export -f _digest_log
export -f _has_build_args_include
export -f _has_build_args
export -f image_needs_rebuild
export -f image_exists_in_registry
export -f get_digest_label_args
export -f should_skip_build
export BUILD_DIGEST_LABEL
