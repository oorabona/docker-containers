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
# Usage: compute_build_digest <dockerfile> <flavor> [render_config render_flavor render_build_flavor render_pg_major render_source...]
# Returns: 64-char hex SHA256 digest
#
# Note: CUSTOM_BUILD_ARGS is included in the digest if set.
# Do not pass secrets via CUSTOM_BUILD_ARGS — they will be hashed
# and logged when DIGEST_DEBUG=1.
#
# The optional render inputs are supplied only by build-container.sh for a
# marker-bearing Dockerfile.  Omitting them means the caller is not rendering
# a template (as is still the case for push-container.sh).
compute_build_digest() {
    local dockerfile="$1"
    local flavor="${2:-}"
    local render_config="${3:-}"
    local render_flavor="${4:-}"
    local render_build_flavor="${5:-}"
    local render_pg_major="${6:-}"
    if [[ "$#" -ge 6 ]]; then
        shift 6
    else
        set --
    fi
    local -a render_sources=("$@")

    command -v yq >/dev/null 2>&1 || {
        log_error "  yq is required for build digest inputs but was not found in PATH."
        return 1
    }

    # Keep fields in separate arrays until they are emitted.  Bash variables
    # cannot hold NUL, which is precisely why assembly into one string is not
    # safe here.
    local -a digest_record_types=()
    local -a digest_record_names=()
    local -a digest_record_values=()

    # --- Input 1: Dockerfile content ---
    if [[ ! -f "$dockerfile" ]]; then
        log_error "  digest input: Dockerfile not found at $dockerfile"
        return 1
    fi
    local dockerfile_content
    _digest_read_file "$dockerfile" dockerfile_content || return 1
    digest_record_types+=("FILE")
    digest_record_names+=("Dockerfile")
    digest_record_values+=("$dockerfile_content")
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
        digest_record_types+=("FILE")
        digest_record_names+=("flavor")
        digest_record_values+=("$flavor_content")
        _digest_log "  digest input: flavors/${flavor}.yaml"

        # Extract extension list from flavor file, get version for each
        local extensions
        if ! extensions=$(yq -r '.extensions[]' "flavors/${flavor}.yaml" 2>/dev/null); then
            log_error "  digest input: failed to parse extensions from flavors/${flavor}.yaml"
            return 1
        fi

        if [[ -n "$extensions" ]]; then
            if [[ ! -f "extensions/config.yaml" ]]; then
                log_error "  digest input: extensions/config.yaml not found"
                return 1
            fi
            local -a extension_names=()
            local -a extension_values=()
            local ext
            for ext in $extensions; do
                local version
                if ! version=$(yq -r ".extensions.${ext}.version // \"unknown\"" "extensions/config.yaml" 2>/dev/null); then
                    log_error "  digest input: failed to query extension '$ext' in extensions/config.yaml"
                    return 1
                fi
                if [[ "$version" == "unknown" ]]; then
                    log_warning "  extension '$ext' listed in flavors/${flavor}.yaml but not found in extensions/config.yaml"
                fi
                extension_names+=("$ext")
                extension_values+=("$version")
                _digest_log "  digest input: ${ext}=${version}"
            done
            # Sort names, not name=value text: a value may contain a newline.
            local sorted_extension_names
            if ! sorted_extension_names=$(printf '%s\n' "${extension_names[@]}" | sort); then
                log_error "  digest input: failed to sort extension versions"
                return 1
            fi
            local sorted_extension_name extension_index
            while IFS= read -r sorted_extension_name || [[ -n "$sorted_extension_name" ]]; do
                for extension_index in "${!extension_names[@]}"; do
                    [[ "${extension_names[$extension_index]}" == "$sorted_extension_name" ]] || continue
                    break
                done
                digest_record_types+=("EXTENSION_VERSION")
                digest_record_names+=("$sorted_extension_name")
                digest_record_values+=("${extension_values[$extension_index]}")
            done <<< "$sorted_extension_names"
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
        if ! args=$(yq -r ".versions[].variants[] | select(.flavor == \"$flavor\") | .build_args_include[]" variants.yaml 2>/dev/null); then
            log_error "  digest input: failed to query build args from variants.yaml"
            return 1
        fi

        if [[ -z "$args" ]]; then
            log_warning "  no build_args found for flavor '$flavor'"
        fi

        if [[ -n "$args" ]]; then
            if [[ ! -f "config.yaml" ]]; then
                log_error "  digest input: config.yaml not found for declared build args"
                return 1
            fi
            local -a arg_names=()
            local -a arg_values=()
            local arg
            for arg in $args; do
                local value
                if ! value=$(yq -r ".build_args.${arg} // \"unknown\"" "config.yaml" 2>/dev/null); then
                    log_error "  digest input: failed to query build arg '$arg' in config.yaml"
                    return 1
                fi
                if [[ "$value" == "unknown" ]]; then
                    log_warning "  build arg '$arg' not found in config.yaml for flavor '$flavor'"
                fi
                arg_names+=("$arg")
                arg_values+=("$value")
                _digest_log "  digest input: ${arg}=${value}"
            done
            # Sort names, not name=value text: a value may contain a newline.
            local sorted_arg_names
            if ! sorted_arg_names=$(printf '%s\n' "${arg_names[@]}" | sort); then
                log_error "  digest input: failed to sort build args"
                return 1
            fi
            local sorted_arg_name arg_index
            while IFS= read -r sorted_arg_name || [[ -n "$sorted_arg_name" ]]; do
                for arg_index in "${!arg_names[@]}"; do
                    [[ "${arg_names[$arg_index]}" == "$sorted_arg_name" ]] || continue
                    break
                done
                digest_record_types+=("BUILD_ARG")
                digest_record_names+=("$sorted_arg_name")
                digest_record_values+=("${arg_values[$arg_index]}")
            done <<< "$sorted_arg_names"
        fi

        elif [[ "$has_config_build_args" -eq 0 ]]; then
        # TYPE 3: Simple container — all build_args from config.yaml
        _digest_log "  digest type: simple (config.yaml build_args)"

        local -a arg_names=()
        local -a arg_values=()
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
            arg_names+=("$key")
            arg_values+=("$value")
            _digest_log "  digest input: ${key}=${value}"
        done

        if [[ "${#arg_names[@]}" -gt 0 ]]; then
            local sorted_arg_names
            if ! sorted_arg_names=$(printf '%s\n' "${arg_names[@]}" | sort); then
                log_error "  digest input: failed to sort build args"
                return 1
            fi
            local sorted_arg_name arg_index
            while IFS= read -r sorted_arg_name || [[ -n "$sorted_arg_name" ]]; do
                for arg_index in "${!arg_names[@]}"; do
                    [[ "${arg_names[$arg_index]}" == "$sorted_arg_name" ]] || continue
                    break
                done
                digest_record_types+=("BUILD_ARG")
                digest_record_names+=("$sorted_arg_name")
                digest_record_values+=("${arg_values[$arg_index]}")
            done <<< "$sorted_arg_names"
        fi

        else
        # TYPE 4: Dockerfile-only
        _digest_log "  digest type: dockerfile-only"
        fi
    fi

    # A marker-bearing Dockerfile is labelled from declared pre-expansion
    # inputs, never from a generated temporary file.  The caller selects the
    # renderer and provides exactly the config, arguments, and sourced helper
    # files used for that render.
    if [[ -n "$render_config" ]]; then
        local render_config_content
        _digest_read_file "$render_config" render_config_content || return 1
        digest_record_types+=("FILE")
        digest_record_names+=("render-config")
        digest_record_values+=("$render_config_content")
        _digest_log "  digest input: $render_config"

        digest_record_types+=("RENDER_ARG")
        digest_record_names+=("flavor")
        digest_record_values+=("$render_flavor")
        _digest_log "  digest input: render flavor=$render_flavor"

        digest_record_types+=("RENDER_ARG")
        digest_record_names+=("build_flavor")
        digest_record_values+=("$render_build_flavor")
        _digest_log "  digest input: render build_flavor=$render_build_flavor"

        digest_record_types+=("RENDER_ARG")
        digest_record_names+=("pg_major")
        digest_record_values+=("$render_pg_major")
        _digest_log "  digest input: render pg_major=$render_pg_major"

        local render_source render_source_content
        for render_source in "${render_sources[@]}"; do
            _digest_read_file "$render_source" render_source_content || return 1
            digest_record_types+=("FILE")
            digest_record_names+=("renderer:$(basename "$render_source")")
            digest_record_values+=("$render_source_content")
            _digest_log "  digest input: $render_source"
        done
    fi

    # --- Input: CUSTOM_BUILD_ARGS (if set) ---
    if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
        digest_record_types+=("CUSTOM_BUILD_ARGS")
        digest_record_names+=("")
        digest_record_values+=("$CUSTOM_BUILD_ARGS")
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
        digest_record_types+=("LAST_REBUILD")
        digest_record_names+=("LAST_REBUILD.md")
        digest_record_values+=("$last_rebuild_hash")
        _digest_log "  digest input: LAST_REBUILD.md=$last_rebuild_hash"
    fi

    # --- Compute hash ---
    local full_digest
    if ! full_digest=$(
        {
            # This literal is deliberately part of the hashed stream.  Every
            # following input is a typed, NUL-framed record: type, name,
            # value, record end.  No Bash-held field can spell a separator.
            printf '%s\0' 'digest-v2'
            local record_index
            for record_index in "${!digest_record_types[@]}"; do
                printf '%s\0%s\0%s\0' \
                    "${digest_record_types[$record_index]}" \
                    "${digest_record_names[$record_index]}" \
                    "${digest_record_values[$record_index]}"
            done
        } | sha256sum
    ); then
        log_error "  digest computation: sha256sum failed"
        return 1
    fi
    full_digest="${full_digest%%[[:space:]]*}"
    if [[ ! "$full_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "  digest computation: sha256sum returned an invalid hash"
        return 1
    fi
    printf '%s\n' "$full_digest"
}

# Helper: check if any variant in variants.yaml has build_args_include entries
_has_build_args_include() {
    yq '.' variants.yaml &>/dev/null || return 2
    yq -e '.versions[].variants[] | select(.build_args_include | length > 0)' variants.yaml &>/dev/null
    local status=$?
    [[ "$status" -le 1 ]] && return "$status"
    return 2
}

# Helper: check if config.yaml has non-empty build_args
_has_build_args() {
    local count
    yq '.' config.yaml &>/dev/null || return 2
    if ! count=$(yq -r '.build_args | length' "config.yaml" 2>/dev/null); then
        return 2
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || return 2
    [[ "$count" -gt 0 ]]
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
# Usage: should_skip_build <image> <dockerfile> <flavor> [force_rebuild] [precomputed_digest]
# Returns: 0 if should skip, 1 if should build, 2 if the digest cannot be computed
# Sets BUILD_DIGEST variable for use in build on statuses 0 and 1; unsets it on 2
should_skip_build() {
    local image="$1"
    local dockerfile="$2"
    local flavor="${3:-}"
    local force_rebuild="${4:-false}"
    local precomputed_digest="${5:-}"

    if [[ "$#" -ge 5 ]]; then
        [[ -n "$precomputed_digest" ]] || { unset BUILD_DIGEST; return 2; }
        BUILD_DIGEST="$precomputed_digest"
    else
        BUILD_DIGEST=$(compute_build_digest "$dockerfile" "$flavor") || { unset BUILD_DIGEST; return 2; }
    fi
    export BUILD_DIGEST

    # Always build if force_rebuild is set, after establishing provenance.
    if [[ "$force_rebuild" == "true" ]]; then
        log_info "Force rebuild requested"
        return 1  # Should build
    fi

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
