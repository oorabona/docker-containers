#!/usr/bin/env bash
# Helpers for PR changed-file detection.

set -euo pipefail

pr_changed_files() {
    if [[ $# -ne 2 ]]; then
        echo "usage: pr_changed_files <base_sha> <head_sha>" >&2
        return 2
    fi

    local base="$1"
    local head="$2"
    local mb

    mb="$(git merge-base "$base" "$head" 2>/dev/null || true)"

    if [[ -z "$mb" ]]; then
        echo "warning: merge-base unavailable for PR diff; refusing unsafe two-dot fallback" >&2
        return 3
    fi

    git diff --name-only --no-renames "$mb" "$head"
}

export -f pr_changed_files
