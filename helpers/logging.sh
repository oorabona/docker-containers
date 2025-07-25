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
