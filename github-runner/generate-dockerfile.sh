#!/usr/bin/env bash
# Generate a Dockerfile from Dockerfile.linux template for a given distro + build_flavor.
#
# Usage (direct):
#   generate-dockerfile.sh <distro> <build_flavor>
#   generate-dockerfile.sh                                   # generates all Linux distro×flavor combos
#
# Usage (via build-container.sh convention):
#   generate-dockerfile.sh <template> <distro> <version> <build_flavor>
#
# Output: generated Dockerfile written to stdout (caller redirects to a file).
#
# Examples:
#   ./github-runner/generate-dockerfile.sh ubuntu-2404 base > github-runner/Dockerfile.ubuntu-2404-base
#   ./github-runner/generate-dockerfile.sh debian-trixie dev > github-runner/Dockerfile.debian-trixie-dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$(cd "$SCRIPT_DIR/../helpers" && pwd)"

source "$HELPERS_DIR/logging.sh"
source "$HELPERS_DIR/template-utils.sh"

CONFIG="$SCRIPT_DIR/config.yaml"
TEMPLATE="$SCRIPT_DIR/Dockerfile.linux"

[[ -f "$CONFIG" ]]   || { log_error "config.yaml not found: $CONFIG";       exit 1; }
[[ -f "$TEMPLATE" ]] || { log_error "Dockerfile.linux not found: $TEMPLATE"; exit 1; }

# ---------------------------------------------------------------------------
# Generate a single distro+flavor combination — prints to stdout
# ---------------------------------------------------------------------------
generate_one() {
    local distro="$1"
    local flavor="$2"

    # ---- Validate distro ---------------------------------------------------
    local distro_check
    distro_check=$(yq e ".distros.${distro}" "$CONFIG")
    if [[ "$distro_check" == "null" ]]; then
        log_error "Unknown distro: $distro"
        log_error "Available distros: $(yq e '.distros | keys | join(", ")' "$CONFIG")"
        exit 1
    fi

    # Reject Windows — it has its own standalone Dockerfile
    local pkg_manager
    pkg_manager=$(yq e ".distros.${distro}.pkg_manager" "$CONFIG")
    if [[ "$pkg_manager" == "none" ]]; then
        log_error "Distro $distro uses pkg_manager=none (Windows) — use Dockerfile.windows instead"
        exit 1
    fi

    # ---- Validate flavor ---------------------------------------------------
    local flavor_check
    flavor_check=$(yq e ".flavors.${flavor}" "$CONFIG")
    if [[ "$flavor_check" == "null" ]]; then
        log_error "Unknown flavor: $flavor"
        log_error "Available flavors: $(yq e '.flavors | keys | join(", ")' "$CONFIG")"
        exit 1
    fi

    log_info "Generating Dockerfile: distro=$distro flavor=$flavor" >&2

    # ---- Helpers for reading distro config ---------------------------------
    _yq_distro() { yq e ".distros.${distro}.${1}" "$CONFIG"; }
    _yq_distro_default() { yq e ".distros.${distro}.${1} // \"${2}\"" "$CONFIG"; }

    local base_image base_image_arg install_cmd cleanup_cmd runner_user user_exists
    base_image=$(     _yq_distro      "base_image")
    base_image_arg=$( _yq_distro      "base_image_arg")
    install_cmd=$(    _yq_distro      "install_cmd")
    cleanup_cmd=$(    _yq_distro_default "cleanup_cmd" "")
    runner_user=$(    _yq_distro      "runner_user")
    user_exists=$(    _yq_distro_default "user_exists" "false")

    # ---- Wrap helper: indent a list of words at ~80 chars ------------------
    _wrap_list() {
        local indent="$1"
        shift
        local line=""
        for word in "$@"; do
            if [[ -z "$line" ]]; then
                line="${indent}${word}"
            elif (( ${#line} + ${#word} + 1 > 80 )); then
                printf '%s \\\n' "$line"
                line="${indent}${word}"
            else
                line+=" ${word}"
            fi
        done
        [[ -n "$line" ]] && printf '%s' "$line"
    }

    # ========================================================================
    # @@BASE_IMAGE@@ — ARG + FROM lines
    # Strip the ${VAR:-default} shell syntax from base_image if present;
    # we emit "ARG <arg>=<raw_default>" so Docker resolves it cleanly.
    # ========================================================================
    # Extract raw default (e.g. "ubuntu:24.04" from "${UBUNTU_2404_BASE:-ubuntu:24.04}")
    local raw_default
    if [[ "$base_image" =~ ^\$\{[A-Za-z0-9_]+:-(.+)\}$ ]]; then
        raw_default="${BASH_REMATCH[1]}"
    else
        raw_default="$base_image"
    fi

    local base_block
    base_block="ARG ${base_image_arg}=${raw_default}"$'\n'
    base_block+="FROM \${${base_image_arg}}"$'\n'

    # ========================================================================
    # @@LABELS@@ — OCI image labels + runner metadata
    # ========================================================================
    local labels_block
    labels_block='LABEL org.opencontainers.image.description="GitHub Actions self-hosted runner ('"${distro}"' '"${flavor}"')"'$'\n'
    labels_block+='LABEL org.opencontainers.image.source="https://github.com/oorabona/docker-containers"'$'\n'
    labels_block+='LABEL com.github.runner.flavor="'"${flavor}"'"'$'\n'
    labels_block+='LABEL com.github.runner.distro="'"${distro}"'"'$'\n'

    # ========================================================================
    # @@INSTALL_PACKAGES@@ — base packages with BuildKit cache mounts
    # ========================================================================
    # Base flavor packages (always installed)
    local base_pkgs_raw base_pkgs
    base_pkgs_raw=$(yq e '.flavors.base.packages.apt | join(" ")' "$CONFIG")
    # shellcheck disable=SC2086  # intentional word splitting
    base_pkgs=$(_wrap_list "      " $base_pkgs_raw)

    local install_block
    install_block="RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \\"$'\n'
    install_block+="    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\"$'\n'
    install_block+="    ${install_cmd} \\"$'\n'
    install_block+="${base_pkgs}"
    if [[ -n "$cleanup_cmd" ]]; then
        install_block+=" \\"$'\n'"    && ${cleanup_cmd}"
    fi
    install_block+=$'\n'

    # ========================================================================
    # @@DEV_PACKAGES@@ — extra packages for dev flavor only; empty for base
    # ========================================================================
    local dev_block=""
    if [[ "$flavor" == "dev" ]]; then
        local dev_pkgs_raw dev_pkgs
        dev_pkgs_raw=$(yq e '.flavors.dev.packages.apt | join(" ")' "$CONFIG")
        # shellcheck disable=SC2086  # intentional word splitting
        dev_pkgs=$(_wrap_list "      " $dev_pkgs_raw)

        dev_block="RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \\"$'\n'
        dev_block+="    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\"$'\n'
        dev_block+="    ${install_cmd} \\"$'\n'
        dev_block+="${dev_pkgs}"
        if [[ -n "$cleanup_cmd" ]]; then
            dev_block+=" \\"$'\n'"    && ${cleanup_cmd}"
        fi
        dev_block+=$'\n'
    fi

    # ========================================================================
    # @@CREATE_USER@@ — useradd when user_exists=false
    # ========================================================================
    local create_user_block=""
    if [[ "$user_exists" != "true" ]]; then
        create_user_block="# Create dedicated runner user (non-root)"$'\n'
        create_user_block+="RUN useradd -m -s /bin/bash ${runner_user}"$'\n'
    fi

    # ========================================================================
    # Expand template → stdout
    # ========================================================================
    expand_template "$TEMPLATE" \
        "BASE_IMAGE"        "$base_block" \
        "LABELS"            "$labels_block" \
        "INSTALL_PACKAGES"  "$install_block" \
        "DEV_PACKAGES"      "$dev_block" \
        "CREATE_USER"       "$create_user_block"
}

# ---------------------------------------------------------------------------
# Main: dispatch based on calling convention
# ---------------------------------------------------------------------------
if [[ $# -eq 2 ]]; then
    # Direct invocation: generate-dockerfile.sh <distro> <build_flavor>
    generate_one "$1" "$2"
elif [[ $# -eq 4 ]]; then
    # build-container.sh convention: <template> <distro> <version> <build_flavor>
    # $1=template (ignored — we always use Dockerfile.linux), $2=distro, $3=version (ignored), $4=build_flavor
    generate_one "$2" "$4"
elif [[ $# -eq 0 ]]; then
    # Generate all Linux distros × all flavors
    all_distros=$(yq e '.distros | keys | .[]' "$CONFIG")
    all_flavors=$(yq e '.flavors | keys | .[]' "$CONFIG")

    while IFS= read -r distro; do
        # Skip Windows distros
        pm=$(yq e ".distros.${distro}.pkg_manager" "$CONFIG")
        [[ "$pm" == "none" ]] && continue

        while IFS= read -r flv; do
            out_file="$SCRIPT_DIR/Dockerfile.${distro}-${flv}"
            log_info "Writing $out_file" >&2
            generate_one "$distro" "$flv" > "$out_file"
        done <<< "$all_flavors"
    done <<< "$all_distros"
else
    echo "Usage: generate-dockerfile.sh [<distro> <build_flavor>]" >&2
    echo "  With 2 args: print generated Dockerfile to stdout" >&2
    echo "  No args:   generate all Linux Dockerfile.<distro>-<flavor> files" >&2
    exit 1
fi
