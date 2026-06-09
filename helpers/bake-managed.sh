#!/usr/bin/env bash
# bake-managed.sh — Bake-engine partition helper for the ADR-013 production cutover.
#
# Usage (library):
#   source helpers/bake-managed.sh
#   bake_managed_containers         # echoes space-separated set
#   is_bake_managed <container>     # 0 = yes, 1 = no
#   _bake_retained_eligible <container>  # 0 = retained cells may route to bake
#   partition_builds <builds_json>       # prints {"bake":[...],"matrix":[...]}
#
# Usage (standalone):
#   helpers/bake-managed.sh partition <builds_json_or_@file>
#
# The bake-managed set defaults to:
#   github-runner web-shell wordpress debian vector jekyll ansible
#   sslh openvpn php openresty terraform
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
    echo "${BAKE_MANAGED_CONTAINERS:-github-runner web-shell wordpress debian vector jekyll ansible sslh openvpn php openresty terraform}"
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
# _bake_retained_core_containers
#
# Echoes the B1-core retained-bake rollout set.  This is intentionally narrower
# than bake_managed_containers while chained retained rebuilds are deferred.
# Override via BAKE_RETAINED_CORE_CONTAINERS for focused tests only.
# ---------------------------------------------------------------------------
_bake_retained_core_containers() {
    echo "${BAKE_RETAINED_CORE_CONTAINERS:-debian vector jekyll ansible sslh openvpn openresty terraform}"
}

# ---------------------------------------------------------------------------
# _bake_is_retained_core_container <container>
#
# Returns 0 if <container> is in the B1-core retained-bake rollout set.
# ---------------------------------------------------------------------------
_bake_is_retained_core_container() {
    local container="$1"
    local core
    core=$(_bake_retained_core_containers)
    local c
    for c in $core; do
        if [[ "$c" == "$container" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# _bake_normalize_base_repo <base_image_ref>
#
# Prints the repository path after stripping known project registry prefixes.
# Examples:
#   ghcr.io/oorabona/debian:${TAG}  -> debian
#   ${REMOTE_CR}/php:${TAG}         -> php
#   ${REMOTE_CR}/library/debian:12  -> library/debian
#
# The library/ namespace is deliberately left intact: it denotes an external
# mirror path, not a project-built bake-managed container.
# ---------------------------------------------------------------------------
_bake_normalize_base_repo() {
    local ref="$1"
    local repo_path="${ref%%@*}"
    local leaf="${repo_path##*/}"

    if [[ "$leaf" == *:* ]]; then
        repo_path="${repo_path%:*}"
    fi

    repo_path="${repo_path#\$\{REMOTE_CR\}/}"
    if [[ "$repo_path" == ghcr.io/*/* ]]; then
        repo_path="${repo_path#ghcr.io/}"
        repo_path="${repo_path#*/}"
    fi

    printf '%s\n' "$repo_path"
}

# ---------------------------------------------------------------------------
# _bake_container_has_internal_base_dependency <container>
#
# Static chained-container detector for retained-bake routing.
#
# Returns:
#   0 when any config.yaml base_image points at another bake-managed container
#   1 when config.yaml is parseable and no managed base dependency is found
#   2 when config.yaml is missing, unparsable, or has no base_image entries
#
# This uses only <container>/config.yaml.  It never runs ./make, Docker, or any
# networked probe.  library/* refs are external mirrors and are not considered
# managed-container dependencies even when the leaf name matches a container.
# ---------------------------------------------------------------------------
_bake_container_has_internal_base_dependency() {
    local container="$1"
    local repo_root
    repo_root="$(dirname "${_BM_SCRIPT_DIR}")"
    local config_file="${repo_root}/${container}/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 2
    fi

    local refs
    if ! refs=$(yq e '.. | select(has("base_image")) | .base_image | select(. != null)' \
            "$config_file" 2>/dev/null); then
        return 2
    fi
    if [[ -z "$refs" ]]; then
        return 2
    fi

    local ref repo_path first_segment
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        repo_path=$(_bake_normalize_base_repo "$ref")
        [[ -n "$repo_path" ]] || continue
        if [[ "$repo_path" == library/* ]]; then
            continue
        fi
        first_segment="${repo_path%%/*}"
        if is_bake_managed "$first_segment"; then
            return 0
        fi
    done <<< "$refs"

    return 1
}

# ---------------------------------------------------------------------------
# _bake_retained_eligible <container>
#
# Returns 0 iff retained (non-latest) Linux cells for <container> may route to
# bake in B1-core:
#   - the container is bake-managed,
#   - it is in the B1-core standalone rollout set,
#   - it is not build.bake_latest_only,
#   - its config.yaml base_image entries do not reference a bake-managed
#     project container.
#
# Missing or unparsable config.yaml fails closed to not eligible.
# ---------------------------------------------------------------------------
_bake_retained_eligible() {
    local container="$1"
    local chained_status

    is_bake_managed "$container" || return 1
    if _bake_container_latest_only "$container"; then
        return 1
    fi
    _bake_is_retained_core_container "$container" || return 1

    if _bake_container_has_internal_base_dependency "$container"; then
        return 1
    else
        chained_status=$?
        [[ "$chained_status" -eq 1 ]] || return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# partition_builds <builds_json> [<scope_active>] [<include_retained>]
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
#     3. Its .is_latest_version is explicitly true OR include_retained is
#        "true" and the container is retained-eligible.
#   All other cells go to .matrix so the flat matrix handles them faithfully.
#
# Design rationale: retained-bake is deliberately limited to B1-core standalone
# containers.  latest-only and chained containers keep retained cells on the
# flat matrix so cells are not dropped or rebuilt against the wrong internal
# base-image target.
#
# Cell order within each partition is preserved.
#
# Fail-closed: malformed input (not a JSON array) writes ::error:: to stderr
# and returns 1.  Empty input [] returns {"bake":[],"matrix":[]}.
# ---------------------------------------------------------------------------
partition_builds() {
    local builds_json="$1"
    local scope_active="${2:-false}"
    local include_retained="${3:-false}"

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
    # per-cell fidelity (scope_versions / scope_flavors / test routing).
    if [[ "$scope_active" == "true" ]]; then
        echo "$builds_json" | jq -c '{bake: [], matrix: [.[]]}'
        return 0
    fi

    # Build jq array arguments from the managed set and retained-eligible set.
    # Read into an array so word-splitting is explicit and shellcheck-clean.
    local managed
    managed=$(bake_managed_containers)
    local -a managed_arr
    read -ra managed_arr <<< "$managed"
    local managed_jq_array
    if [[ ${#managed_arr[@]} -gt 0 ]]; then
        managed_jq_array=$(printf '%s\n' "${managed_arr[@]}" | jq -R . | jq -s -c .)
    else
        managed_jq_array='[]'
    fi

    local eligible_jq_array='[]'
    if [[ "$include_retained" == "true" ]]; then
        local -a eligible_arr=()
        local c
        while IFS= read -r c; do
            [[ -n "$c" ]] || continue
            if _bake_retained_eligible "$c"; then
                eligible_arr+=("$c")
            fi
        done < <(echo "$builds_json" | jq -r '
            [.[] |
                select((.os // "") == "" or (.os // "") == "linux") |
                .container // empty
            ] | unique | .[]')

        if [[ ${#eligible_arr[@]} -gt 0 ]]; then
            eligible_jq_array=$(printf '%s\n' "${eligible_arr[@]}" | jq -R . | jq -s -c .)
        fi
    fi

    # Partition in a single jq pass; cell order preserved within each partition.
    #
    # A cell lands in .bake only when ALL hold:
    #   (a) container is bake-managed
    #   (b) .os is "linux" or absent/empty (linux cells may omit the field)
    #   (c) .is_latest_version is explicitly true OR include_retained=true and
    #       the container is retained-eligible
    #
    # Non-eligible retained cells route to .matrix so the flat matrix builds
    # them with per-cell scan/attest fidelity.
    # Note: .container is captured as $c before entering $managed so the
    # any() filter runs in string context (not object context).
    echo "$builds_json" | jq -c \
        --argjson managed "$managed_jq_array" \
        --argjson eligible "$eligible_jq_array" \
        --arg include_retained "$include_retained" \
        '{
            bake:   [.[] | select(
                        (
                            (.container as $c | $managed | any(. == $c))
                            and ((.os // "") == "" or (.os // "") == "linux")
                            and (
                                (.is_latest_version == true)
                                or (
                                    $include_retained == "true"
                                    and (.container as $c | $eligible | any(. == $c))
                                )
                            )
                        )
                    )],
            matrix: [.[] | select(
                        (
                            (.container as $c | $managed | any(. == $c))
                            and ((.os // "") == "" or (.os // "") == "linux")
                            and (
                                (.is_latest_version == true)
                                or (
                                    $include_retained == "true"
                                    and (.container as $c | $eligible | any(. == $c))
                                )
                            )
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
                printf 'Usage: %s partition <builds_json_or_@file> [scope_active] [include_retained]\n' \
                    "$(basename "$0")" >&2
                return 1
            fi
            local input="$2"
            local scope_arg="${3:-false}"
            local include_retained_arg="${4:-false}"
            # Support @file syntax: @path reads from file
            if [[ "$input" == @* ]]; then
                local filepath="${input#@}"
                input="$(cat "$filepath")"
            fi
            partition_builds "$input" "$scope_arg" "$include_retained_arg"
            ;;
        *)
            printf 'Usage: %s partition <builds_json_or_@file> [scope_active] [include_retained]\n' \
                "$(basename "$0")" >&2
            return 1
            ;;
    esac
}

# Guard: only invoke main when executed directly (not sourced by bats or callers)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
