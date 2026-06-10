#!/usr/bin/env bash
# generate-bake-hcl.sh — Synthesise a docker buildx bake definition (JSON) to
# stdout from the repo's canonical metadata, driven by the ADR-013
# dependency-ordered build.
#
# Usage:
#   scripts/generate-bake-hcl.sh                  # whole fleet
#   scripts/generate-bake-hcl.sh wordpress         # wordpress + dep closure
#   scripts/generate-bake-hcl.sh github-runner     # github-runner + debian dep
#   scripts/generate-bake-hcl.sh --cells --scope-versions 1.31 openresty
#   scripts/generate-bake-hcl.sh --scope-flavors aws terraform
#   scripts/generate-bake-hcl.sh --container-scopes '{"terraform":{"flavors":"aws"}}' terraform
#   scripts/generate-bake-hcl.sh --scope alpine web-shell
#   scripts/generate-bake-hcl.sh --include-final-build postgres
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
#   postgres      — extension-marker template via generate-dockerfile.sh
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

# Print CLI help.
_usage() {
    cat <<'EOF'
Usage:
  scripts/generate-bake-hcl.sh [options] [container ...]

Options:
  --cells                 Emit compact cell JSON instead of a bake document.
  --all-retained          Include retained versions where allowed.
  --include-final-build   include flag-marked extension containers' FINAL image build in the graph
                          (requires their extension lineage artifacts to be present; used by the
                          postgres bake routing -- NOT by the whole-fleet smoke).
  --scope-versions <csv>  Keep versions matching a comma-separated version list.
  --scope-flavors <csv>   Keep cells whose flavor is in a comma-separated list.
  --scope <str>           Keep cells whose variant/os/build_flavor/flavor contains this string.
  --container-scopes <json>
                          Per-container scope map:
                          {"<container>":{"versions":"csv","flavors":"csv","extensions":"csv"}}
  -h, --help              Show this help.
EOF
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
            # F1: extension compilation stays out of bake; a flag-gated FINAL
            # image build may enter the graph when explicitly requested.
            if _is_bake_excluded_extension_container "$dep"; then
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

# _effective_scope_filters <container>
# Prints "<versions>\t<flavors>" for the container's effective scope filters.
# A per-container map entry overrides the global version/flavor filters for
# that container; containers absent from the map keep the global filters.
_effective_scope_filters() {
    local container="$1"
    local scope_versions="${_BAKE_SCOPE_VERSIONS:-}"
    local scope_flavors="${_BAKE_SCOPE_FLAVORS:-}"

    if [[ -n "${_BAKE_CONTAINER_SCOPES:-}" ]] && \
       jq -e --arg c "$container" 'has($c)' <<< "$_BAKE_CONTAINER_SCOPES" >/dev/null; then
        scope_versions=$(jq -r --arg c "$container" '.[$c].versions // ""' <<< "$_BAKE_CONTAINER_SCOPES")
        scope_flavors=$(jq -r --arg c "$container" '.[$c].flavors // ""' <<< "$_BAKE_CONTAINER_SCOPES")
    fi

    printf '%s\t%s\n' "$scope_versions" "$scope_flavors"
}

_scope_filters_active_for_container() {
    local container="$1"
    local filters
    filters=$(_effective_scope_filters "$container")
    local scope_versions="${filters%%$'\t'*}"
    local scope_flavors="${filters#*$'\t'}"

    [[ -n "$scope_versions" || -n "$scope_flavors" || -n "${_BAKE_SCOPE:-}" ]]
}

# _cell_passes_scope <container> <version> <flavor> <variant> <os> <build_flavor>
# Returns 0 if the cell passes the active bake scope filters.
# Empty scope variables mean pass-all.
_cell_passes_scope() {
    local container="$1"
    local version="$2"
    local flavor="$3"
    local variant="$4"
    local cell_os="$5"
    local build_flavor="$6"
    local filters
    filters=$(_effective_scope_filters "$container")
    local scope_versions="${filters%%$'\t'*}"
    local scope_flavors="${filters#*$'\t'}"

    if [[ -n "$scope_versions" ]]; then
        local version_match="false"
        local versions_csv="${scope_versions},"
        local scope_version
        while [[ "$versions_csv" == *,* ]]; do
            scope_version="${versions_csv%%,*}"
            versions_csv="${versions_csv#*,}"

            # Keep byte-identical semantics with
            # .github/actions/detect-containers/action.yaml scope_versions jq:
            # V == S OR V startswith(S + ".") OR V startswith(S + "-").
            if [[ "$version" == "$scope_version" || \
                  "$version" == "$scope_version."* || \
                  "$version" == "$scope_version-"* ]]; then
                version_match="true"
                break
            fi
        done
        [[ "$version_match" == "true" ]] || return 1
    fi

    if [[ -n "$scope_flavors" ]]; then
        local flavor_match="false"
        local flavors_csv="${scope_flavors},"
        local scope_flavor
        while [[ "$flavors_csv" == *,* ]]; do
            scope_flavor="${flavors_csv%%,*}"
            flavors_csv="${flavors_csv#*,}"
            if [[ "$flavor" == "$scope_flavor" ]]; then
                flavor_match="true"
                break
            fi
        done
        [[ "$flavor_match" == "true" ]] || return 1
    fi

    if [[ -n "${_BAKE_SCOPE:-}" ]]; then
        local scope="${_BAKE_SCOPE}"
        if [[ "$variant" != *"$scope"* && \
              "$cell_os" != *"$scope"* && \
              "$build_flavor" != *"$scope"* && \
              "$flavor" != *"$scope"* ]]; then
            return 1
        fi
    fi

    return 0
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
# Returns 0 if the Dockerfile declares "ARG <name>" (no default, any spacing).
# Args: <arg_name> <df_content_or_path> <is_inline>
#   is_inline=1 → second arg is inline Dockerfile content
#   is_inline=0 → second arg is an absolute path to the Dockerfile
# Returns 1 (false) when df is empty or the file is missing.
# ---------------------------------------------------------------------------
_df_declares_arg() {
    local arg_name="$1" df="$2" is_inline="${3:-0}"
    [[ -n "$df" ]] || return 1
    local re="^ARG[[:space:]]+${arg_name}([[:space:]=]|\$)"
    if [[ "$is_inline" == "1" ]]; then
        printf '%s' "$df" | grep -qE "$re" 2>/dev/null
    else
        [[ -f "$df" ]] && grep -qE "$re" "$df" 2>/dev/null
    fi
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

    # 2. VERSION — mirror the non-bake build's base_image_version
    #    (build-container.sh: "${major_version}${base_suffix}"). postgres declares
    #    base_suffix "-alpine", and its Dockerfile does FROM library/postgres:${VERSION},
    #    so VERSION must carry the suffix ("18" -> "18-alpine") or the bake build would
    #    pull the Debian base and publish *-alpine tags backed by the wrong distro.
    #    base_suffix is empty for every container except postgres today, so this is a
    #    no-op for the rest of the fleet.
    local _base_sfx
    _base_sfx=$(base_suffix "${PROJECT_ROOT}/${container}" 2>/dev/null || echo "")
    args=$(jq -cn --argjson base "$args" --arg v "${version}${_base_sfx}" '$base + {VERSION: $v}')

    # 3. MAJOR_VERSION (leading integer: "18" from "18-alpine", "2" from "2.334.0")
    local major
    major=$(printf '%s' "$version" | grep -oE '^[0-9]+' | head -1 || true)
    if [[ -n "$major" ]]; then
        args=$(jq -cn --argjson base "$args" --arg m "$major" '$base + {MAJOR_VERSION: $m}')
    fi

    # 4. UPSTREAM_VERSION — derived DETERMINISTICALLY from the selected cell tag
    #    ($version) by stripping the tag suffix returned by version.sh --tag-suffix.
    #    Never a live upstream query: a live query can drift past the pinned tag
    #    (build a newer source under an older tag → silent wrong-version) or fail.
    #    Emit only when: upstream is non-empty AND differs from version AND the
    #    Dockerfile declares ARG UPSTREAM_VERSION (avoids unused build-arg warnings
    #    and keeps parity with the matrix path, which only passes what the Dockerfile
    #    consumes — same rationale as NPROC in STEP 7 below).
    local version_sh="${PROJECT_ROOT}/${container}/version.sh"
    if [[ -x "$version_sh" ]]; then
        local suffix upstream
        suffix=$(cd "${PROJECT_ROOT}/${container}" && ./version.sh --tag-suffix 2>/dev/null || true)
        # Robustness guard: treat suffix as valid ONLY when it is empty OR
        # (starts with '-' AND $version ends with it).  A version.sh that lacks
        # --tag-suffix support falls through to its default output (e.g. "8.5.7-fpm-alpine"),
        # which does NOT start with '-' — treat that as no-suffix.
        if [[ -n "$suffix" && ( "${suffix:0:1}" != "-" || "${version%"$suffix"}" == "$version" ) ]]; then
            suffix=""  # invalid/garbage suffix — treat as no-suffix
        fi
        if [[ -n "$suffix" ]]; then
            upstream="${version%"$suffix"}"
        else
            upstream="$version"
        fi
        if [[ -n "$upstream" && "$upstream" != "$version" ]] && \
               _df_declares_arg "UPSTREAM_VERSION" "$df_content_or_path" "$is_inline"; then
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
    if _df_declares_arg "NPROC" "$df_content_or_path" "$is_inline"; then
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

    local -A _requested_set=()
    local _rc
    for _rc in "${requested_containers[@]}"; do
        _requested_set["$_rc"]=1
    done

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
        # bake_latest_only: when true, force latest-only for this container regardless
        # of the global --all-retained flag (e.g. github-runner shares a single
        # runner.tar.gz across all variants in one bake invocation — retained older
        # versions would get the wrong binary).
        local _c_bake_latest_only
        _c_bake_latest_only=$(yq -r '.build.bake_latest_only // false' "./${c}/variants.yaml" 2>/dev/null || echo "false")
        local _c_retained="$_ec_all_retained"
        if [[ "$_c_bake_latest_only" == "true" && "$_ec_all_retained" == "true" ]]; then
            _c_retained="false"
            printf '::notice::bake: %s forced latest-only (bake_latest_only=true; shared runner.tar.gz; retained rebuilds need per-version build contexts)\n' "$c" >&2
        fi

        local matrix
        if ! matrix=$(list_build_matrix "./${c}" "" "$_c_retained" 2>/dev/null); then
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
        if [[ -n "${_requested_set[$c]+set}" ]] && _scope_filters_active_for_container "$c"; then
            first_entry=""
            local _first_ncells
            _first_ncells=$(jq 'length' <<< "$matrix")
            local _first_i
            for (( _first_i=0; _first_i<_first_ncells; _first_i++ )); do
                local _first_cell
                _first_cell=$(jq -c ".[$_first_i]" <<< "$matrix")

                local _first_version _first_flavor _first_variant _first_os _first_build_flavor
                _first_version=$(jq -r '.version' <<< "$_first_cell")
                _first_flavor=$(jq -r '.flavor // ""' <<< "$_first_cell")
                _first_variant=$(jq -r '.variant // ""' <<< "$_first_cell")
                _first_os=$(jq -r '.os // "linux"' <<< "$_first_cell")
                _first_build_flavor=$(jq -r '.build_flavor // ""' <<< "$_first_cell")

                if [[ "$_first_os" == "windows" ]]; then
                    continue
                fi
                if _cell_passes_scope "$c" "$_first_version" "$_first_flavor" "$_first_variant" \
                        "$_first_os" "$_first_build_flavor"; then
                    first_entry="$_first_cell"
                    break
                fi
            done
        else
            first_entry=$(jq -c 'first(.[] | select(.is_latest_version == true)) // .[0]' \
                <<< "$matrix" 2>/dev/null) || first_entry=""
        fi
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
            if ! _cell_passes_scope "$c" "$version" "$flavor" "$variant" "$cell_os" "$build_flavor"; then
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

    # Registry cache: per-target ref keyed by container+tag+arch so each target
    # reuses its own layer cache across runs.  ARCH_SUFFIX is the bake variable
    # (declared in the document header); it interpolates to -amd64/-arm64 at bake
    # invocation time.  ignore-error on cache-to ensures a transient GHCR export
    # failure never fails the build job.
    #
    # cache-from is UNCONDITIONAL — reading is always safe and PR/dry-run builds
    # benefit from master's warm cache.
    # cache-to is GATED on BAKE_CACHE_EXPORT=true — writing to canonical GHCR
    # buildcache refs must only happen on the real publish path (push/dispatch).
    # PR builds have packages:write but must NOT poison the canonical buildcache
    # that master builds consume via cache-from.
    local cache_ref="${_BAKE_REMOTE_CR}/${c}:buildcache-${tag}\${ARCH_SUFFIX}"
    local cache_from_json
    cache_from_json=$(jq -cn --arg ref "$cache_ref" \
        '[{"type": "registry", "ref": $ref}]')
    target_obj=$(jq -cn --argjson t "$target_obj" \
        --argjson cf "$cache_from_json" \
        '$t + {"cache-from": $cf}')

    if [[ "${BAKE_CACHE_EXPORT:-false}" == "true" ]]; then
        local cache_to_json
        cache_to_json=$(jq -cn --arg ref "$cache_ref" \
            '[{"type": "registry", "ref": $ref, "mode": "max", "ignore-error": true}]')
        target_obj=$(jq -cn --argjson t "$target_obj" \
            --argjson ct "$cache_to_json" \
            '$t + {"cache-to": $ct}')
    fi

    # Accumulate into caller-scope variables (set -n nameref not in bash 4.3; use globals)
    targets_json=$(printf '%s\n%s\n' "$targets_json" "$target_obj" | \
        jq -sc --arg tid "$tid" '.[0] + {($tid): .[1]}')

    container_targets=$(jq -cn --argjson arr "$container_targets" --arg tid "$tid" \
        '$arr + [$tid]')
}

# ---------------------------------------------------------------------------
# Build the complete bake JSON document and print it to stdout.
# ---------------------------------------------------------------------------
_build_bake_json() {
    local -a requested_containers=("$@")

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
            if [[ -n "${_requested_set[$c]+set}" ]] && \
                    ! _cell_passes_scope "$c" "$version" "$flavor" "$variant" "$cell_os" "$build_flavor"; then
                continue
            fi

            _on_cell_bake "$c" "$cell" "$dep_target_ids_json" "$config_args" \
                "$version" "$variant" "$tag" "$flavor" "$build_flavor" \
                "$cell_dockerfile" || return 1
        done

        container_target_lists[$c]="$container_targets"
    done

    local dangling_context_targets
    dangling_context_targets=$(jq -r '
        . as $targets
        | [
            to_entries[]
            | (.value.contexts // {})
            | to_entries[]
            | .value
            | select(type == "string" and startswith("target:"))
            | sub("^target:"; "") as $target_id
            | select(($targets | has($target_id)) | not)
            | $target_id
        ]
        | unique
        | .[]
    ' <<< "$targets_json")
    if [[ -n "$dangling_context_targets" ]]; then
        local dangling_target
        while IFS= read -r dangling_target; do
            [[ -n "$dangling_target" ]] || continue
            printf '::error::bake: dangling internal base context target:%s — refusing to emit an incomplete bake graph\n' \
                "$dangling_target" >&2
        done <<< "$dangling_context_targets"
        return 1
    fi

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
    bake_doc=$(printf '%s\n%s\n' "$targets_json" "$groups_json" | jq -sc \
        '{
            variable: {
                ARCH_SUFFIX: { default: "" },
                NPROC:       { default: "1" }
            },
            target:   .[0],
            group:    .[1]
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
    # #595: include target_id (byte-identical to the bake target key) so that
    #        bake-buildresult.sh can correlate --metadata-file keys to cells.
    _on_cell_plain() {
        local _c="$1" _tag="$2" _flavor="$3" _is_default="$4" _iref="$5" _is_latest="${6:-false}" _variant="${7:-}" _tid="${8:-}"
        local _obj
        _obj=$(jq -cn \
            --arg container    "$_c" \
            --arg tag          "$_tag" \
            --arg flavor       "$_flavor" \
            --arg variant      "$_variant" \
            --argjson is_default       "$( [ "$_is_default" = "true" ] && echo 'true' || echo 'false')" \
            --argjson is_latest_version "$( [ "$_is_latest"  = "true" ] && echo 'true' || echo 'false')" \
            --arg intermediate_ref "$_iref" \
            --arg target_id    "$_tid" \
            '{container: $container, tag: $tag, flavor: $flavor, variant: $variant, is_default: $is_default, is_latest_version: $is_latest_version, intermediate_ref: $intermediate_ref, target_id: $target_id}')
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

            local version tag flavor build_flavor variant cell_os is_default_raw is_latest_raw
            version=$(jq -r '.version'          <<< "$cell")
            tag=$(jq -r '.tag'              <<< "$cell")
            flavor=$(jq -r '.flavor // ""'  <<< "$cell")
            build_flavor=$(jq -r '.build_flavor // ""' <<< "$cell")
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
            if ! _cell_passes_scope "$c" "$version" "$flavor" "$variant" "$cell_os" "$build_flavor"; then
                continue
            fi

            # #595: Compute target_id using IDENTICAL logic to _on_cell_bake so
            # that --cells[].target_id matches the bake --metadata-file keys.
            local cell_tid
            if [[ -z "$variant" ]]; then
                cell_tid="$(_target_id "${c}_${tag}")"
            else
                cell_tid="$(_target_id "${c}_${version}_${variant}")"
            fi

            local intermediate_ref="${_BAKE_REMOTE_CR}/${c}:${tag}"
            _on_cell_plain "$c" "$tag" "$flavor" "$is_default_raw" "$intermediate_ref" "$is_latest_raw" "$variant" "$cell_tid"
        done
    done

    # Validate and emit
    jq -e 'if type == "array" then . else error("not array") end' <<< "$cells_json"
}

# ---------------------------------------------------------------------------
# Extension-sub-pipeline exclusion checks (F1).
#
# _is_extension_container returns 0 when a container has
# <container>/extensions/config.yaml. Extension COMPILATION remains excluded;
# only the FINAL image build (flag-gated by build.bake_final_build) may enter
# the graph.
# ---------------------------------------------------------------------------
_is_extension_container() {
    local container="$1"
    [[ -f "${PROJECT_ROOT}/${container}/extensions/config.yaml" ]]
}

_bake_final_build_enabled() {
    local container="$1"
    local variants_file="${PROJECT_ROOT}/${container}/variants.yaml"
    [[ -f "$variants_file" ]] || return 1

    local flag
    flag=$(yq -r '.build.bake_final_build // false' "$variants_file" 2>/dev/null || echo "false")
    [[ "$flag" == "true" ]]
}

_is_bake_excluded_extension_container() {
    local container="$1"
    _is_extension_container "$container" || return 1

    # build.bake_final_build is only a capability marker. Existing whole-fleet
    # smoke (bake-build.yaml) and bake_managed fleet builds do not pass
    # --include-final-build, so postgres stays excluded there; only the future
    # postgres bake-build job, after downloading extension lineage artifacts,
    # should activate final-image inclusion.
    if [[ "${_BAKE_INCLUDE_FINAL_BUILD:-}" == "1" ]] && _bake_final_build_enabled "$container"; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    local -a requested=()
    local mode="bake"      # default mode
    local include_all_retained="false"   # F4: default = latest-only
    local include_final_build=""
    local scope_versions=""
    local scope_flavors=""
    local scope=""
    local container_scopes=""

    unset _BAKE_INCLUDE_FINAL_BUILD

    # Parse flags (order-independent):
    #   --cells                → cells plan mode
    #   --all-retained         → pass include_all_retained=true to list_build_matrix
    #   --include-final-build  → include flag-marked extension final image builds
    #   --scope-versions <csv> → scope version filter
    #   --scope-flavors <csv>  → scope flavor filter
    #   --scope <str>          → free-form variant/os/build_flavor/flavor filter
    #   --container-scopes <json>
    #                           → per-container version/flavor scope map
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cells)        mode="cells" ;;
            --all-retained) include_all_retained="true" ;;
            --include-final-build) include_final_build="1" ;;
            --scope-versions)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --scope-versions requires a value\n' >&2
                    _usage >&2
                    exit 2
                fi
                scope_versions="$2"
                shift
                ;;
            --scope-versions=*) scope_versions="${1#*=}" ;;
            --scope-flavors)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --scope-flavors requires a value\n' >&2
                    _usage >&2
                    exit 2
                fi
                scope_flavors="$2"
                shift
                ;;
            --scope-flavors=*) scope_flavors="${1#*=}" ;;
            --scope)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --scope requires a value\n' >&2
                    _usage >&2
                    exit 2
                fi
                scope="$2"
                shift
                ;;
            --scope=*)      scope="${1#*=}" ;;
            --container-scopes)
                if [[ $# -lt 2 ]]; then
                    printf 'ERROR: --container-scopes requires a JSON object value\n' >&2
                    _usage >&2
                    exit 2
                fi
                container_scopes="$2"
                shift
                ;;
            --container-scopes=*) container_scopes="${1#*=}" ;;
            -h|--help)
                _usage
                exit 0
                ;;
            *)              args+=("$1") ;;
        esac
        shift
    done

    if [[ -n "$container_scopes" ]]; then
        if ! jq -e '
            type == "object"
            and all(.[]; type == "object")
            and all(.[]; ((.versions? // "") | type == "string"))
            and all(.[]; ((.flavors? // "") | type == "string"))
            and all(.[]; ((.extensions? // "") | type == "string"))
        ' <<< "$container_scopes" >/dev/null 2>&1; then
            printf 'ERROR: --container-scopes must be a JSON object mapping container names to scope objects with string versions/flavors/extensions fields\n' >&2
            exit 2
        fi
    fi

    if [[ "$include_final_build" == "1" ]]; then
        export _BAKE_INCLUDE_FINAL_BUILD=1
    fi

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
        if _is_bake_excluded_extension_container "$c"; then
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
    export _BAKE_SCOPE_VERSIONS="$scope_versions"
    export _BAKE_SCOPE_FLAVORS="$scope_flavors"
    export _BAKE_SCOPE="$scope"
    export _BAKE_CONTAINER_SCOPES="$container_scopes"

    if [[ "$mode" == "cells" ]]; then
        _emit_cells_json "${requested[@]}"
    else
        _build_bake_json "${requested[@]}"
    fi
}

main "$@"
