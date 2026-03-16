#!/usr/bin/env bash

# Shared logging utilities for docker-containers repository
# Eliminates code duplication across scripts

# Colors for output (only define if not already set)
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
fi

# Dry-run support: $DOCKER/$SKOPEO replace hardcoded commands
# DRY_RUN=true -> commands print instead of executing
# DOCKER/SKOPEO can also be overridden directly (e.g., podman)
if [[ -z "${DOCKER:-}" ]]; then
    DOCKER="docker"
    [[ "${DRY_RUN:-false}" == "true" ]] && DOCKER="echo docker"
fi
if [[ -z "${SKOPEO:-}" ]]; then
    SKOPEO="skopeo"
    [[ "${DRY_RUN:-false}" == "true" ]] && SKOPEO="echo skopeo"
fi

# Logging functions
log_success() {
    echo -e "${GREEN}✅ $*${NC}" >&2
}

log_error() {
    echo -e "${RED}❌ $*${NC}" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}" >&2
}

log_info() {
    echo -e "${BLUE}ℹ️  $*${NC}" >&2
}

log_step() {
    echo -e "${BLUE}🔵 $*${NC}" >&2
}

# Helper for help text formatting (from make script)
log_help() {
    printf "\033[36m%-25s\033[0m %s\n" "$1" "$2"
}

# Check if a directory contains a Dockerfile (standard or template-based)
# Usage: has_dockerfile <dir>
has_dockerfile() {
    local dir="${1:-.}"
    ls "$dir"/Dockerfile* &>/dev/null
}

# List all container directories (those with a Dockerfile)
# Usage: list_containers [base_dir]
list_containers() {
    local base="${1:-.}"
    find "$base" -maxdepth 2 \( -name "Dockerfile" -o -name "Dockerfile.*" \) | sed 's|^\./||' | cut -d'/' -f1 | sort -u
}
