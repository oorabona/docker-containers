#!/bin/bash
# Generate Dockerfile from template for web-shell multi-distro variants
# Called by build_container() when Dockerfile has @@MARKER@@ patterns
#
# Usage: generate-dockerfile.sh <template_path> <flavor> [<version>]
# Output: Generated Dockerfile to stdout
#
# Markers expanded:
#   @@BASE_IMAGE@@          Distro-specific ARGs + FROM instruction
#   @@INSTALL_PACKAGES@@    Package installation (install_cmd + packages + cleanup)
#   @@SSH_SETUP@@           SSH server configuration
#   @@USER_SETUP@@          User creation + sudo + bashrc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$(cd "$SCRIPT_DIR/../helpers" && pwd)"

source "$HELPERS_DIR/logging.sh"
source "$HELPERS_DIR/template-utils.sh"

template="${1:?Usage: generate-dockerfile.sh <template> <flavor> [version]}"
flavor="${2:-debian}"
version="${3:-}"

config="$SCRIPT_DIR/config.yaml"

[[ -f "$config" ]] || { log_error "config.yaml not found: $config"; exit 1; }

# Verify flavor exists in distros config
if [[ "$(yq e ".distros.${flavor}" "$config")" == "null" ]]; then
    log_error "Unknown distro: $flavor (available: $(yq e '.distros | keys | join(", ")' "$config"))"
    exit 1
fi

# --- Read distro config ---
_yq() { yq e ".distros.${flavor}.${1}" "$config"; }
_yq_default() { yq e ".distros.${flavor}.${1} // \"${2}\"" "$config"; }

install_cmd=$(_yq install_cmd)
cleanup_cmd=$(_yq_default cleanup_cmd "")
shell_user=$(_yq shell_user)
user_exists=$(_yq_default user_exists "false")
pkg_manager=$(_yq pkg_manager)
pre_install=$(_yq_default pre_install "")

# Collect packages: shell_packages (bash, sudo) + all meta-group packages
shell_pkgs=$(yq e '(.distros.'"${flavor}"'.shell_packages // []) | join(" ")' "$config")
meta_pkgs=$(yq e '[.distros.'"${flavor}"'.packages | to_entries[] | .value[]] | join(" ")' "$config")
all_pkgs="${shell_pkgs:+$shell_pkgs }${meta_pkgs}"

log_info "Generating Dockerfile: distro=$flavor user=$shell_user pkgs=$(echo "$all_pkgs" | wc -w | tr -d ' ')"

# Wrap a space-separated list of words into continuation lines (max ~72 chars)
_wrap_list() {
    local indent="$1"
    shift
    local line=""
    for word in "$@"; do
        if [[ -z "$line" ]]; then
            line="${indent}${word}"
        elif (( ${#line} + ${#word} + 1 > 72 )); then
            printf '%s \\\n' "$line"
            line="${indent}${word}"
        else
            line+=" ${word}"
        fi
    done
    [[ -n "$line" ]] && printf '%s' "$line"
}

# ============================================================
# @@BASE_IMAGE@@ — Distro-specific ARGs + FROM instruction
# Values like ${DEBIAN_TAG} are Docker ARG references — output literally
# ============================================================
case "$flavor" in
    debian)
        base_block='ARG DEBIAN_TAG="trixie"
FROM ghcr.io/oorabona/debian:${DEBIAN_TAG}'
        ;;
    alpine)
        base_block='ARG ALPINE_BASE=alpine
ARG ALPINE_TAG=3.21
FROM ${ALPINE_BASE}:${ALPINE_TAG}'
        ;;
    ubuntu)
        base_block='ARG UBUNTU_BASE=ubuntu
ARG UBUNTU_TAG=noble
FROM ${UBUNTU_BASE}:${UBUNTU_TAG}'
        ;;
    rocky)
        base_block='ARG ROCKY_BASE=rockylinux
ARG ROCKY_TAG=9
FROM ${ROCKY_BASE}:${ROCKY_TAG}'
        ;;
    *)
        log_error "No BASE_IMAGE template for distro: $flavor"
        exit 1
        ;;
esac
base_block+=$'\n'

# ============================================================
# @@INSTALL_PACKAGES@@ — Package installation with distro pkg manager
# ============================================================
# shellcheck disable=SC2086 # intentional word splitting for package list
pkg_lines=$(_wrap_list "        " $all_pkgs)
install_block=""
if [[ -n "$pre_install" ]]; then
    install_block+="RUN ${pre_install} \\"$'\n'"    && "
else
    install_block+="RUN "
fi
install_block+="${install_cmd} \\"$'\n'"${pkg_lines}"
if [[ -n "$cleanup_cmd" ]]; then
    install_block+=" \\"$'\n'"    && ${cleanup_cmd}"
fi
install_block+=$'\n'

# ============================================================
# @@SSH_SETUP@@ — SSH server configuration (same for all distros)
# ============================================================
read -r -d '' ssh_block <<'BLOCK' || true
# Configure SSH server
RUN sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && mkdir -p /run/sshd
BLOCK
ssh_block+=$'\n'

# ============================================================
# @@USER_SETUP@@ — User creation + sudo + bashrc
# user_exists=true: skip creation (custom base has user pre-configured)
# user_exists=false: create user, add to sudo/wheel group, configure NOPASSWD
# ============================================================
user_block="ARG SHELL_USER=${shell_user}"$'\n'

if [[ "$user_exists" != "true" ]]; then
    user_block+=$'\n'
    case "$pkg_manager" in
        apk)
            # Alpine: adduser -D (BusyBox), wheel group for sudo
            user_block+='# Create user with home directory and bash shell
RUN adduser -D -s /bin/bash ${SHELL_USER} \
    && adduser ${SHELL_USER} wheel \
    && echo "${SHELL_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${SHELL_USER} \
    && chmod 0440 /etc/sudoers.d/${SHELL_USER}'
            ;;
        apt)
            # Debian/Ubuntu: useradd, sudo group
            user_block+='# Create user with home directory and bash shell
RUN useradd -m -s /bin/bash ${SHELL_USER} \
    && usermod -aG sudo ${SHELL_USER} \
    && echo "${SHELL_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${SHELL_USER} \
    && chmod 0440 /etc/sudoers.d/${SHELL_USER}'
            ;;
        dnf)
            # Rocky: useradd, wheel group
            user_block+='# Create user with home directory and bash shell
RUN useradd -m -s /bin/bash ${SHELL_USER} \
    && usermod -aG wheel ${SHELL_USER} \
    && echo "${SHELL_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${SHELL_USER} \
    && chmod 0440 /etc/sudoers.d/${SHELL_USER}'
            ;;
    esac
fi

user_block+=$'\n\n''# Bash prompt and aliases
COPY bashrc /home/${SHELL_USER}/.bashrc
RUN chown ${SHELL_USER}:${SHELL_USER} /home/${SHELL_USER}/.bashrc'
user_block+=$'\n'

# ============================================================
# Expand template with all marker content
# ============================================================
expand_template "$template" \
    "BASE_IMAGE" "$base_block" \
    "INSTALL_PACKAGES" "$install_block" \
    "SSH_SETUP" "$ssh_block" \
    "USER_SETUP" "$user_block"
