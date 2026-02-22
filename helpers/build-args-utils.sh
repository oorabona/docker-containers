#!/usr/bin/env bash

# Shared build_args extraction from config.yaml
# Eliminates duplication across build-container.sh and generate-dashboard.sh
# Requires: yq, helpers/logging.sh

# Source logging if not already loaded
if ! declare -F log_warning &>/dev/null; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
fi

# Get build args as Docker --build-arg flags
# Usage: build_args_flags "./container-dir"
# Output: "--build-arg FOO=bar --build-arg BAZ=qux" or ""
build_args_flags() {
    local dir="$1"
    local config_file="$dir/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    local result
    if result=$(yq -r '.build_args // {} | to_entries | map("--build-arg " + .key + "=" + .value) | join(" ")' "$config_file" 2>&1); then
        echo "$result"
    else
        log_warning "Failed to parse build_args from $config_file: $result" >&2
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
