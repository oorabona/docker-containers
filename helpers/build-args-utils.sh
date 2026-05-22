#!/usr/bin/env bash

# Shared build_args extraction from config.yaml
# Eliminates duplication across build-container.sh and generate-dashboard.sh
# Requires: yq, helpers/logging.sh

# Source logging if not already loaded
if ! declare -F log_warning &>/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
fi

# Source build_args validator if not already loaded.
# _vbc_validate_build_args_config enforces R7/R7b/R7c at the point of use
# (defense-in-depth: the schema lint runs only in CI, but every build path
# must reject malformed/malicious build_args before flags reach docker).
if ! declare -F _vbc_validate_build_args_config &>/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate-base-cache-schema.sh"
fi

# Get build args as Docker --build-arg flags
# Validates build_args keys and values before emitting flags (fail-closed).
# Usage: build_args_flags "./container-dir"
# Output: "--build-arg FOO=bar --build-arg BAZ=qux" or ""
# Returns: 0 on success, non-zero and prints error to stderr on validation failure.
build_args_flags() {
    local dir="$1"
    local config_file="$dir/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Validate before emitting: reject REMOTE_CR keys, non-identifier keys,
    # non-scalar values, and whitespace-containing values. Fail-closed so a
    # malformed or malicious config.yaml aborts the build rather than emitting
    # unsafe --build-arg tokens to docker.
    local container_label
    container_label="$(basename "$dir")"
    if ! _vbc_validate_build_args_config "$container_label" "$config_file"; then
        return 1
    fi

    local result
    if result=$(yq -r '.build_args // {} | to_entries | map("--build-arg " + .key + "=" + (.value | tostring)) | join(" ")' "$config_file" 2>&1); then
        echo "$result"
    else
        log_warning "Failed to parse build_args from $config_file: $result" >&2
        return 1
    fi
}

# Get build args as JSON object
# Usage: build_args_json "./container-dir"
# Output: '{"FOO":"bar","BAZ":"qux"}' or '{}'
build_args_json() {
    local dir="$1"
    local config_file="$dir/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo "{}"
        return 0
    fi

    local result
    if result=$(yq -o=json -r '.build_args // {}' "$config_file" 2>&1); then
        echo "$result"
    else
        log_warning "Failed to parse build_args from $config_file: $result" >&2
        echo "{}"
    fi
}

# Prepare all build arguments from version, flavor, config, and environment
# Consolidates logic previously duplicated in build-container.sh and push-container.sh
# Usage: prepare_build_args <version> [flavor]
# Sets: _BUILD_ARGS, _MAJOR_VERSION, _UPSTREAM_VERSION
prepare_build_args() {
    local version="$1"
    local flavor="${2:-}"

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
    if ! config_build_args=$(build_args_flags "."); then
        log_error "build_args validation failed; aborting build arg preparation" >&2
        return 1
    fi
    if [[ -n "$config_build_args" ]]; then
        _BUILD_ARGS="$_BUILD_ARGS $config_build_args"
        log_info "Loaded build args from config.yaml"
    fi

    if [[ -n "${CUSTOM_BUILD_ARGS:-}" ]]; then
        _BUILD_ARGS="$_BUILD_ARGS $CUSTOM_BUILD_ARGS"
    fi
}

# Get build args as key=value lines
# Usage: build_args_lines "./container-dir"
# Output: "FOO=bar\nBAZ=qux" or ""
build_args_lines() {
    local dir="$1"
    local config_file="$dir/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    local result
    if result=$(yq -r '.build_args // {} | to_entries[] | .key + "=" + .value' "$config_file" 2>&1); then
        echo "$result"
    else
        log_warning "Failed to parse build_args from $config_file: $result" >&2
    fi
}
