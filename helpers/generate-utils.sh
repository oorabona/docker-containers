#!/bin/bash
# Shared utilities for Dockerfile generators (template+generator pattern)
# Used by: web-shell/generate-dockerfile.sh, github-runner/generate-dockerfile.sh
#
# Sourcing convention:
#   source "$HELPERS_DIR/logging.sh"
#   source "$HELPERS_DIR/generate-utils.sh"
#
# All functions take a config_file as first argument so they are stateless and
# work regardless of which container is calling them.

# Validate that a distro exists in config.yaml.
# Usage: validate_distro <config_file> <distro>
# Exits 1 with an error message when the distro is not found.
validate_distro() {
    local config="$1"
    local distro="$2"

    if [[ "$(yq e ".distros.${distro}" "$config")" == "null" ]]; then
        log_error "Unknown distro: $distro"
        log_error "Available distros: $(yq e '.distros | keys | join(", ")' "$config")"
        return 1
    fi
}

# Validate that a flavor exists in config.yaml.
# Usage: validate_flavor <config_file> <flavor>
# Exits 1 with an error message when the flavor is not found.
validate_flavor() {
    local config="$1"
    local flavor="$2"

    if [[ "$(yq e ".flavors.${flavor}" "$config")" == "null" ]]; then
        log_error "Unknown flavor: $flavor"
        log_error "Available flavors: $(yq e '.flavors | keys | join(", ")' "$config")"
        return 1
    fi
}

# Read a distro property from config.yaml.
# Usage: distro_property <config_file> <distro> <property> [default]
# Prints the value to stdout. If a default is given it is used when the value is null.
distro_property() {
    local config="$1"
    local distro="$2"
    local property="$3"
    local default="${4:-}"

    if [[ -n "$default" ]]; then
        yq e ".distros.${distro}.${property} // \"${default}\"" "$config"
    else
        yq e ".distros.${distro}.${property}" "$config"
    fi
}

# List all distro names from config.yaml, one per line.
# Usage: list_distros <config_file> [--exclude-windows]
# With --exclude-windows, skips any distro whose pkg_manager is "none".
list_distros() {
    local config="$1"
    local exclude_windows=false
    [[ "${2:-}" == "--exclude-windows" ]] && exclude_windows=true

    local distros
    distros=$(yq e '.distros | keys | .[]' "$config")

    if [[ "$exclude_windows" == "true" ]]; then
        while IFS= read -r distro; do
            local pm
            pm=$(yq e ".distros.${distro}.pkg_manager" "$config")
            [[ "$pm" == "none" ]] && continue
            echo "$distro"
        done <<< "$distros"
    else
        echo "$distros"
    fi
}

# List all flavor names from config.yaml, one per line.
# Usage: list_flavors <config_file>
# Returns empty output (no error) when the config has no .flavors key.
list_flavors() {
    local config="$1"

    local has_flavors
    has_flavors=$(yq e '.flavors' "$config")
    [[ "$has_flavors" == "null" ]] && return 0

    yq e '.flavors | keys | .[]' "$config"
}

# Parse the calling convention used by build-container.sh and direct callers.
#
# Two supported conventions:
#   Direct (2 args):                  <distro> <flavor>
#   build-container.sh (4 args):      <template> <distro> <version> <flavor>
#
# Sets globals: GEN_DISTRO, GEN_FLAVOR, GEN_VERSION
# Returns 1 on unsupported argument count (caller should print usage and exit).
parse_generator_args() {
    # shellcheck disable=SC2034  # globals intentionally set for callers to read
    GEN_DISTRO=""
    # shellcheck disable=SC2034
    GEN_FLAVOR=""
    # shellcheck disable=SC2034
    GEN_VERSION=""

    case $# in
        2)
            # Direct: <distro> <flavor>
            # shellcheck disable=SC2034
            GEN_DISTRO="$1"
            # shellcheck disable=SC2034
            GEN_FLAVOR="$2"
            ;;
        4)
            # build-container.sh: <template> <distro> <version> <flavor>
            # shellcheck disable=SC2034
            GEN_DISTRO="$2"
            # shellcheck disable=SC2034
            GEN_VERSION="$3"
            # shellcheck disable=SC2034
            GEN_FLAVOR="$4"
            ;;
        *)
            return 1
            ;;
    esac
}
