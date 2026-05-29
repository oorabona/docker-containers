#!/usr/bin/env bash
# dependency-graph.sh — Infer project-internal container dependency DAG from lineage.
#
# A container has a "project-internal" dep on another container <X> when its
# base_image_ref matches one of:
#   - ghcr.io/<owner>/<X>:<tag>     (e.g. ghcr.io/oorabona/php:latest)
#   - ${REMOTE_CR}/<X>:<tag>        (CI-expanded variant of the above)
#   - hub.docker.io/<owner>/<X>:<tag> (project Docker Hub mirror)
# AND <X> appears in `./make list` (the canonical project container set).
#
# External upstream refs (library/*, hashicorp/*, mcr.microsoft.com/*) are
# NOT project-internal deps — they're external base images outside this repo.
#
# Sources: lineage files in .build-lineage/<container>-*.json; falls back to
# parsing config.yaml build_args values if no lineage exists for a container.
#
# Public API:
#   _depgraph_get_deps <container>             — direct deps (space-sep)
#   _depgraph_get_deps_transitive <container>  — transitive closure (topo order, leaves first)
#   _depgraph_get_consumers <container>        — reverse — who depends on <container>
#   _depgraph_validate_no_cycles               — exits 1 if any cycle detected
#
# Test override hooks:
#   _DEPGRAPH_CONTAINERS_OVERRIDE — space-sep list, bypasses `./make list`
#   _DEPGRAPH_LINEAGE_DIR         — alternate lineage directory (default: .build-lineage)

# Note: no set -euo pipefail here — this file is sourced by consumers that
# may have their own error handling. Callers must not rely on pipefail.

# ---------------------------------------------------------------------------
# Auto-detect PROJECT_ROOT from BASH_SOURCE if not set
# ---------------------------------------------------------------------------
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Source lineage-utils for is_lineage_sidecar
# ---------------------------------------------------------------------------
# shellcheck source=./lineage-utils.sh
source "${PROJECT_ROOT}/helpers/lineage-utils.sh"

# ---------------------------------------------------------------------------
# _depgraph_valid_containers
#
# Returns (echo) space-separated list of valid container names.
# Respects _DEPGRAPH_CONTAINERS_OVERRIDE test hook.
# ---------------------------------------------------------------------------
_depgraph_valid_containers() {
    if [[ -n "${_DEPGRAPH_CONTAINERS_OVERRIDE:-}" ]]; then
        printf '%s' "$_DEPGRAPH_CONTAINERS_OVERRIDE"
    else
        local _make_out
        if ! _make_out=$(cd "$PROJECT_ROOT" && ./make list 2>&1); then
            echo "::error::Failed to enumerate project containers via './make list'" >&2
            return 1
        fi
        if [[ -z "$_make_out" ]]; then
            echo "::error::'./make list' returned empty container set" >&2
            return 1
        fi
        printf '%s' "$(echo "$_make_out" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# _depgraph_project_owner
#
# Outputs the project owner (GitHub username / org) used to scope internal refs.
# Resolution order:
#   1. _DEPGRAPH_OWNER_OVERRIDE   — test hook
#   2. GITHUB_REPOSITORY_OWNER   — set by GitHub Actions
#   3. git remote origin URL      — fallback for local runs
#
# Returns non-zero (fail-closed) when the owner cannot be determined.
# ---------------------------------------------------------------------------
_depgraph_project_owner() {
    if [[ -n "${_DEPGRAPH_OWNER_OVERRIDE:-}" ]]; then
        printf '%s' "$_DEPGRAPH_OWNER_OVERRIDE"
        return 0
    fi
    if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
        printf '%s' "$GITHUB_REPOSITORY_OWNER"
        return 0
    fi
    local remote_url
    if ! remote_url=$(cd "$PROJECT_ROOT" && git remote get-url origin 2>/dev/null); then
        echo "::error::Cannot determine project owner (no GITHUB_REPOSITORY_OWNER and git remote get-url origin failed)" >&2
        return 1
    fi
    # Match: github.com/OWNER/REPO  or  git@github.com:OWNER/REPO(.git)
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "::error::Cannot parse project owner from git remote URL: ${remote_url}" >&2
    return 1
}

# ---------------------------------------------------------------------------
# _depgraph_is_internal_ref <base_image_ref> <valid_containers_space_sep>
#
# Outputs the parent container name if the ref is project-internal; empty otherwise.
# Matches patterns (only when <owner> == project owner):
#   ghcr.io/<owner>/<X>:<tag>
#   hub.docker.io/<owner>/<X>:<tag>
#   ${REMOTE_CR}/<X>:<tag>    (CI-controlled variable — always trusted)
# ---------------------------------------------------------------------------
_depgraph_is_internal_ref() {
    local ref="$1"
    local valid_containers="$2"
    local parent=""

    # Skip refs with unresolved shell variables (placeholders not yet expanded)
    # BUT allow ${REMOTE_CR}/X:tag which is a known CI variable pattern
    # Strip the ${REMOTE_CR}/ prefix first to extract the container name
    local normalized_ref="$ref"
    # SC2016 disabled: single-quote assignments store literal ${REMOTE_CR} and ${ strings intentionally
    # shellcheck disable=SC2016
    local remote_cr_prefix='${REMOTE_CR}/'
    # shellcheck disable=SC2016
    local dollar_brace='${'
    if [[ "$normalized_ref" == "${remote_cr_prefix}"* ]]; then
        normalized_ref="${normalized_ref#"${remote_cr_prefix}"}"
    elif [[ "$normalized_ref" == *"${dollar_brace}"* ]]; then
        # Has other unresolved vars — skip
        return 0
    fi

    # Resolve project owner (fail-closed: if undetermined, treat ref as external)
    local owner
    if ! owner=$(_depgraph_project_owner 2>/dev/null); then
        return 1
    fi

    # Match: after owner-prefix path, extract container name before : or @ or end
    # Patterns:
    #   ghcr.io/<owner>/<name>:<tag>   → after ghcr.io/<owner>/, take <name>
    #   hub.docker.io/<owner>/<name>:<tag> → after hub.docker.io/<owner>/, take <name>
    #   ${REMOTE_CR}/<name>:<tag>      → normalized_ref is already <name>:<tag> here
    if [[ "$normalized_ref" =~ ^ghcr\.io/([^/]+)/([^:/@ ]+) ]]; then
        if [[ "${BASH_REMATCH[1]}" == "$owner" ]]; then
            parent="${BASH_REMATCH[2]}"
        fi
    elif [[ "$normalized_ref" =~ ^hub\.docker\.io/([^/]+)/([^:/@ ]+) ]]; then
        if [[ "${BASH_REMATCH[1]}" == "$owner" ]]; then
            parent="${BASH_REMATCH[2]}"
        fi
    elif [[ "$ref" == "${remote_cr_prefix}"* && "$normalized_ref" =~ ^([^:/@ ]+) ]]; then
        # ${REMOTE_CR}/name:tag after stripping prefix — CI-controlled, always trusted
        parent="${BASH_REMATCH[1]}"
    else
        return 0
    fi

    [[ -n "$parent" ]] || return 0

    # Verify the extracted name is in the valid container set
    if [[ " $valid_containers " == *" $parent "* ]]; then
        printf '%s' "$parent"
    fi
}

# ---------------------------------------------------------------------------
# _depgraph_get_deps <container>
#
# Outputs space-separated direct project-internal dependencies.
# Reads all non-sidecar lineage files for the container.
# Falls back to config.yaml build_args when no lineage files exist.
# ---------------------------------------------------------------------------
_depgraph_get_deps() {
    local container="$1"
    local deps=""
    local valid_containers
    # Explicit error check required: set -e is disabled inside command
    # substitutions used as conditional operands (bash §3.7.5), so a simple
    # `if ! var=$(cmd)` or `var=$(cmd) || ...` will not propagate failures from
    # nested helpers.  We must check the exit code explicitly.
    valid_containers="$(_depgraph_valid_containers 2>&1)" || {
        # Re-emit the error (already contains ::error:: from _depgraph_valid_containers)
        printf '%s\n' "$valid_containers" >&2
        return 1
    }
    local lineage_dir="${_DEPGRAPH_LINEAGE_DIR:-${PROJECT_ROOT}/.build-lineage}"

    shopt -s nullglob
    local lineage_files=("${lineage_dir}/${container}-"*.json "${lineage_dir}/${container}.json")
    shopt -u nullglob

    local found_any=false
    for lineage_file in "${lineage_files[@]}"; do
        [[ -f "$lineage_file" ]] || continue
        local basename_file
        basename_file="$(basename "$lineage_file")"
        # Skip sidecar files BEFORE marking found_any; a container with only sidecars
        # must fall through to the config.yaml fallback path.
        if is_lineage_sidecar "$basename_file"; then continue; fi
        # Mark that at least one real lineage entry exists (suppresses config.yaml fallback)
        found_any=true

        local base_ref
        base_ref=$(jq -r '.base_image_ref // empty' "$lineage_file" 2>/dev/null || true)
        [[ -n "$base_ref" ]] || continue

        local parent
        parent=$(_depgraph_is_internal_ref "$base_ref" "$valid_containers")
        [[ -n "$parent" ]] || continue
        [[ "$parent" == "$container" ]] && continue  # no self-deps

        # Deduplicate
        if [[ " $deps " != *" $parent "* ]]; then
            deps="$deps $parent"
        fi
    done

    # Fallback: parse config.yaml build_args if no lineage exists
    if [[ "$found_any" == "false" ]]; then
        local config_file="${PROJECT_ROOT}/${container}/config.yaml"
        if [[ -f "$config_file" ]]; then
            # Extract all string values from build_args that look like internal refs
            local build_args_refs
            build_args_refs=$(grep -oE '(ghcr\.io/[^/]+/[^:/ ]+|hub\.docker\.io/[^/]+/[^:/ ]+|\$\{REMOTE_CR\}/[^:/ ]+)' \
                "$config_file" 2>/dev/null || true)
            while IFS= read -r ref; do
                [[ -n "$ref" ]] || continue
                local parent
                parent=$(_depgraph_is_internal_ref "$ref" "$valid_containers")
                [[ -n "$parent" ]] || continue
                [[ "$parent" == "$container" ]] && continue
                if [[ " $deps " != *" $parent "* ]]; then
                    deps="$deps $parent"
                fi
            done <<< "$build_args_refs"
        fi
    fi

    printf '%s' "${deps# }"
}

# ---------------------------------------------------------------------------
# _depgraph_get_deps_transitive <container>
#
# Outputs space-separated transitive deps in topological order (leaves first).
# Uses iterative DFS with visited + in-stack cycle detection.
# ---------------------------------------------------------------------------
_depgraph_get_deps_transitive() {
    local container="$1"
    local -a result=()
    local -a visited_list=()
    local -a stack=()

    _depgraph_dfs_topo() {
        local node="$1"

        # Check in-stack (cycle)
        local s
        for s in "${stack[@]:-}"; do
            if [[ "$s" == "$node" ]]; then
                return 0  # cycle — skip silently (validate_no_cycles catches it)
            fi
        done

        # Check already visited
        local v
        for v in "${visited_list[@]:-}"; do
            if [[ "$v" == "$node" ]]; then
                return 0
            fi
        done

        stack+=("$node")
        local deps
        deps=$(_depgraph_get_deps "$node")
        if [[ -n "$deps" ]]; then
            local dep
            for dep in $deps; do
                _depgraph_dfs_topo "$dep"
            done
        fi
        stack=("${stack[@]:0:${#stack[@]}-1}")

        visited_list+=("$node")
        # Add to result only if not already there (can happen with diamond deps)
        local already=false
        local r
        for r in "${result[@]:-}"; do
            if [[ "$r" == "$node" ]]; then
                already=true
                break
            fi
        done
        if [[ "$already" == "false" && "$node" != "$container" ]]; then
            result+=("$node")
        fi
    }

    _depgraph_dfs_topo "$container"
    printf '%s' "${result[*]:-}"
}

# ---------------------------------------------------------------------------
# _depgraph_get_consumers <container>
#
# Outputs space-separated names of containers that directly depend on <container>.
# ---------------------------------------------------------------------------
_depgraph_get_consumers() {
    local target="$1"
    local consumers=""
    local valid_containers
    valid_containers="$(_depgraph_valid_containers)"

    local c
    for c in $valid_containers; do
        [[ "$c" == "$target" ]] && continue
        local deps
        deps=$(_depgraph_get_deps "$c")
        if [[ " $deps " == *" $target "* ]]; then
            consumers="$consumers $c"
        fi
    done

    printf '%s' "${consumers# }"
}

# ---------------------------------------------------------------------------
# _depgraph_validate_no_cycles
#
# Exits 1 if any cycle is detected in the dependency graph.
# ---------------------------------------------------------------------------
_depgraph_validate_no_cycles() {
    local valid_containers
    valid_containers="$(_depgraph_valid_containers)"
    local -A color  # 0=white, 1=gray (in-stack), 2=black (done)
    local cycle_found=false
    local cycle_path=""

    _dfs_cycle() {
        local node="$1"
        local path="${2:-$node}"

        color["$node"]=1  # gray
        local deps
        deps=$(_depgraph_get_deps "$node")
        local dep
        for dep in $deps; do
            if [[ "${color[$dep]:-0}" == "1" ]]; then
                # Found cycle
                cycle_found=true
                cycle_path="${path} -> $dep"
                return 0
            fi
            if [[ "${color[$dep]:-0}" == "0" ]]; then
                _dfs_cycle "$dep" "${path} -> $dep"
                if [[ "$cycle_found" == "true" ]]; then
                    return 0
                fi
            fi
        done
        color["$node"]=2  # black
    }

    local c
    for c in $valid_containers; do
        if [[ "${color[$c]:-0}" == "0" ]]; then
            _dfs_cycle "$c"
            if [[ "$cycle_found" == "true" ]]; then
                printf '::error::Cycle detected in container dependency graph: %s\n' "$cycle_path" >&2
                return 1
            fi
        fi
    done

    return 0
}
