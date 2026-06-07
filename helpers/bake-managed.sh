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
# The bake-managed set defaults to "github-runner web-shell wordpress debian vector jekyll ansible".
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
    echo "${BAKE_MANAGED_CONTAINERS:-github-runner web-shell wordpress debian vector jekyll ansible}"
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
# _bake_container_latest_only <container>
#
# Returns 0 (true) if the container declares build.bake_latest_only: true in
# its variants.yaml; returns 1 (false) otherwise.  Tolerates a missing file,
# a missing field, or a non-true value — all default to false.
#
# Uses the resolved _BM_SCRIPT_DIR to locate <container>/variants.yaml
# relative to the repo root (parent of helpers/).
# ---------------------------------------------------------------------------
_bake_container_latest_only() {
    local container="$1"
    local repo_root
    repo_root="$(dirname "${_BM_SCRIPT_DIR}")"
    local variants_file="${repo_root}/${container}/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        return 1
    fi

    local val
    val=$(yq e '.build.bake_latest_only // false' "$variants_file" 2>/dev/null) || return 1
    [[ "$val" == "true" ]]
}

# ---------------------------------------------------------------------------
# partition_builds <builds_json> [<scope_active>]
#
# Given the `builds` JSON array (cells with a `.container` field), prints a
# compact JSON object:
#   {"bake": [...cells routed to the bake engine...],
#    "matrix": [...all remaining cells...]}
#
# When <scope_active> is "true" (second argument), bake is disabled for this
# run: ALL cells route to .matrix.  This preserves per-cell scan/attest
# fidelity for scoped dispatches (scope_versions / scope_flavors non-empty),
# which build only a subset of a container's cells while bake would publish
# the full container plan.
#
# When <scope_active> is absent or any value other than "true", per-cell
# routing applies:
#   A cell lands in .bake only when ALL of the following hold:
#     1. Its .container is in the bake-managed set.
#     2. Its .os is "linux" or absent/empty (linux cells may omit the field).
#     3. Its .is_latest_version is explicitly true.
#   All other cells go to .matrix so the flat matrix handles them faithfully.
#
# Design rationale: bake is latest-only by design — it always generates and
# builds the full container plan for the latest version of each container.
# Any retained (non-latest) cell detected by the carry-forward / diff-failure /
# container-file-change / PR-smoke logic is routed to the flat matrix, which
# builds exactly the detected cells per-cell with full scan/attest coverage.
# This prevents a retained cell from being falsely recovered (unscanned,
# unpublished) by a bake run that regenerates latest-only.
#
# Cell order within each partition is preserved.
#
# Fail-closed: malformed input (not a JSON array) writes ::error:: to stderr
# and returns 1.  Empty input [] returns {"bake":[],"matrix":[]}.
# ---------------------------------------------------------------------------
partition_builds() {
    local builds_json="$1"
    local scope_active="${2:-false}"

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

    # Scoped run or forced-matrix: bake disabled — all cells to matrix for full
    # per-cell fidelity (scope_versions / scope_flavors / PR routing).
    if [[ "$scope_active" == "true" ]]; then
        echo "$builds_json" | jq -c '{bake: [], matrix: [.[]]}'
        return 0
    fi

    # Build jq array argument from the managed set.
    # Read into an array so word-splitting is explicit and shellcheck-clean.
    local managed
    managed=$(bake_managed_containers)
    local -a managed_arr
    read -ra managed_arr <<< "$managed"
    local managed_jq_array
    managed_jq_array=$(printf '%s\n' "${managed_arr[@]}" | jq -R . | jq -s -c .)

    # Partition in a single jq pass; cell order preserved within each partition.
    #
    # A cell lands in .bake only when ALL hold:
    #   (a) container is bake-managed
    #   (b) .os is "linux" or absent/empty (linux cells may omit the field)
    #   (c) .is_latest_version is explicitly true
    #
    # Retained (non-latest) cells for bake-managed containers route to .matrix
    # so the flat matrix builds them with per-cell scan/attest fidelity.
    # Note: .container is captured as $c before entering $managed so the
    # any() filter runs in string context (not object context).
    echo "$builds_json" | jq -c \
        --argjson managed "$managed_jq_array" \
        '{
            bake:   [.[] | select(
                        (.container as $c | $managed | any(. == $c))
                        and ((.os // "") == "" or (.os // "") == "linux")
                        and (.is_latest_version == true)
                    )],
            matrix: [.[] | select(
                        (
                            (.container as $c | $managed | any(. == $c))
                            and ((.os // "") == "" or (.os // "") == "linux")
                            and (.is_latest_version == true)
                        ) | not
                    )]
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
                printf 'Usage: %s partition <builds_json_or_@file> [scope_active]\n' \
                    "$(basename "$0")" >&2
                return 1
            fi
            local input="$2"
            local scope_arg="${3:-false}"
            # Support @file syntax: @path reads from file
            if [[ "$input" == @* ]]; then
                local filepath="${input#@}"
                input="$(cat "$filepath")"
            fi
            partition_builds "$input" "$scope_arg"
            ;;
        *)
            printf 'Usage: %s partition <builds_json_or_@file> [scope_active]\n' \
                "$(basename "$0")" >&2
            return 1
            ;;
    esac
}

# Guard: only invoke main when executed directly (not sourced by bats or callers)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
