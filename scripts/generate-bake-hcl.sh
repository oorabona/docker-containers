#!/usr/bin/env bash
# generate-bake-hcl.sh — Synthesise a docker buildx bake definition (JSON) to
# stdout from the repo's canonical metadata, driven by the ADR-013
# dependency-ordered build.
#
# Usage:
#   scripts/generate-bake-hcl.sh                  # whole fleet
#   scripts/generate-bake-hcl.sh wordpress         # wordpress + dep closure
#   scripts/generate-bake-hcl.sh github-runner     # github-runner + debian dep
#
# Output is a JSON bake file (same schema as HCL; docker-buildx bake -f -)
# written to stdout.  It is a generated artifact — do NOT commit it.
# Source of truth: <container>/variants.yaml + <container>/config.yaml.
#
# Enumerator: helpers/variant-utils.sh::list_build_matrix — the same canonical
# per-container build-cell enumerator used by the real CI pipeline.
#
# Template containers (ADR-006) — Dockerfile contains @@MARKER@@ placeholders.
# The generator expands them IN MEMORY and emits dockerfile-inline in the bake
# target (no working-tree file written; compatible with --print and real builds):
#   web-shell     — generate-dockerfile.sh <template> <flavor> <version>
#   github-runner — generate-dockerfile.sh <template> <flavor> <version> <build_flavor>
#   postgres      — uses single Dockerfile + FLAVOR build-arg (no template markers)
#
# CUSTOM_BUILD_ARGS: operator-supplied extra args are applied at the R3 merge-job
# layer via `bake --set "*.args.KEY=VAL"`, NOT embedded here.
#
# Requirements:
#   bash 4+, yq (mikefarah v4), jq

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve PROJECT_ROOT (parent of the scripts/ directory)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# REMOTE_CR resolved ONCE at generation time from the environment.
# All emitted refs (tags, args.REMOTE_CR, contexts keys, intermediate_ref) use
# this concrete value — no bake-time variable.  Override at generation with
#   REMOTE_CR=myreg.io/myorg ./scripts/generate-bake-hcl.sh …
# ARCH_SUFFIX and NPROC remain bake-time variables (they genuinely vary per arch/job).
readonly _BAKE_REMOTE_CR="${REMOTE_CR:-ghcr.io/oorabona}"

# ---------------------------------------------------------------------------
# Source helpers — variant enumerator + dependency graph + build-args utils
# ---------------------------------------------------------------------------
# shellcheck source=../helpers/variant-utils.sh
source "${PROJECT_ROOT}/helpers/variant-utils.sh"

# Force config-only dep resolution (no ./make list-builds fan-out needed).
# The generator runs before any build lineage exists.
export _DEPGRAPH_LINEAGE_DIR=/nonexistent
# shellcheck source=../helpers/dependency-graph.sh
source "${PROJECT_ROOT}/helpers/dependency-graph.sh"

# build-args-utils provides build_args_json (config.yaml build_args as JSON).
# shellcheck source=../helpers/logging.sh
source "${PROJECT_ROOT}/helpers/logging.sh"
# shellcheck source=../helpers/build-args-utils.sh
source "${PROJECT_ROOT}/helpers/build-args-utils.sh"
# validate-base-cache-schema provides _vbc_validate_build_args_config — the
# canonical fail-closed validator for config.yaml build_args entries.
# shellcheck source=../helpers/validate-base-cache-schema.sh
source "${PROJECT_ROOT}/helpers/validate-base-cache-schema.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Sanitise a string to a valid bake target identifier.
# Dots, hyphens, slashes → underscores; leading digit → "v" prefix.
# Only [A-Za-z_][A-Za-z0-9_]* is valid.
_target_id() {
    local s="$1"
    s="${s//[.\-\/]/_}"
    if [[ "$s" =~ ^[0-9] ]]; then
        s="v${s}"
    fi
    printf '%s' "$s"
}

# Assert a string is a valid bake target identifier; fail loudly if not.
_assert_id() {
    local id="$1" ctx="${2:-identifier}"
    if [[ ! "$id" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'ERROR: %s is not a valid bake target identifier: %q\n' "$ctx" "$id" >&2
        return 1
    fi
}

# Assert a build_arg key is valid (^[A-Za-z_][A-Za-z0-9_]*$); fail loudly.
_assert_arg_key() {
    local key="$1"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'ERROR: invalid build_arg key %q in config.yaml — must match ^[A-Za-z_][A-Za-z0-9_]*$\n' "$key" >&2
        return 1
    fi
}

# Enumerate all containers from `./make list`, strictly filtered to container-
# name characters to drop any diagnostic noise.
_list_all_containers() {
    local out
    if ! out=$(cd "${PROJECT_ROOT}" && ./make list 2>/dev/null); then
        printf 'ERROR: ./make list failed\n' >&2
        return 1
    fi
    printf '%s' "$out" | grep -E '^[a-z0-9_-]+$' || true
}

# Expand a list of requested container names to their transitive dep closure,
# in topological order (leaves first).  Output: one name per line.
_expand_closure() {
    local -a requested=("$@")
    local -a closure=()

    _add_unique() {
        local item="$1"
        local e
        for e in "${closure[@]:-}"; do
            [[ "$e" == "$item" ]] && return 0
        done
        closure+=("$item")
    }

    local c
    for c in "${requested[@]}"; do
        local deps
        # Fail-closed on graph errors: empty output with rc=0 is the normal leaf
        # case (no internal deps); non-zero means a genuine graph failure that
        # would silently drop required base-image contexts if coerced to "".
        if ! deps="$(_depgraph_get_deps_transitive "$c")"; then
            printf '::error::dependency-graph resolution failed for %s — refusing to emit an incomplete bake graph (would drop required internal base contexts)\n' \
                "$c" >&2
            return 1
        fi
        local dep
        for dep in ${deps}; do
            # F1: extension containers must not appear in the closure even as deps.
            if _is_extension_container "$dep"; then
                printf '::notice::Skipping %s from bake graph (extension sub-pipeline owns it; see build-extensions)\n' \
                    "$dep" >&2
                continue
            fi
            _add_unique "$dep"
        done
        _add_unique "$c"
    done

    printf '%s\n' "${closure[@]:-}"
}

# ---------------------------------------------------------------------------
# Dockerfile resolution for a build cell.
#
# Uses the matrix cell's .dockerfile field VERBATIM — never reconstruct it.
# list_build_matrix already encodes the correct path from variants.yaml.
#
# Fallback precedence when .dockerfile is empty (not set in variants.yaml):
#   1. web-shell with flavor → Dockerfile.<flavor>  (generator pre-step)
#   2. Everything else      → Dockerfile
# ---------------------------------------------------------------------------
_resolve_dockerfile() {
    local container="$1"
    local matrix_dockerfile="$2"
    local flavor="$3"
    # build_flavor kept for API compatibility; unused here.
    # shellcheck disable=SC2034
    local build_flavor="$4"

    # Use the matrix-provided dockerfile verbatim when non-empty.
    if [[ -n "$matrix_dockerfile" ]]; then
        printf '%s' "$matrix_dockerfile"
        return 0
    fi

    # Empty dockerfile field — apply conventional fallback.
    case "$container" in
        web-shell)
            if [[ -n "$flavor" ]]; then
                printf 'Dockerfile.%s' "$flavor"
            else
                printf 'Dockerfile'
            fi
            ;;
        *)
            printf 'Dockerfile'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Build-args from config.yaml for a container.
# Delegates to helpers/build-args-utils.sh::build_args_json (canonical source).
# Returns a compact jq JSON object {"KEY":"VALUE",...}
#
# DEFECT 1 FIX: before returning, calls the canonical fail-closed validator
# _vbc_validate_build_args_config (helpers/validate-base-cache-schema.sh:266).
# It rejects: REMOTE_CR key, non-identifier keys, non-scalar values, and
# shell-unsafe values.  Keeps _assert_arg_key as belt-and-suspenders.
# ---------------------------------------------------------------------------
_config_build_args() {
    local container="$1"
    local container_dir="${PROJECT_ROOT}/${container}"
    local config="${container_dir}/config.yaml"
    [[ -f "$config" ]] || { printf '{}'; return 0; }

    local raw
    raw=$(build_args_json "$container_dir") || { printf '{}'; return 0; }

    # Canonical validator (fail-closed): rejects REMOTE_CR key, non-identifier
    # keys, non-scalar/shell-unsafe values.  Failure aborts generation.
    if ! _vbc_validate_build_args_config "$container" "$config"; then
        printf '::error::container %s: config.yaml build_args failed validation\n' "$container" >&2
        return 1
    fi

    # Belt-and-suspenders: also validate each key via the identifier regex.
    local keys
    keys=$(jq -r 'keys[]' <<< "$raw" 2>/dev/null) || { printf '%s' "$raw"; return 0; }
    local key
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        _assert_arg_key "$key" || return 1
    done <<< "$keys"

    printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# Materialize a template Dockerfile IN MEMORY for a given build cell.
#
# DEFECT 2 FIX: template Dockerfiles (those containing @@MARKER@@ patterns)
# are expanded via the container's own generate-dockerfile.sh to a string,
# then emitted as dockerfile-inline in the bake target — no file is written.
#
# Args: <container> <template_path_rel_to_container> <flavor> <version> <build_flavor>
# Returns: 0 and prints expanded content on stdout
#          non-0 on generator failure or remaining @@ markers after expansion
# ---------------------------------------------------------------------------
_materialize_dockerfile() {
    local container="$1"
    local template_rel="$2"    # relative to container dir (e.g. "Dockerfile.linux")
    local flavor="$3"
    local version="$4"
    local build_flavor="$5"

    local generator="${PROJECT_ROOT}/${container}/generate-dockerfile.sh"

    if [[ ! -x "$generator" ]]; then
        printf 'ERROR: template container %s has no generate-dockerfile.sh\n' "$container" >&2
        return 1
    fi

    local content
    # Convention from build-container.sh L505:
    #   "$PROJECT_ROOT/$container/generate-dockerfile.sh" "$dockerfile" "${flavor:-}" "$version" "${build_flavor:-}"
    # Run from the container's own directory so that relative template paths
    # (e.g. "Dockerfile") resolve correctly inside expand_template().
    # Both github-runner (4-arg via parse_generator_args) and web-shell (3-arg)
    # accept this 4-arg call; extra args are safely ignored.
    content=$(cd "${PROJECT_ROOT}/${container}" && \
        "${generator}" "$template_rel" "${flavor:-}" "$version" "${build_flavor:-}" 2>/dev/null)
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        printf 'ERROR: generate-dockerfile.sh failed for %s (flavor=%s version=%s build_flavor=%s)\n' \
            "$container" "$flavor" "$version" "$build_flavor" >&2
        return 1
    fi

    # Verify no @@ markers remain after expansion.
    if printf '%s' "$content" | grep -qE '@@[A-Z_]+@@' 2>/dev/null; then
        printf 'ERROR: unexpanded @@ markers remain in generated Dockerfile for %s (flavor=%s)\n' \
            "$container" "$flavor" >&2
        return 1
    fi

    printf '%s' "$content"
}

# ---------------------------------------------------------------------------
# Compute the complete build-args JSON object for one build cell.
# Replicates helpers/build-args-utils.sh::prepare_build_args exactly:
#
#   1. config.yaml build_args entries (base layer)
#   2. VERSION=<version>
#   3. MAJOR_VERSION=<leading-integer> (when extractable)
#   4. UPSTREAM_VERSION=<upstream>     (when version.sh --upstream succeeds
#                                       AND its output differs from version)
#   5. FLAVOR=<effective_build_flavor> (when non-empty; effective_build_flavor
#                                       is build_flavor || flavor, mirroring
#                                       build_container's "$6:-$4" fallback)
#   6. REMOTE_CR=<concrete>            (resolved once from env at generation time)
#   7. NPROC="${NPROC}"               (bake variable, only when Dockerfile
#                                       declares ARG NPROC; see DEFECT 3 FIX)
#
# Args: <container> <version> <flavor> <build_flavor> <config_args_json>
#       <dockerfile_content_or_path>  <is_inline>
#   is_inline=1 → dockerfile_content_or_path is the full content (string)
#   is_inline=0 → dockerfile_content_or_path is an absolute path to the file
# Output: compact JSON {"KEY":"VALUE",...}
# ---------------------------------------------------------------------------
_compute_cell_build_args() {
    local container="$1"
    local version="$2"
    local flavor="$3"
    local build_flavor="$4"
    local config_args="$5"     # pre-computed _config_build_args output
    local df_content_or_path="${6:-}"
    local is_inline="${7:-0}"

    # Start from config.yaml build_args; overlay computed args so VERSION etc.
    # always win over any accidental config key collision.
    local args
    args="$config_args"

    # 2. VERSION
    args=$(jq -cn --argjson base "$args" --arg v "$version" '$base + {VERSION: $v}')

    # 3. MAJOR_VERSION (leading integer: "18" from "18-alpine", "2" from "2.334.0")
    local major
    major=$(printf '%s' "$version" | grep -oE '^[0-9]+' | head -1 || true)
    if [[ -n "$major" ]]; then
        args=$(jq -cn --argjson base "$args" --arg m "$major" '$base + {MAJOR_VERSION: $m}')
    fi

    # 4. UPSTREAM_VERSION — mirrors prepare_build_args: run version.sh --upstream
    #    from the container directory; emit only when non-empty AND != version.
    local version_sh="${PROJECT_ROOT}/${container}/version.sh"
    if [[ -x "$version_sh" ]]; then
        local upstream
        upstream=$(cd "${PROJECT_ROOT}/${container}" && ./version.sh --upstream 2>/dev/null || true)
        if [[ -n "$upstream" && "$upstream" != "$version" ]]; then
            args=$(jq -cn --argjson base "$args" --arg u "$upstream" \
                '$base + {UPSTREAM_VERSION: $u}')
        fi
    fi

    # 5. FLAVOR — explicit build_flavor takes priority, else fall back to flavor.
    #    Mirrors build_container parameter default: local build_flavor="${6:-$flavor}".
    local effective_flavor="${build_flavor:-$flavor}"
    if [[ -n "$effective_flavor" ]]; then
        args=$(jq -cn --argjson base "$args" --arg f "$effective_flavor" \
            '$base + {FLAVOR: $f}')
    fi

    # 6. REMOTE_CR — concrete generation-time value (resolved once from env at startup).
    #    Using a concrete value (not a bake variable token) ensures args.REMOTE_CR and
    #    the contexts key always match, regardless of any bake-time override.
    args=$(jq -cn --argjson base "$args" --arg rcr "$_BAKE_REMOTE_CR" '$base + {REMOTE_CR: $rcr}')

    # 7. NPROC (DEFECT 3 FIX) — inject only when the Dockerfile declares ARG NPROC.
    #    Avoids Docker "unused build-arg" warnings for containers that don't use it.
    #    The NPROC bake variable is declared in the document header (default "1");
    #    CI sets NPROC env var for parallel builds.
    #    NOTE: CUSTOM_BUILD_ARGS are an R3 concern — applied via `bake --set "*.args.KEY=VAL"`
    #    at the merge-job layer, never embedded in this generated document.
    local declares_nproc=false
    if [[ -n "$df_content_or_path" ]]; then
        if [[ "$is_inline" == "1" ]]; then
            if printf '%s' "$df_content_or_path" | grep -qE '^ARG[[:space:]]+NPROC([[:space:]=]|$)' 2>/dev/null; then
                declares_nproc=true
            fi
        else
            if [[ -f "$df_content_or_path" ]] && \
               grep -qE '^ARG[[:space:]]+NPROC([[:space:]=]|$)' "$df_content_or_path" 2>/dev/null; then
                declares_nproc=true
            fi
        fi
    fi
    if [[ "$declares_nproc" == "true" ]]; then
        args=$(jq -cn --argjson base "$args" '$base + {NPROC: "${NPROC}"}')
    fi

    printf '%s' "$args"
}

# ---------------------------------------------------------------------------
# Resolve the base image reference that a specific build cell's Dockerfile
# uses at runtime, after substituting ARG defaults and build_args.
#
# Important constraints:
#   - "${REMOTE_CR}" is a declared bake variable — never substitute it.
#     Leave the literal string "${REMOTE_CR}" so bake resolves it at print time.
#   - For unresolved "${KEY}" where KEY is an ARG with a known default from the
#     Dockerfile or config, substitute that default.
#
# DEFECT 2 FIX: for template cells (is_inline=1), the FROM is extracted from
# the in-memory materialized content, not a file.  Non-template cells unchanged.
#
# Args: <container> <dockerfile_or_content> <flavor> <config> <is_inline>
#   is_inline=1 → 2nd arg is the full materialized content
#   is_inline=0 → 2nd arg is the Dockerfile path relative to container dir
# Returns the resolved FROM string on stdout, or empty if undeterminable.
# ---------------------------------------------------------------------------
_resolve_cell_base_ref() {
    local container="$1"
    local df_or_content="$2"   # path (relative to container) OR content string
    local flavor="$3"
    local config="${4:-${PROJECT_ROOT}/${container}/config.yaml}"
    local is_inline="${5:-0}"

    # Apply variable substitutions to a ref string.
    # REMOTE_CR is excluded here — it is already substituted concretely via
    # _BAKE_REMOTE_CR after this function returns (see callers below).
    _subst_args() {
        local ref="$1"
        local entries="$2"
        local k v
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] || continue
            [[ "$k" == "REMOTE_CR" ]] && continue   # handled separately below
            ref="${ref//\$\{${k}\}/${v}}"
            ref="${ref//\$${k}/${v}}"
        done <<< "$entries"
        printf '%s' "$ref"
    }

    local df_text=""

    if [[ "$is_inline" == "1" ]]; then
        # Template cell: content is already in memory
        df_text="$df_or_content"
    else
        # Committed file cell.
        # F3: _on_cell_bake passes an ABSOLUTE path; guard against double-prefixing.
        local abs_dockerfile
        if [[ "$df_or_content" == /* && -f "$df_or_content" ]]; then
            abs_dockerfile="$df_or_content"
        else
            abs_dockerfile="${PROJECT_ROOT}/${container}/${df_or_content}"
        fi
        [[ -f "$abs_dockerfile" ]] || { printf ''; return 0; }
        df_text=$(< "$abs_dockerfile")
    fi

    if [[ -n "$df_text" ]]; then
        # Collect ARG KEY=default lines before the first FROM
        local arg_entries=""
        local line
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*FROM[[:space:]] ]]; then break; fi
            # ARG KEY=value  or  ARG KEY="value"
            if [[ "$line" =~ ^[[:space:]]*ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                local akey="${BASH_REMATCH[1]}"
                local aval="${BASH_REMATCH[2]}"
                aval="${aval%\"}" ; aval="${aval#\"}"
                aval="${aval%\'}" ; aval="${aval#\'}"
                arg_entries="${arg_entries}${akey}"$'\t'"${aval}"$'\n'
            fi
        done <<< "$df_text"

        # Extract first non-AS FROM line
        local from_line
        from_line=$(printf '%s' "$df_text" | grep -m1 -E '^FROM ') || from_line=""
        local raw_ref
        raw_ref=$(awk '{print $2}' <<< "$from_line") || raw_ref=""
        [[ -z "$raw_ref" ]] && { printf ''; return 0; }

        # Substitute ARG defaults first, then build_args (build_args override)
        local resolved="$raw_ref"
        resolved=$(_subst_args "$resolved" "$arg_entries")

        if [[ -f "$config" ]]; then
            local build_entries
            build_entries=$(yq e '.build_args // {} | to_entries | .[] | .key + "\t" + .value' \
                "$config" 2>/dev/null) || build_entries=""
            resolved=$(_subst_args "$resolved" "$build_entries")
        fi

        # Concretise the REMOTE_CR token so the contexts key is a concrete registry
        # ref (e.g. ghcr.io/oorabona/php:latest) that bake can match against the
        # target's resolved FROM without relying on variable interpolation in map keys.
        resolved="${resolved//\$\{REMOTE_CR\}/${_BAKE_REMOTE_CR}}"
        resolved="${resolved//\$REMOTE_CR/${_BAKE_REMOTE_CR}}"

        printf '%s' "$resolved"
        return 0
    fi

    # df_text is empty (file not found for non-inline path) —
    # infer base ref from config.yaml + dep knowledge (web-shell fallback).
    [[ -n "$flavor" && -f "$config" ]] || { printf ''; return 0; }

    local distro_base
    distro_base=$(yq e ".distros.${flavor}.base_image // \"\"" "$config" 2>/dev/null) || distro_base=""
    [[ -z "$distro_base" ]] && { printf ''; return 0; }

    # Strip bash default-value syntax ${VAR:-fallback} → keep fallback
    local resolved="$distro_base"
    if [[ "$resolved" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}$ ]]; then
        resolved="${BASH_REMATCH[1]}"
    fi

    # Substitute build_args (skip REMOTE_CR as above)
    local build_entries
    build_entries=$(yq e '.build_args // {} | to_entries | .[] | .key + "\t" + .value' \
        "$config" 2>/dev/null) || build_entries=""
    resolved=$(_subst_args "$resolved" "$build_entries")

    # Any remaining "${KEY}" pattern: try reading the ARG default from the
    # master template Dockerfile.
    if [[ "$resolved" == *'${'* ]]; then
        local template="${PROJECT_ROOT}/${container}/Dockerfile"
        if [[ -f "$template" ]]; then
            local tline targ_entries=""
            while IFS= read -r tline; do
                if [[ "$tline" =~ ^[[:space:]]*ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.+)$ ]]; then
                    local tkey="${BASH_REMATCH[1]}"
                    local tval="${BASH_REMATCH[2]}"
                    tval="${tval%\"}" ; tval="${tval#\"}"
                    targ_entries="${targ_entries}${tkey}"$'\t'"${tval}"$'\n'
                fi
            done < "$template"
            resolved=$(_subst_args "$resolved" "$targ_entries")
        fi
    fi

    # Last-resort: if an unresolved "${KEY}" still remains in the ref, check if
    # the dep container name appears in the ref (e.g. "debian" in
    # "ghcr.io/oorabona/debian:${DEBIAN_TAG}").  If so, resolve the tag
    # portion from the dep container's first entry in its variants.yaml.
    if [[ "$resolved" == *'${'* ]]; then
        local dep_containers_space
        if ! dep_containers_space="$(_depgraph_get_deps "$container")"; then
            printf '::error::dependency-graph resolution failed for %s — refusing to emit an incomplete bake graph (would drop required internal base contexts)\n' \
                "$container" >&2
            return 1
        fi
        local dep2
        for dep2 in ${dep_containers_space}; do
            if [[ "$resolved" == *"/${dep2}:"* ]]; then
                local dep_first_tag
                dep_first_tag=$(yq e '.versions[0].tag // ""' \
                    "${PROJECT_ROOT}/${dep2}/variants.yaml" 2>/dev/null) || dep_first_tag=""
                if [[ -n "$dep_first_tag" ]]; then
                    resolved=$(printf '%s' "$resolved" | \
                        sed "s|/${dep2}:\\\${[^}]*}|/${dep2}:${dep_first_tag}|g")
                fi
            fi
        done
    fi

    # Concretise REMOTE_CR token in the fallback path as well.
    resolved="${resolved//\$\{REMOTE_CR\}/${_BAKE_REMOTE_CR}}"
    resolved="${resolved//\$REMOTE_CR/${_BAKE_REMOTE_CR}}"

    printf '%s' "$resolved"
}

# ---------------------------------------------------------------------------
# Contexts entry for a specific build cell.
#
# Resolves the cell's actual FROM base ref, checks if it references a
# project-internal dep, and if so produces:
#   { "<FROM-resolved-ref>": "target:<dep-target-id>" }
#
# DEFECT 2 FIX: passes is_inline through to _resolve_cell_base_ref so that
# template cells' FROM is extracted from in-memory content.
# ---------------------------------------------------------------------------
_contexts_for_cell() {
    local container="$1"
    local df_or_content="$2"   # path (relative to container) OR content string
    local flavor="$3"
    local dep_target_ids_json="$4"
    local is_inline="${5:-0}"

    local deps
    if ! deps="$(_depgraph_get_deps "$container")"; then
        printf '::error::dependency-graph resolution failed for %s — refusing to emit an incomplete bake graph (would drop required internal base contexts)\n' \
            "$container" >&2
        return 1
    fi
    [[ -z "$deps" ]] && { printf '{}'; return 0; }

    local base_ref
    base_ref=$(_resolve_cell_base_ref "$container" "$df_or_content" "$flavor" \
        "${PROJECT_ROOT}/${container}/config.yaml" "$is_inline") || base_ref=""
    [[ -z "$base_ref" ]] && { printf '{}'; return 0; }

    local ctx='{}'
    local dep
    for dep in ${deps}; do
        # Check if the resolved base_ref references this dep
        if [[ "$base_ref" == *"/${dep}:"* || "$base_ref" == *"/${dep}" ]]; then
            local dep_target_id
            dep_target_id=$(jq -r --arg d "$dep" '.[$d] // ""' <<< "$dep_target_ids_json") || dep_target_id=""
            [[ -n "$dep_target_id" ]] || continue
            ctx=$(jq -cn --argjson base "$ctx" --arg k "$base_ref" \
                --arg v "target:${dep_target_id}" '$base + {($k): $v}')
        fi
    done

    printf '%s' "$ctx"
}

# ---------------------------------------------------------------------------
# Shared validation + closure builder — common preamble for both modes.
#
# Sets shell variables (in caller's scope via eval-free pattern):
#   _EC_CLOSURE_CONTAINERS  — nameref or positional array not available in bash 4
#   We use a global-ish approach: caller passes arrays by reference via
#   _enumerate_cells_init which populates two associative arrays in the
#   caller's scope:
#     _EC_all_matrix_json[container]        — list_build_matrix JSON array
#     _EC_first_target_per_container[c]     — first target ID (for dep-contexts)
#   and one indexed array:
#     _EC_closure_containers[...]           — topological order
#
# Args: requested_containers[@]
# ---------------------------------------------------------------------------
_enumerate_cells_init() {
    local -a requested_containers=("$@")

    # Validate each requested container against ./make list
    local all_containers_newline
    if ! all_containers_newline="$(_list_all_containers)"; then
        printf 'ERROR: cannot enumerate valid containers\n' >&2
        return 1
    fi

    local c
    for c in "${requested_containers[@]}"; do
        if ! printf '%s\n' "$all_containers_newline" | grep -qxF -- "$c"; then
            printf 'ERROR: unknown container %q — not in ./make list\n' "$c" >&2
            printf 'Valid containers:\n%s\n' "$all_containers_newline" >&2
            return 1
        fi
    done

    # Determine containers to process: transitive dep closure of requested
    _EC_closure_containers=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && _EC_closure_containers+=("$c")
    done < <(_expand_closure "${requested_containers[@]}")

    # Matrix enumeration + first-target-per-container for dep-context lookup
    # F4: use the caller-supplied include_all_retained flag (default false = latest-only).
    local _ec_all_retained="${_BAKE_INCLUDE_ALL_RETAINED:-false}"
    for c in "${_EC_closure_containers[@]}"; do
        local matrix
        if ! matrix=$(list_build_matrix "./${c}" "" "$_ec_all_retained" 2>/dev/null); then
            printf 'ERROR: list_build_matrix failed for %q\n' "$c" >&2
            return 1
        fi
        if ! jq -e 'if type == "array" then true else error("not array") end' \
                <<< "$matrix" >/dev/null 2>&1; then
            printf 'ERROR: list_build_matrix for %q returned non-array JSON\n' "$c" >&2
            return 1
        fi
        _EC_all_matrix_json[$c]="$matrix"

        local first_entry
        first_entry=$(jq -c 'first(.[] | select(.is_latest_version == true)) // .[0]' \
            <<< "$matrix" 2>/dev/null) || first_entry=""
        if [[ -n "$first_entry" && "$first_entry" != "null" ]]; then
            local fver fvariant ftag
            fver=$(jq -r '.version'           <<< "$first_entry")
            fvariant=$(jq -r '.variant // ""' <<< "$first_entry")
            ftag=$(jq -r '.tag'               <<< "$first_entry")

            local ftid
            if [[ -z "$fvariant" ]]; then
                ftid="$(_target_id "${c}_${ftag}")"
            else
                ftid="$(_target_id "${c}_${fver}_${fvariant}")"
            fi
            _EC_first_target_per_container[$c]="$ftid"
        fi
    done
}

# ---------------------------------------------------------------------------
# Core per-cell enumerator — shared by _build_bake_json and _emit_cells_json.
#
# Iterates the closure × matrix, skipping windows cells.
# For each linux cell, calls one of two callbacks:
#
#   _on_cell_bake   <container> <cell_json> <dep_target_ids_json> <config_args>
#   _on_cell_plain  <container> <tag> <flavor> <is_default> <intermediate_ref>
#
# The caller defines whichever callback is needed.  Both modes share the same
# skip logic (os == windows) and the same cell field extraction.
#
# Args: <mode> <dep_target_ids_json> <requested_containers[@]> (mode: bake|cells)
# Context: _EC_closure_containers, _EC_all_matrix_json must be set by
#          _enumerate_cells_init before calling.
# ---------------------------------------------------------------------------
_enumerate_cells() {
    local mode="$1"
    local dep_target_ids_json="$2"
    shift 2
    local -a requested_containers=("$@")

    local c
    for c in "${_EC_closure_containers[@]}"; do
        local matrix="${_EC_all_matrix_json[$c]}"

        # Read config build_args once per container (DEFECT 1: validator fires here).
        # Only needed for bake mode; cells mode skips this expensive step.
        local config_args='{}'
        if [[ "$mode" == "bake" ]]; then
            if ! config_args=$(_config_build_args "$c"); then
                printf 'ERROR: _config_build_args failed for %q\n' "$c" >&2
                return 1
            fi
        fi

        local ncells
        ncells=$(jq 'length' <<< "$matrix")
        local i
        for (( i=0; i<ncells; i++ )); do
            local cell
            cell=$(jq -c ".[$i]" <<< "$matrix")

            local version variant tag flavor build_flavor cell_os cell_dockerfile
            version=$(jq -r '.version'               <<< "$cell")
            variant=$(jq -r '.variant // ""'         <<< "$cell")
            tag=$(jq -r '.tag'                       <<< "$cell")
            flavor=$(jq -r '.flavor // ""'           <<< "$cell")
            build_flavor=$(jq -r '.build_flavor // ""'   <<< "$cell")
            cell_os=$(jq -r '.os // "linux"'         <<< "$cell")
            cell_dockerfile=$(jq -r '.dockerfile // ""' <<< "$cell")
            local is_default
            is_default=$(jq -r 'if .is_default then "true" else "false" end' <<< "$cell")

            # Skip Windows cells — bake/linux-native only.
            if [[ "$cell_os" == "windows" ]]; then
                continue
            fi

            if [[ "$mode" == "cells" ]]; then
                # cells mode: emit compact cell descriptor (no Dockerfile work needed)
                local intermediate_ref="${_BAKE_REMOTE_CR}/${c}:${tag}"
                _on_cell_plain "$c" "$tag" "$flavor" "$is_default" "$intermediate_ref"
            else
                # bake mode: full target construction (original _build_bake_json logic)
                _on_cell_bake "$c" "$cell" "$dep_target_ids_json" "$config_args" \
                    "$version" "$variant" "$tag" "$flavor" "$build_flavor" \
                    "$cell_dockerfile"
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# Bake-mode cell handler — called by _enumerate_cells for each linux cell
# when mode == "bake".  Accumulates into the caller-scope variables:
#   targets_json, container_target_lists[c]
# ---------------------------------------------------------------------------
_on_cell_bake() {
    local c="$1"
    local cell="$2"
    local dep_target_ids_json="$3"
    local config_args="$4"
    local version="$5"
    local variant="$6"
    local tag="$7"
    local flavor="$8"
    local build_flavor="$9"
    local cell_dockerfile="${10}"

    # Compute target ID
    local tid
    if [[ -z "$variant" ]]; then
        tid="$(_target_id "${c}_${tag}")"
    else
        tid="$(_target_id "${c}_${version}_${variant}")"
    fi
    _assert_id "$tid" "target ID for ${c} tag=${tag} variant=${variant}" || return 1

    # Platforms (linux only — windows filtered above)
    local platforms_json='["linux/amd64","linux/arm64"]'

    # Dockerfile (relative to the container context dir)
    local dockerfile
    dockerfile=$(_resolve_dockerfile "$c" "$cell_dockerfile" "$flavor" "$build_flavor")

    # Tags: intermediate-only GHCR ref with arch suffix.
    # REMOTE_CR is concrete (generation-time); ARCH_SUFFIX stays a bake variable
    # (varies per-arch job at bake invocation time).
    local tags_json
    tags_json=$(jq -cn --arg t "${_BAKE_REMOTE_CR}/${c}:${tag}\${ARCH_SUFFIX}" '[$t]')

    # Template Dockerfile detection and materialization (DEFECT 2 FIX)
    local abs_dockerfile="${PROJECT_ROOT}/${c}/${dockerfile}"
    local template_for_gen="$dockerfile"
    local is_inline=0
    local df_content_or_path="$abs_dockerfile"
    local inline_content=""
    local _is_template=false

    if [[ -f "$abs_dockerfile" ]] && grep -qE '@@[A-Z_]+@@' "$abs_dockerfile" 2>/dev/null; then
        _is_template=true
    elif [[ ! -f "$abs_dockerfile" ]]; then
        local base_df="${PROJECT_ROOT}/${c}/Dockerfile"
        if [[ -f "$base_df" ]] && grep -qE '@@[A-Z_]+@@' "$base_df" 2>/dev/null; then
            _is_template=true
            template_for_gen="Dockerfile"
        fi
    fi

    if [[ "$_is_template" == "true" ]]; then
        if ! inline_content=$(_materialize_dockerfile "$c" "$template_for_gen" \
                "$flavor" "$version" "$build_flavor"); then
            printf 'ERROR: template materialization failed for %q (flavor=%q)\n' "$c" "$flavor" >&2
            return 1
        fi
        is_inline=1
        df_content_or_path="$inline_content"
    fi

    # Build args: complete per-cell arg set replicating prepare_build_args.
    local args_json
    if ! args_json=$(_compute_cell_build_args "$c" "$version" "$flavor" \
            "$build_flavor" "$config_args" "$df_content_or_path" "$is_inline"); then
        printf 'ERROR: _compute_cell_build_args failed for %q version=%q\n' "$c" "$version" >&2
        return 1
    fi

    # Multi-stage target: emit "target" when Dockerfile has a named stage for build_flavor.
    local target_stage=""
    if [[ -n "$build_flavor" ]]; then
        local df_text_for_stage=""
        if [[ "$is_inline" == "1" ]]; then
            df_text_for_stage="$df_content_or_path"
        elif [[ -f "$abs_dockerfile" ]]; then
            df_text_for_stage=$(< "$abs_dockerfile")
        fi
        if [[ -n "$df_text_for_stage" ]] && \
           printf '%s' "$df_text_for_stage" | grep -qE "^FROM .* AS ${build_flavor}\b" 2>/dev/null; then
            target_stage="$build_flavor"
        fi
    fi

    # Cell-specific contexts — must use the un-escaped inline content so that
    # FROM extraction sees "FROM ${DEBIAN_TRIXIE_BASE}" (not "FROM $${…}")
    # and the resulting contexts key stays as the concrete ghcr.io/… ref.
    local ctx_json
    if ! ctx_json=$(_contexts_for_cell "$c" "$df_content_or_path" \
            "$flavor" "$dep_target_ids_json" "$is_inline"); then
        printf 'ERROR: _contexts_for_cell failed for %q\n' "$c" >&2
        return 1
    fi

    # Escape bake/HCL interpolation triggers in the inline Dockerfile content
    # before writing it into the JSON.  bake performs HCL variable interpolation
    # over the entire bake file, including dockerfile-inline string values.  Any
    # ${DOCKER_ARG} or %{…} that is not a declared bake variable causes
    # "docker buildx bake --print" to abort with "undefined variable".
    # Escaping: ${ -> $${  (HCL un-escapes to literal ${; Docker sees ${ARG})
    #           %{ -> %%{  (HCL template escape; harmless if absent)
    # Ordering: all prior operations (contexts extraction, NPROC detection,
    # args computation) already ran on df_content_or_path (un-escaped content).
    # Only the emitted dockerfile-inline string receives this escaping.
    local inline_content_escaped="$inline_content"
    if [[ "$is_inline" == "1" ]]; then
        inline_content_escaped="${inline_content_escaped//\$\{/\$\$\{}"
        inline_content_escaped="${inline_content_escaped//%\{/%%\{}"
    fi

    # Assemble the target object.
    local target_obj
    if [[ "$is_inline" == "1" ]]; then
        target_obj=$(jq -cn \
            --arg ctx "$c" \
            --arg dfi "$inline_content_escaped" \
            --argjson platforms "$platforms_json" \
            --argjson tags      "$tags_json" \
            --argjson args      "$args_json" \
            '{"context": $ctx, "dockerfile-inline": $dfi, "platforms": $platforms, "tags": $tags, "args": $args}')
    else
        target_obj=$(jq -cn \
            --arg ctx "$c" \
            --arg df "$dockerfile" \
            --argjson platforms "$platforms_json" \
            --argjson tags      "$tags_json" \
            --argjson args      "$args_json" \
            '{context: $ctx, dockerfile: $df, platforms: $platforms, tags: $tags, args: $args}')
    fi

    if [[ -n "$target_stage" ]]; then
        target_obj=$(jq -cn --argjson t "$target_obj" --arg s "$target_stage" \
            '$t + {target: $s}')
    fi

    local ctx_len
    ctx_len=$(jq -r 'length' <<< "$ctx_json")
    if [[ "$ctx_len" -gt 0 ]]; then
        target_obj=$(jq -cn --argjson t "$target_obj" --argjson c "$ctx_json" \
            '$t + {contexts: $c}')
    fi

    # Accumulate into caller-scope variables (set -n nameref not in bash 4.3; use globals)
    targets_json=$(jq -cn --argjson base "$targets_json" \
        --arg tid "$tid" --argjson obj "$target_obj" \
        '$base + {($tid): $obj}')

    container_targets=$(jq -cn --argjson arr "$container_targets" --arg tid "$tid" \
        '$arr + [$tid]')
}

# ---------------------------------------------------------------------------
# Build the complete bake JSON document and print it to stdout.
# ---------------------------------------------------------------------------
_build_bake_json() {
    local -a requested_containers=("$@")

    # Shared init: validate, expand closure, fetch matrices
    declare -a _EC_closure_containers=()
    declare -A _EC_all_matrix_json=()
    declare -A _EC_first_target_per_container=()
    if ! _enumerate_cells_init "${requested_containers[@]}"; then
        return 1
    fi

    # Build dep_target_ids_json: {"container": "first_target_id", ...}
    local dep_target_ids_json='{}'
    local c
    for c in "${!_EC_first_target_per_container[@]}"; do
        dep_target_ids_json=$(jq -cn --argjson base "$dep_target_ids_json" \
            --arg k "$c" --arg v "${_EC_first_target_per_container[$c]}" \
            '$base + {($k): $v}')
    done

    # -----------------------------------------------------------------------
    # Target construction: one bake target per build cell
    # -----------------------------------------------------------------------
    local targets_json='{}'
    declare -A container_target_lists   # container -> JSON array of target IDs

    for c in "${_EC_closure_containers[@]}"; do
        local container_targets='[]'

        _on_cell_plain() { :; }   # no-op placeholder for cells mode (unused here)

        # _on_cell_bake accumulates into targets_json and container_targets
        local ncells
        ncells=$(jq 'length' <<< "${_EC_all_matrix_json[$c]}")
        local config_args
        if ! config_args=$(_config_build_args "$c"); then
            printf 'ERROR: _config_build_args failed for %q\n' "$c" >&2
            return 1
        fi

        local matrix="${_EC_all_matrix_json[$c]}"
        local i
        for (( i=0; i<ncells; i++ )); do
            local cell
            cell=$(jq -c ".[$i]" <<< "$matrix")

            local version variant tag flavor build_flavor cell_os cell_dockerfile
            version=$(jq -r '.version'               <<< "$cell")
            variant=$(jq -r '.variant // ""'         <<< "$cell")
            tag=$(jq -r '.tag'                       <<< "$cell")
            flavor=$(jq -r '.flavor // ""'           <<< "$cell")
            build_flavor=$(jq -r '.build_flavor // ""'   <<< "$cell")
            cell_os=$(jq -r '.os // "linux"'         <<< "$cell")
            cell_dockerfile=$(jq -r '.dockerfile // ""' <<< "$cell")

            # Skip Windows cells
            if [[ "$cell_os" == "windows" ]]; then
                continue
            fi

            _on_cell_bake "$c" "$cell" "$dep_target_ids_json" "$config_args" \
                "$version" "$variant" "$tag" "$flavor" "$build_flavor" \
                "$cell_dockerfile" || return 1
        done

        container_target_lists[$c]="$container_targets"
    done

    # -----------------------------------------------------------------------
    # Group construction
    # -----------------------------------------------------------------------
    local groups_json='{}'

    # group "default": ONLY the originally requested containers' targets
    local default_targets='[]'
    for c in "${requested_containers[@]}"; do
        local ctargets="${container_target_lists[$c]:-[]}"
        default_targets=$(jq -cn --argjson acc "$default_targets" \
            --argjson add "$ctargets" '$acc + $add')
    done
    groups_json=$(jq -cn --argjson base "$groups_json" --argjson dt "$default_targets" \
        '$base + {"default": {"targets": $dt}}')

    # Per-container groups (for explicit targeting by name)
    for c in "${_EC_closure_containers[@]}"; do
        local ctargets="${container_target_lists[$c]:-[]}"
        groups_json=$(jq -cn --argjson base "$groups_json" \
            --arg c "$c" --argjson ct "$ctargets" \
            '$base + {($c): {"targets": $ct}}')
    done

    # -----------------------------------------------------------------------
    # Assemble the final bake document; validate; emit atomically
    # -----------------------------------------------------------------------
    local bake_doc
    # REMOTE_CR is NOT a bake variable — it is resolved concretely at generation
    # time from the environment (_BAKE_REMOTE_CR).  Emitting it as a bake
    # variable would allow a bake-time override that diverges from the concrete
    # contexts keys, breaking BuildKit named-context matching.
    # ARCH_SUFFIX and NPROC genuinely vary per-arch job and remain bake variables.
    bake_doc=$(jq -cn \
        --argjson targets "$targets_json" \
        --argjson groups  "$groups_json" \
        '{
            variable: {
                ARCH_SUFFIX: { default: "" },
                NPROC:       { default: "1" }
            },
            target:   $targets,
            group:    $groups
        }')

    # Belt-and-suspenders: verify the assembled document is valid JSON
    jq -e . <<< "$bake_doc" > /dev/null 2>&1 || {
        printf 'ERROR: generated bake JSON is not valid — internal bug\n' >&2
        return 1
    }

    jq . <<< "$bake_doc"
}

# ---------------------------------------------------------------------------
# --cells mode: emit a compact JSON array — one object per linux build cell.
# Same cell set as the bake mode (same closure + matrix + os==windows skip).
# No Dockerfile work; no build_args computation.
#
# Output per element:
#   {
#     "container":       "<name>",
#     "tag":             "<tag>",
#     "flavor":          "<flavor>",          -- "" when not set
#     "is_default":      true|false,
#     "intermediate_ref": "<concrete-registry>/<container>:<tag>"
#   }
#
# intermediate_ref is a concrete registry ref (no ${REMOTE_CR} token) — the
# registry is resolved once at generation time from the REMOTE_CR env var.
# ---------------------------------------------------------------------------
_emit_cells_json() {
    local -a requested_containers=("$@")

    # FIX D: Build a lookup set of the originally-requested containers so that
    # cells mode only emits cells for containers bake actually pushes (the
    # requested set, NOT the dep closure).  Dep targets are built cacheonly
    # (in-memory context handoff) and are never pushed, so must not be merged.
    # When the requested set IS the full fleet (whole-fleet mode), every
    # container in the closure is a requested container so the filter is a no-op.
    local -A _requested_set=()
    local _rc
    for _rc in "${requested_containers[@]}"; do
        _requested_set["$_rc"]=1
    done

    # Shared init: validate, expand closure, fetch matrices
    declare -a _EC_closure_containers=()
    declare -A _EC_all_matrix_json=()
    declare -A _EC_first_target_per_container=()
    if ! _enumerate_cells_init "${requested_containers[@]}"; then
        return 1
    fi

    # Accumulate cell objects into a JSON array
    local cells_json='[]'

    # Define the cells-mode callback — each call appends one object.
    # F2: include is_latest_version so the merge job can gate rolling tags.
    # FIX F: include variant (unique per cell) for rolling-alias routing in merge;
    #        flavor is non-unique for multi-build_flavor containers (github-runner).
    _on_cell_plain() {
        local _c="$1" _tag="$2" _flavor="$3" _is_default="$4" _iref="$5" _is_latest="${6:-false}" _variant="${7:-}"
        local _obj
        _obj=$(jq -cn \
            --arg container    "$_c" \
            --arg tag          "$_tag" \
            --arg flavor       "$_flavor" \
            --arg variant      "$_variant" \
            --argjson is_default       "$( [ "$_is_default" = "true" ] && echo 'true' || echo 'false')" \
            --argjson is_latest_version "$( [ "$_is_latest"  = "true" ] && echo 'true' || echo 'false')" \
            --arg intermediate_ref "$_iref" \
            '{container: $container, tag: $tag, flavor: $flavor, variant: $variant, is_default: $is_default, is_latest_version: $is_latest_version, intermediate_ref: $intermediate_ref}')
        cells_json=$(jq -cn --argjson arr "$cells_json" --argjson obj "$_obj" '$arr + [$obj]')
    }

    local c
    for c in "${_EC_closure_containers[@]}"; do
        # FIX D: skip dep-closure containers that were not in the original
        # requested set — their intermediates are never pushed.
        if [[ -z "${_requested_set[$c]+set}" ]]; then
            continue
        fi

        local matrix="${_EC_all_matrix_json[$c]}"
        local ncells
        ncells=$(jq 'length' <<< "$matrix")
        local i
        for (( i=0; i<ncells; i++ )); do
            local cell
            cell=$(jq -c ".[$i]" <<< "$matrix")

            local tag flavor variant cell_os is_default_raw is_latest_raw
            tag=$(jq -r '.tag'              <<< "$cell")
            flavor=$(jq -r '.flavor // ""'  <<< "$cell")
            # FIX F: variant is the unique per-cell name for rolling-alias routing
            variant=$(jq -r '.variant // ""' <<< "$cell")
            cell_os=$(jq -r '.os // "linux"' <<< "$cell")
            is_default_raw=$(jq -r 'if .is_default then "true" else "false" end' <<< "$cell")
            # F2: propagate is_latest_version from the matrix cell
            is_latest_raw=$(jq -r 'if .is_latest_version then "true" else "false" end' <<< "$cell")

            # Skip Windows cells — same filter as bake mode
            if [[ "$cell_os" == "windows" ]]; then
                continue
            fi

            local intermediate_ref="${_BAKE_REMOTE_CR}/${c}:${tag}"
            _on_cell_plain "$c" "$tag" "$flavor" "$is_default_raw" "$intermediate_ref" "$is_latest_raw" "$variant"
        done
    done

    # Validate and emit
    jq -e 'if type == "array" then . else error("not array") end' <<< "$cells_json"
}

# ---------------------------------------------------------------------------
# Extension-sub-pipeline exclusion check (F1).
#
# Returns 0 (true) when a container has <container>/extensions/config.yaml,
# meaning it is owned by the build-extensions sub-pipeline and must NOT
# enter the bake graph.  Generation for such containers is not deterministic
# or network-free (skopeo/manifest-inspect fires during generate_dockerfile).
# ---------------------------------------------------------------------------
_is_extension_container() {
    local container="$1"
    [[ -f "${PROJECT_ROOT}/${container}/extensions/config.yaml" ]]
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    local -a requested=()
    local mode="bake"      # default mode
    local include_all_retained="false"   # F4: default = latest-only

    # Parse flags (order-independent):
    #   --cells        → cells plan mode
    #   --all-retained → pass include_all_retained=true to list_build_matrix
    local -a args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --cells)        mode="cells" ;;
            --all-retained) include_all_retained="true" ;;
            *)              args+=("$arg") ;;
        esac
    done

    if [[ ${#args[@]} -gt 0 ]]; then
        requested=("${args[@]}")
    else
        # Full fleet: enumerate from ./make list
        while IFS= read -r c; do
            [[ -n "$c" ]] && requested+=("$c")
        done < <(_list_all_containers)
        if [[ ${#requested[@]} -eq 0 ]]; then
            printf 'ERROR: ./make list returned no containers\n' >&2
            exit 1
        fi
    fi

    # F1: Remove extension-sub-pipeline containers from the requested set.
    # The exclusion is applied before closure expansion so that an explicitly
    # requested extension container is still skipped (not just dropped from
    # the fleet enumeration).
    local -a filtered_requested=()
    for c in "${requested[@]}"; do
        if _is_extension_container "$c"; then
            printf '::notice::Skipping %s from bake graph (extension sub-pipeline owns it; see build-extensions)\n' \
                "$c" >&2
        else
            filtered_requested+=("$c")
        fi
    done

    # If every requested container was excluded, emit an empty graph and exit 0.
    if [[ ${#filtered_requested[@]} -eq 0 ]]; then
        printf '::notice::All requested containers excluded from bake graph (extension sub-pipeline)\n' >&2
        if [[ "$mode" == "cells" ]]; then
            printf '[]\n'
        else
            # No REMOTE_CR variable — it is generation-time concrete.
            jq -cn \
                '{"variable":{"ARCH_SUFFIX":{"default":""},"NPROC":{"default":"1"}},"target":{},"group":{"default":{"targets":[]}}}'
        fi
        exit 0
    fi
    requested=("${filtered_requested[@]}")

    # Export include_all_retained so _enumerate_cells_init can read it.
    export _BAKE_INCLUDE_ALL_RETAINED="$include_all_retained"

    if [[ "$mode" == "cells" ]]; then
        _emit_cells_json "${requested[@]}"
    else
        _build_bake_json "${requested[@]}"
    fi
}

main "$@"
