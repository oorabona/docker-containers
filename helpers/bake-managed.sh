#!/usr/bin/env bash
# bake-managed.sh — Bake-engine partition helper for the ADR-013 production cutover.
#
# Usage (library):
#   source helpers/bake-managed.sh
#   bake_managed_containers         # echoes space-separated set
#   is_bake_managed <container>     # 0 = yes, 1 = no
#   partition_builds <builds_json>  # prints {"bake":[...],"matrix":[...]}
#
# Usage (standalone):
#   helpers/bake-managed.sh partition <builds_json_or_@file>
#
# The bake-managed set defaults to "github-runner web-shell wordpress".
# Override at any time via BAKE_MANAGED_CONTAINERS env (space-separated).
#
# Requirements: bash 4+, jq

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script dir robustly whether sourced or executed directly
# ---------------------------------------------------------------------------
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _BM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    _BM_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# shellcheck source=./logging.sh
# shellcheck disable=SC1091
source "${_BM_SCRIPT_DIR}/logging.sh"

# ---------------------------------------------------------------------------
# bake_managed_containers
#
# Echoes the space-separated list of containers that are managed by the bake
# engine.  Overridable via BAKE_MANAGED_CONTAINERS env variable — allows
# operators and tests to expand the set without code changes.
# ---------------------------------------------------------------------------
bake_managed_containers() {
    echo "${BAKE_MANAGED_CONTAINERS:-github-runner web-shell wordpress}"
}

# ---------------------------------------------------------------------------
# is_bake_managed <container>
#
# Returns 0 if <container> is in the bake-managed set, 1 otherwise.
# ---------------------------------------------------------------------------
is_bake_managed() {
    local container="$1"
    local managed
    managed=$(bake_managed_containers)
    local c
    for c in $managed; do
        if [[ "$c" == "$container" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# partition_builds <builds_json>
#
# Given the `builds` JSON array (cells with a `.container` field), prints a
# compact JSON object:
#   {"bake": [...cells whose .container is bake-managed...],
#    "matrix": [...all remaining cells...]}
#
# Cell order within each partition is preserved.
#
# Fail-closed: malformed input (not a JSON array) writes ::error:: to stderr
# and returns 1.  Empty input [] returns {"bake":[],"matrix":[]}.
# ---------------------------------------------------------------------------
partition_builds() {
    local builds_json="$1"

    # Validate: must be a non-empty string
    if [[ -z "$builds_json" ]]; then
        echo "::error::partition_builds: empty input" >&2
        return 1
    fi

    # Validate: must be a JSON array
    if ! echo "$builds_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "::error::partition_builds: input is not a JSON array" >&2
        return 1
    fi

    # Build jq array argument from the managed set.
    # Read into an array so word-splitting is explicit and shellcheck-clean.
    local managed
    managed=$(bake_managed_containers)
    local -a managed_arr
    read -ra managed_arr <<< "$managed"
    local managed_jq_array
    managed_jq_array=$(printf '%s\n' "${managed_arr[@]}" | jq -R . | jq -s -c .)

    # Partition in a single jq pass; cell order preserved within each partition
    echo "$builds_json" | jq -c \
        --argjson managed "$managed_jq_array" \
        '{
            bake:   [.[] | select(.container as $c | $managed | any(. == $c))],
            matrix: [.[] | select(.container as $c | $managed | any(. == $c) | not)]
        }'
}

# ---------------------------------------------------------------------------
# main — CLI entry point (only when executed directly, not sourced)
# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    case "$cmd" in
        partition)
            if [[ $# -lt 2 ]]; then
                printf 'Usage: %s partition <builds_json_or_@file>\n' \
                    "$(basename "$0")" >&2
                return 1
            fi
            local input="$2"
            # Support @file syntax: @path reads from file
            if [[ "$input" == @* ]]; then
                local filepath="${input#@}"
                input="$(cat "$filepath")"
            fi
            partition_builds "$input"
            ;;
        *)
            printf 'Usage: %s partition <builds_json_or_@file>\n' \
                "$(basename "$0")" >&2
            return 1
            ;;
    esac
}

# Guard: only invoke main when executed directly (not sourced by bats or callers)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
