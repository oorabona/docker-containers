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
#
# Resolve the sibling helper from THIS file's own directory (BASH_SOURCE),
# never via PROJECT_ROOT. PROJECT_ROOT is a data-lookup override and must not
# select which code is sourced (source-hijack / breaks when PROJECT_ROOT is
# stale or set to a test fixture path).
# ---------------------------------------------------------------------------
_depgraph_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lineage-utils.sh
source "${_depgraph_dir}/lineage-utils.sh"
unset _depgraph_dir

# ---------------------------------------------------------------------------
# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a `::keyword::value` GitHub Actions
# workflow command.  Without this, a newline/CR/`%` in the value could
# terminate the command early and inject another (e.g. `::set-env::`,
# `::add-mask::`, `::stop-commands::`).  Mapping per GitHub runner spec:
#   %  → %25
#   \n → %0A
#   \r → %0D
#
# Pattern sourced from helpers/base-cache-utils.sh::_escape_gha_command;
# inlined here to avoid importing the full base-cache helper (which has
# set -euo pipefail and sources logging.sh/variant-utils.sh at parse time,
# breaking this file's explicit no-pipefail contract).
# ---------------------------------------------------------------------------
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

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
        if ! _make_out=$(cd "$PROJECT_ROOT" && ./make list 2>/dev/null); then
            echo "::error::Failed to enumerate project containers via './make list'" >&2
            return 1
        fi
        # Filter to strict container-name lines only (defense in depth: drops any
        # banner/diagnostic output that may have leaked into stdout, same charset
        # as the validator in cascade-resolver.yaml line 76).
        _make_out=$(printf '%s' "$_make_out" | grep -E '^[a-z0-9_-]+$' || true)
        if [[ -z "$_make_out" ]]; then
            echo "::error::'./make list' returned empty container set" >&2
            return 1
        fi
        printf '%s' "$(printf '%s' "$_make_out" | tr '\n' ' ')"
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
    printf '::error::Cannot parse project owner from git remote URL: %s\n' "$(_escape_gha_command "$remote_url")" >&2
    return 1
}

# ---------------------------------------------------------------------------
# _depgraph_is_internal_ref <base_image_ref> <valid_containers_space_sep>
#
# Outputs the parent container name if the ref is project-internal; empty otherwise.
# Matches patterns (only when <owner> == project owner):
#   ghcr.io/<owner>/<X>:<tag>
#   hub.docker.io/<owner>/<X>:<tag>  (Docker Hub mirror — hub.docker.io alias)
#   docker.io/<owner>/<X>:<tag>      (Docker Hub mirror — docker.io alias, same registry)
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

    # ${REMOTE_CR}/<name>:<tag> — always trusted; no owner resolution needed.
    # Match BEFORE the owner-dependent registries so an environment without a
    # usable owner source (CI fork, test fixture, local sandbox) still resolves
    # the ref instead of returning rc=2 (owner-resolution failure).
    if [[ "$ref" == "${remote_cr_prefix}"* && "$normalized_ref" =~ ^([^:/@ ]+) ]]; then
        parent="${BASH_REMATCH[1]}"
        [[ -n "$parent" ]] || return 0
        if [[ " $valid_containers " == *" $parent "* ]]; then
            printf '%s' "$parent"
        fi
        return 0
    fi

    # Resolve project owner (fail-closed: if undetermined, treat ref as external)
    local owner
    if ! owner=$(_depgraph_project_owner 2>/dev/null); then
        # rc=2 distinguishes owner-resolution failure from "external ref" (rc=0+empty).
        # Callers must check rc explicitly; treating this as "not internal" silently
        # bypasses the internal-ref classification and is wrong.
        return 2
    fi

    # Match owner-dependent registries.
    # Patterns:
    #   ghcr.io/<owner>/<name>:<tag>            → after ghcr.io/<owner>/, take <name>
    #   hub.docker.io/<owner>/<name>:<tag>      → after hub.docker.io/<owner>/, take <name>
    #   docker.io/<owner>/<name>:<tag>          → same registry as hub.docker.io, different alias
    if [[ "$normalized_ref" =~ ^ghcr\.io/([^/]+)/([^:/@ ]+) ]]; then
        if [[ "${BASH_REMATCH[1]}" == "$owner" ]]; then
            parent="${BASH_REMATCH[2]}"
        fi
    elif [[ "$normalized_ref" =~ ^(hub\.docker\.io|docker\.io)/([^/]+)/([^:/@ ]+) ]]; then
        # hub.docker.io and docker.io are aliases for the same registry
        if [[ "${BASH_REMATCH[2]}" == "$owner" ]]; then
            parent="${BASH_REMATCH[3]}"
        fi
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

    # Glob lineage files FIRST — the active-tag filter only makes sense when files
    # exist (it drops stale entries from existing lineage).  For a container with NO
    # lineage files yet (e.g. not yet built) the filter must be skipped so the
    # function falls through to the config.yaml fallback.
    shopt -s nullglob
    local lineage_files=("${lineage_dir}/${container}-"*.json "${lineage_dir}/${container}.json")
    shopt -u nullglob

    # Determine whether any non-sidecar lineage files exist BEFORE running the
    # active-tag filter.  The filter is only meaningful (and its fail-closed
    # semantics only applicable) when lineage files are present.
    local _has_lineage=false
    local _lf
    for _lf in "${lineage_files[@]}"; do
        [[ -f "$_lf" ]] || continue
        local _bn; _bn="$(basename "$_lf")"
        if ! is_lineage_sidecar "$_bn"; then
            _has_lineage=true
            break
        fi
    done

    # ---------------------------------------------------------------------------
    # Active-tag filter (Defect N fix)
    #
    # Stale lineage files for retired variants persist in .build-lineage/ after
    # version rotation.  Without filtering, _depgraph_get_deps unions parents from
    # EVERY file — including files whose variants are no longer in the active build
    # matrix.  The consumer that was rebuilt against a now-retired parent gets a
    # cascade:waiting-for-<retired-parent> label; cascade-resolver never fires
    # because the parent has no active build → child stranded indefinitely.
    #
    # Strategy: Option B (./make list-builds) — fail-closed.
    # detect-base-digest-drift.sh uses the same enumeration with the same semantics.
    # A transient list-builds failure must not resurrect retired-variant lineage files:
    # that would misclassify a leaf as a consumer and strand the child PR behind a
    # cascade:waiting-for-<retired-parent> label that nothing will ever resolve.
    # On failure, _depgraph_get_deps returns rc=2 and the caller skips this container
    # for this cron run.  Operator re-runs the workflow once the underlying issue is fixed.
    #
    # FIX 2: When NO lineage files exist for the container (not yet built), skip the
    # active-tag filter entirely and proceed directly to the config.yaml fallback.
    # The filter's purpose is to drop stale entries from EXISTING lineage; with no
    # lineage there is nothing to filter and ./make list-builds is irrelevant.
    # The Defect-N fail-closed guarantee (lineage-present + list-builds failure → rc=2)
    # is preserved: it only triggers when _has_lineage=true.
    #
    # Test hook: _DEPGRAPH_ACTIVE_TAGS_OVERRIDE_<container> (hyphens → underscores)
    # Set to a newline-separated list to bypass ./make list-builds in tests.
    # Set to __TEST_NO_FILTER__ to disable filtering entirely (legacy test mode).
    # ---------------------------------------------------------------------------
    local _active_tags_for_filter=""
    local _at_filter_override_var="_DEPGRAPH_ACTIVE_TAGS_OVERRIDE_${container//-/_}"
    if [[ "$_has_lineage" == "false" ]]; then
        # No lineage files — skip the active-tag filter; fall through to config.yaml.
        _active_tags_for_filter="__TEST_NO_FILTER__"
    elif [[ -n "${!_at_filter_override_var+x}" ]]; then
        # Test hook: use override verbatim (may be empty or __TEST_NO_FILTER__)
        _active_tags_for_filter="${!_at_filter_override_var}"
    elif [[ -n "${_DEPGRAPH_CONTAINERS_OVERRIDE:-}" ]]; then
        # Test-mode detected (_DEPGRAPH_CONTAINERS_OVERRIDE is the existing test hook
        # for synthetic container sets) but no per-container active-tags override —
        # disable filtering so existing tests are not broken by the new filter.
        _active_tags_for_filter="__TEST_NO_FILTER__"
    else
        # Production mode: enumerate active tags via ./make list-builds — FAIL-CLOSED.
        # Only reached when _has_lineage=true (lineage files exist to filter).
        local _lb_out _lb_rc=0
        _lb_out=$(cd "${PROJECT_ROOT}" && ./make list-builds "$container" current 2>/dev/null) || _lb_rc=$?
        if [[ $_lb_rc -ne 0 ]]; then
            printf '::error::_depgraph_get_deps: ./make list-builds %s failed (rc=%s); refusing to proceed (fail-closed)\n' \
                "$(_escape_gha_command "$container")" "$_lb_rc" >&2
            return 2
        fi
        _active_tags_for_filter=$(printf '%s' "$_lb_out" | jq -r '.[].tag // empty' 2>/dev/null | sort -u || echo "")
        if [[ -z "$_active_tags_for_filter" ]]; then
            printf '::error::_depgraph_get_deps: ./make list-builds %s returned no tags; refusing to proceed (fail-closed)\n' \
                "$(_escape_gha_command "$container")" >&2
            return 2
        fi
    fi

    local found_any=false
    local _saw_nonauthoritative=false
    for lineage_file in "${lineage_files[@]}"; do
        [[ -f "$lineage_file" ]] || continue
        local basename_file
        basename_file="$(basename "$lineage_file")"
        # Skip sidecar files BEFORE marking found_any; a container with only sidecars
        # must fall through to the config.yaml fallback path.
        if is_lineage_sidecar "$basename_file"; then continue; fi

        # Active-tag filter: skip lineage files whose tag is not in the active
        # build matrix (stale files from retired variants).  The only bypass is
        # __TEST_NO_FILTER__ (test mode); in production _active_tags_for_filter
        # is always non-empty here (fail-closed above guarantees it).
        if [[ "$_active_tags_for_filter" != "__TEST_NO_FILTER__" && -n "$_active_tags_for_filter" ]]; then
            local _file_tag
            _file_tag=$(jq -r '.tag // empty' "$lineage_file" 2>/dev/null || true)
            if [[ -n "$_file_tag" ]] && ! grep -qxF -- "$_file_tag" <<<"$_active_tags_for_filter"; then
                printf '::notice::_depgraph_get_deps: skipping stale lineage %s (tag %s not in active matrix)\n' \
                    "$(_escape_gha_command "$(basename "$lineage_file")")" "$(_escape_gha_command "$_file_tag")" >&2
                continue
            fi
        fi

        local base_ref
        base_ref=$(jq -r '.base_image_ref // empty' "$lineage_file" 2>/dev/null || true)

        # A lineage entry is authoritative (may suppress config.yaml fallback) only
        # when its base_image_ref is present AND fully resolved.  An empty ref, or
        # one carrying an unresolved ${...} placeholder (other than the trusted
        # ${REMOTE_CR}/ prefix), is non-informative and must not set found_any.
        # SC2016 disabled: single-quote assignments store literal ${ strings intentionally
        # shellcheck disable=SC2016
        local _dollar_brace='${'
        # shellcheck disable=SC2016
        local _remote_cr_prefix='${REMOTE_CR}/'
        if [[ -z "$base_ref" ]] || \
           { [[ "$base_ref" == *"${_dollar_brace}"* ]] && \
             [[ "$base_ref" != "${_remote_cr_prefix}"* ]]; }; then
            # Non-authoritative placeholder — lineage is INCOMPLETE for this container.
            # Record that we saw a non-authoritative entry so the config.yaml fallback
            # fires as a union even if another variant produced an authoritative entry
            # (conservative: may over-include a dep, never under-include).
            _saw_nonauthoritative=true
            continue
        fi

        # Mark that at least one authoritative lineage entry exists
        found_any=true

        local parent _iref_rc
        parent=$(_depgraph_is_internal_ref "$base_ref" "$valid_containers")
        _iref_rc=$?
        if [[ $_iref_rc -eq 2 ]]; then
            printf '::error::Owner resolution failed; cannot classify '"'"'%s'"'"' — aborting dep scan\n' "$(_escape_gha_command "$base_ref")" >&2
            return 2
        fi
        [[ -n "$parent" ]] || continue
        [[ "$parent" == "$container" ]] && continue  # no self-deps

        # Deduplicate
        if [[ " $deps " != *" $parent "* ]]; then
            deps="$deps $parent"
        fi
    done

    # Fallback: parse config.yaml build_args AND base_image if no lineage exists OR
    # if any active lineage entry was a non-authoritative placeholder.
    #
    # The non-authoritative case: in a mixed active-variant set, one variant may have
    # a fully resolved external ref (setting found_any=true) while a different variant
    # carries a placeholder for an INTERNAL parent (e.g. ghcr.io/<owner>/debian:${TAG}).
    # Because found_any is true, the old guard "[[ found_any == false ]]" skipped
    # config.yaml — dropping the internal dep and misclassifying the consumer as a leaf.
    # Fix: union config.yaml whenever _saw_nonauthoritative=true, regardless of found_any.
    # The dedup loop below ensures no dep appears twice.
    #
    # Both fields can carry internal refs:
    #   build_args: key-value pairs injected into docker build --build-arg
    #   base_image: direct base image for Dockerfile FROM (e.g. wordpress, web-shell, github-runner)
    # The same four-prefix recognition applies to both fields.
    if [[ "$found_any" == "false" || "$_saw_nonauthoritative" == "true" ]]; then
        local config_file="${PROJECT_ROOT}/${container}/config.yaml"
        if [[ -f "$config_file" ]]; then
            # Extract all string values from build_args AND base_image that look like internal refs
            local build_args_refs
            build_args_refs=$(grep -oE '(ghcr\.io/[^/]+/[^:/ ]+|hub\.docker\.io/[^/]+/[^:/ ]+|docker\.io/[^/]+/[^:/ ]+|\$\{REMOTE_CR\}/[^:/ ]+)' \
                "$config_file" 2>/dev/null || true)
            while IFS= read -r ref; do
                [[ -n "$ref" ]] || continue
                local parent _iref_rc
                parent=$(_depgraph_is_internal_ref "$ref" "$valid_containers")
                _iref_rc=$?
                if [[ $_iref_rc -eq 2 ]]; then
                    printf '::error::Owner resolution failed; cannot classify '"'"'%s'"'"' — aborting dep scan\n' "$(_escape_gha_command "$ref")" >&2
                    return 2
                fi
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
        local deps _deps_rc
        deps=$(_depgraph_get_deps "$node")
        _deps_rc=$?
        if [[ $_deps_rc -ne 0 ]]; then
            printf '::error::_depgraph_get_deps failed for %s (rc=%s) during transitive dep traversal; aborting (fail-closed)\n' "$(_escape_gha_command "$node")" "$_deps_rc" >&2
            return $_deps_rc
        fi
        if [[ -n "$deps" ]]; then
            local dep
            for dep in $deps; do
                _depgraph_dfs_topo "$dep" || return $?
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

    _depgraph_dfs_topo "$container" || return $?
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
    local valid_containers _vc_rc
    valid_containers="$(_depgraph_valid_containers)"
    _vc_rc=$?
    [[ $_vc_rc -ne 0 ]] && return $_vc_rc

    local c
    for c in $valid_containers; do
        [[ "$c" == "$target" ]] && continue
        local deps _deps_rc
        deps=$(_depgraph_get_deps "$c")
        _deps_rc=$?
        if [[ $_deps_rc -ne 0 ]]; then
            printf '::error::_depgraph_get_deps failed for %s (rc=%s) during consumer scan; aborting (fail-closed)\n' "$(_escape_gha_command "$c")" "$_deps_rc" >&2
            return $_deps_rc
        fi
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
    local valid_containers _vc_rc
    valid_containers="$(_depgraph_valid_containers)"
    _vc_rc=$?
    [[ $_vc_rc -ne 0 ]] && return $_vc_rc
    local -A color  # 0=white, 1=gray (in-stack), 2=black (done)
    local cycle_found=false
    local cycle_path=""

    _dfs_cycle() {
        local node="$1"
        local path="${2:-$node}"

        color["$node"]=1  # gray
        local deps _deps_rc
        deps=$(_depgraph_get_deps "$node")
        _deps_rc=$?
        if [[ $_deps_rc -ne 0 ]]; then
            printf '::error::_depgraph_get_deps failed for %s (rc=%s) during cycle detection; aborting (fail-closed)\n' "$(_escape_gha_command "$node")" "$_deps_rc" >&2
            return $_deps_rc
        fi
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
                local _dfs_rc=$?
                if [[ $_dfs_rc -ne 0 ]]; then
                    return $_dfs_rc
                fi
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
            local _top_rc=$?
            if [[ $_top_rc -ne 0 ]]; then
                return $_top_rc
            fi
            if [[ "$cycle_found" == "true" ]]; then
                printf '::error::Cycle detected in container dependency graph: %s\n' "$(_escape_gha_command "$cycle_path")" >&2
                return 1
            fi
        fi
    done

    return 0
}
