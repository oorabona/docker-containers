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

# Read a required digest input without allowing partial command-substitution
# output to become a valid input.  Callers must return its status explicitly:
# compute_build_digest is often invoked from a conditional, where Bash disables
# errexit for the duration of the calling function.
_digest_read_file() {
    local path="$1"
    local output_var="$2"
    local content

    if ! content=$(cat -- "$path"); then
        log_error "  digest input: failed to read $path"
        return 1
    fi

    printf -v "$output_var" '%s' "$content"
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
    if [[ ! -f "$dockerfile" ]]; then
        log_error "  digest input: Dockerfile not found at $dockerfile"
        return 1
    fi
    local dockerfile_content
    _digest_read_file "$dockerfile" dockerfile_content || return 1
    digest_inputs+=("FILE:Dockerfile=$dockerfile_content")
    _digest_log "  digest input: Dockerfile (${#dockerfile_content} bytes)"

    # A file a Dockerfile bind-mounts is a build input this digest does not see.
    # It is not covered here, and the gap is #1103: nothing that reaches this
    # function uses a bind mount today, because the one container that does —
    # postgres — is built by bake, which never consults a digest.
    #
    # A parser over the Dockerfile's mount lines was written and removed rather
    # than kept: it recognised one spelling of a flag that has many, and its
    # comment claimed a future mount would enter the digest automatically, which
    # was false. A guard that names a property it does not have is worse than an
    # absence someone can look up.

    # --- Detect container type and collect flavor-specific inputs ---

    if [[ -n "$flavor" && -f "flavors/${flavor}.yaml" ]]; then
        # TYPE 1: Postgres-style — flavor file + per-extension versions
        _digest_log "  digest type: postgres-style (flavors/${flavor}.yaml)"

        # Add flavor file content
        local flavor_content
        _digest_read_file "flavors/${flavor}.yaml" flavor_content || return 1
        digest_inputs+=("FILE:flavor=$flavor_content")
        _digest_log "  digest input: flavors/${flavor}.yaml"

        # Extract extension list from flavor file, get version for each
        local extensions
        if command -v yq &>/dev/null; then
            if ! extensions=$(yq -r '.extensions[]' "flavors/${flavor}.yaml" 2>/dev/null); then
                log_error "  digest input: failed to parse extensions from flavors/${flavor}.yaml"
                return 1
            fi
        else
            log_warning "  yq not available, falling back to raw flavor file content"
            extensions=""
        fi

        if [[ -n "$extensions" ]]; then
            if [[ ! -f "extensions/config.yaml" ]]; then
                log_error "  digest input: extensions/config.yaml not found"
                return 1
            fi
            local ext_pairs=""
            local ext
            for ext in $extensions; do
                local version
                if command -v yq &>/dev/null; then
                    if ! version=$(yq -r ".extensions.${ext}.version // \"unknown\"" "extensions/config.yaml" 2>/dev/null); then
                        log_error "  digest input: failed to query extension '$ext' in extensions/config.yaml"
                        return 1
                    fi
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
            local sorted_ext_pairs
            if ! sorted_ext_pairs=$(printf '%s' "$ext_pairs" | sort); then
                log_error "  digest input: failed to sort extension versions"
                return 1
            fi
            digest_inputs+=("$sorted_ext_pairs")
        fi

    else
        local has_variant_build_args=1
        if [[ -f "variants.yaml" ]]; then
            if _has_build_args_include; then
                has_variant_build_args=0
            else
                local has_variant_build_args_status=$?
                if [[ "$has_variant_build_args_status" -gt 1 ]]; then
                    log_error "  digest input: failed to query variants.yaml"
                    return 1
                fi
            fi
        fi

        local has_config_build_args=1
        if [[ -f "config.yaml" ]]; then
            if _has_build_args; then
                has_config_build_args=0
            else
                local has_config_build_args_status=$?
                if [[ "$has_config_build_args_status" -gt 1 ]]; then
                    log_error "  digest input: failed to query config.yaml"
                    return 1
                fi
            fi
        fi

        if [[ "$has_variant_build_args" -eq 0 ]]; then
        # TYPE 2: Terraform-style — build_args_include per variant from config.yaml
        _digest_log "  digest type: terraform-style (variants.yaml + config.yaml)"

        local args
        if command -v yq &>/dev/null; then
            if ! args=$(yq -r ".versions[].variants[] | select(.flavor == \"$flavor\") | .build_args_include[]" variants.yaml 2>/dev/null); then
                log_error "  digest input: failed to query build args from variants.yaml"
                return 1
            fi
        else
            log_warning "  yq not available, falling back to raw variants.yaml content"
            local variants_content
            _digest_read_file variants.yaml variants_content || return 1
            digest_inputs+=("FILE:variants=$variants_content")
            args=""
        fi

        if [[ -z "$args" ]]; then
            log_warning "  no build_args found for flavor '$flavor'"
        fi

        if [[ -n "$args" ]]; then
            if [[ ! -f "config.yaml" ]]; then
                log_error "  digest input: config.yaml not found for declared build args"
                return 1
            fi
            local arg_pairs=""
            local arg
            for arg in $args; do
                local value
                if command -v yq &>/dev/null; then
                    if ! value=$(yq -r ".build_args.${arg} // \"unknown\"" "config.yaml" 2>/dev/null); then
                        log_error "  digest input: failed to query build arg '$arg' in config.yaml"
                        return 1
                    fi
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
            local sorted_arg_pairs
            if ! sorted_arg_pairs=$(printf '%s' "$arg_pairs" | sort); then
                log_error "  digest input: failed to sort build args"
                return 1
            fi
            digest_inputs+=("$sorted_arg_pairs")
        fi

        elif [[ "$has_config_build_args" -eq 0 ]]; then
        # TYPE 3: Simple container — all build_args from config.yaml
        _digest_log "  digest type: simple (config.yaml build_args)"

        local arg_pairs=""
        if command -v yq &>/dev/null; then
            local keys
            if ! keys=$(yq -r '.build_args | keys | .[]' "config.yaml" 2>/dev/null); then
                log_error "  digest input: failed to query build arg keys from config.yaml"
                return 1
            fi
            local key
            for key in $keys; do
                local value
                if ! value=$(yq -r ".build_args.${key}" "config.yaml" 2>/dev/null); then
                    log_error "  digest input: failed to query build arg '$key' in config.yaml"
                    return 1
                fi
                arg_pairs+="${key}=${value}"$'\n'
                _digest_log "  digest input: ${key}=${value}"
            done
        else
            log_warning "  yq not available, falling back to raw config.yaml content"
            local config_content
            _digest_read_file config.yaml config_content || return 1
            digest_inputs+=("FILE:config=$config_content")
        fi

        if [[ -n "$arg_pairs" ]]; then
            local sorted_arg_pairs
            if ! sorted_arg_pairs=$(printf '%s' "$arg_pairs" | sort); then
                log_error "  digest input: failed to sort build args"
                return 1
            fi
            digest_inputs+=("$sorted_arg_pairs")
        fi

        else
        # TYPE 4: Dockerfile-only
        _digest_log "  digest type: dockerfile-only"
        fi
    fi

    # --- Input: CUSTOM_BUILD_ARGS (if set) ---
    if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
        digest_inputs+=("CUSTOM_BUILD_ARGS=${CUSTOM_BUILD_ARGS}")
        _digest_log "  digest input: CUSTOM_BUILD_ARGS=${CUSTOM_BUILD_ARGS}"
    fi

    # --- Input: LAST_REBUILD.md (if present) ---
    # Including LAST_REBUILD.md in the digest ensures that any drift-PR merge
    # (which appends a base-digest-drift section) invalidates the cached digest,
    # forcing should_skip_build to return false and trigger a fresh rebuild.
    # Without this, smart-skip would match the old digest and skip the build,
    # leaving the base digest unchanged and causing an infinite drift-PR loop.
    #
    # compute_build_digest is always called with cwd = container directory
    # (the make script does pushd <container> before invoking build_container).
    # LAST_REBUILD.md lives at the container root, so $PWD/LAST_REBUILD.md is correct.
    local last_rebuild_path="$PWD/LAST_REBUILD.md"
    if [[ -f "$last_rebuild_path" ]]; then
        local last_rebuild_hash
        if ! last_rebuild_hash=$(sha256sum "$last_rebuild_path" | awk '{print $1}'); then
            log_error "  digest input: failed to hash $last_rebuild_path"
            return 1
        fi
        if [[ ! "$last_rebuild_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
            log_error "  digest input: invalid hash for $last_rebuild_path"
            return 1
        fi
        digest_inputs+=("LAST_REBUILD.md=$last_rebuild_hash")
        _digest_log "  digest input: LAST_REBUILD.md=$last_rebuild_hash"
    fi

    # --- Compute hash ---
    local concatenated
    if ! concatenated=$(printf '%s\n' "${digest_inputs[@]}"); then
        log_error "  digest input: failed to assemble digest inputs"
        return 1
    fi
    local full_digest
    if ! full_digest=$(printf '%s' "$concatenated" | sha256sum); then
        log_error "  digest computation: sha256sum failed"
        return 1
    fi
    full_digest="${full_digest%%[[:space:]]*}"
    if [[ ! "$full_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "  digest computation: sha256sum returned an invalid hash"
        return 1
    fi
    printf '%s\n' "${full_digest:0:12}"
}

# Helper: check if any variant in variants.yaml has build_args_include entries
_has_build_args_include() {
    if command -v yq &>/dev/null; then
        yq '.' variants.yaml &>/dev/null || return 2
        yq -e '.versions[].variants[] | select(.build_args_include | length > 0)' variants.yaml &>/dev/null
        local status=$?
        [[ "$status" -le 1 ]] && return "$status"
        return 2
    else
        grep -q 'build_args_include' variants.yaml 2>/dev/null
        local status=$?
        [[ "$status" -le 1 ]] && return "$status"
        return 2
    fi
}

# Helper: check if config.yaml has non-empty build_args
_has_build_args() {
    if command -v yq &>/dev/null; then
        local count
        yq '.' config.yaml &>/dev/null || return 2
        if ! count=$(yq -r '.build_args | length' "config.yaml" 2>/dev/null); then
            return 2
        fi
        [[ "$count" =~ ^[0-9]+$ ]] || return 2
        [[ "$count" -gt 0 ]]
    else
        grep -q 'build_args:' config.yaml 2>/dev/null
        local status=$?
        [[ "$status" -le 1 ]] && return "$status"
        return 2
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
export -f get_digest_label_args
export -f should_skip_build
export BUILD_DIGEST_LABEL
