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

# Emit a per-network-call latency line to stderr.  Never touches stdout.
# Usage: log_latency <label> <start_epochrealtime> [warn_threshold_seconds]
# - label:                 short identifier for the call (e.g. "gh-api /repos/...")
# - start_epochrealtime:   value of ${EPOCHREALTIME} captured before the call
# - warn_threshold_seconds (optional): emit a ::warning:: annotation when dur > threshold
# Safe under set -euo pipefail; returns 0 always; side-effect-free on stdout.
log_latency() {
    local label="${1:-unknown}"
    local start="${2:-}"
    local threshold="${3:-}"

    # Compute duration.  Requires EPOCHREALTIME (bash 5+).
    # On bash <5 or when start is empty, emit an explicit unavailability marker
    # rather than a misleading number (SECONDS would reflect shell uptime, not
    # call duration — that is worse than no data at all, per the #453 lesson).
    local dur
    if [[ -n "$start" && -n "${EPOCHREALTIME:-}" ]]; then
        dur=$(awk -v a="$start" -v b="${EPOCHREALTIME}" 'BEGIN{printf "%.3f", b-a}' 2>/dev/null || true)
    else
        # bash <5 or caller passed empty start — timing genuinely unavailable.
        printf '[latency] %s (timing unavailable: bash<5 lacks EPOCHREALTIME)\n' "$label" >&2
        return 0
    fi

    # Normal latency line — always emitted (plain stderr, NOT ::notice::)
    printf '[latency] %s %ss\n' "$label" "$dur" >&2

    # Optional warning annotation when threshold given and duration exceeds it
    if [[ -n "$threshold" ]]; then
        local over
        over=$(awk -v d="$dur" -v t="$threshold" 'BEGIN{print (d+0 > t+0) ? "1" : "0"}' 2>/dev/null || echo "0")
        if [[ "$over" == "1" ]]; then
            printf '::warning::[latency] %s took %ss (> %ss) — possible API/registry degradation\n' \
                "$label" "$dur" "$threshold" >&2
        fi
    fi

    return 0
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
