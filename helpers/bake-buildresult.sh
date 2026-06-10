#!/usr/bin/env bash
# bake-buildresult.sh — Emit #595 build-result artifacts from a bake run's
# --metadata-file output, so coverage-checkpoint can aggregate bake jobs
# alongside the existing flat-matrix build jobs without modification.
#
# Usage (library):
#   source helpers/bake-buildresult.sh
#   emit_bake_build_results <metadata_file> <arch> <out_dir> <container...>
#
# Usage (standalone):
#   helpers/bake-buildresult.sh <metadata_file> <arch> <out_dir> <container...>
#
# Arguments:
#   metadata_file  — path to bake's --metadata-file JSON (keyed by target id).
#                    MAY be absent or empty; handled fail-closed (all → failure).
#   arch           — amd64 | arm64
#   out_dir        — directory to write build-result-<c>-<tag>-<arch>.json files
#   container...   — one or more container names to emit results for
#
# Output format (per file): {"container","variant","tag","arch","result"}
#   result ∈ "success" | "failure"
#   A target is "success" IFF its target_id is a key in the metadata AND that
#   key has a non-empty "containerimage.digest" value.  Everything else is
#   "failure" (fail-closed: absent/partial = not built = failure).
#
# Return codes:
#   0  — all files written (individual results are in the files, not the exit code)
#   1  — --cells invocation failed (cannot enumerate cells; no files written)
#
# Environment variables honoured:
#   BAKE_GENERATE_ALL_RETAINED  — when "true", pass --all-retained to the generator
#   BAKE_GENERATE_FINAL_BUILD   — when "true", pass --include-final-build to the generator
#
# Requirements: bash 4+, jq

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths robustly whether sourced or executed directly
# ---------------------------------------------------------------------------
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _BBR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    _BBR_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# shellcheck source=./logging.sh
source "${_BBR_SCRIPT_DIR}/logging.sh"

# ---------------------------------------------------------------------------
# emit_bake_build_results
# ---------------------------------------------------------------------------
emit_bake_build_results() {
    local metadata_file="$1"
    local arch="$2"
    local out_dir="$3"
    shift 3
    local -a containers=("$@")

    # ------------------------------------------------------------------
    # Step 1: enumerate cells via generate-bake-hcl.sh --cells
    # stderr passes through to the caller (generator may emit ::error:: or
    # ::warning:: annotations that must surface in CI logs).
    #
    # When BAKE_GENERATE_ALL_RETAINED=true, pass --all-retained so the
    # result set matches the built set (mirrors the RETAINED_FLAG decision
    # in the bake build steps).
    # ------------------------------------------------------------------
    local cells_json
    local generator="${_BBR_SCRIPT_DIR}/../scripts/generate-bake-hcl.sh"
    local -a cells_args=("--cells")
    if [[ "${BAKE_GENERATE_ALL_RETAINED:-}" == "true" ]]; then
        cells_args+=("--all-retained")
    fi
    if [[ "${BAKE_GENERATE_FINAL_BUILD:-}" == "true" ]]; then
        cells_args+=("--include-final-build")
    fi
    # Match the scoped bake build set. If this helper enumerates unscoped
    # cells, scoped-out targets that are absent from metadata become false
    # failures in coverage lineage.
    [[ -n "${SCOPE_VERSIONS:-}" ]] && cells_args+=("--scope-versions" "${SCOPE_VERSIONS}")
    [[ -n "${SCOPE_FLAVORS:-}" ]] && cells_args+=("--scope-flavors" "${SCOPE_FLAVORS}")
    [[ -n "${BUILD_SCOPE:-}" ]] && cells_args+=("--scope" "${BUILD_SCOPE}")
    [[ -n "${CONTAINER_SCOPES:-}" ]] && cells_args+=("--container-scopes" "${CONTAINER_SCOPES}")
    if ! cells_json=$("$generator" "${cells_args[@]}" "${containers[@]}"); then
        printf '::error::bake-buildresult: --cells failed for %s\n' \
            "${containers[*]}" >&2
        return 1
    fi

    # ------------------------------------------------------------------
    # Step 2: load metadata — absent/empty/invalid → empty object (fail-closed)
    # ------------------------------------------------------------------
    local metadata='{}'
    if [[ -f "$metadata_file" ]] && [[ -s "$metadata_file" ]]; then
        if jq -e 'type == "object"' "$metadata_file" >/dev/null 2>&1; then
            metadata=$(jq -c '.' "$metadata_file")
        else
            printf '::warning::bake-buildresult: metadata file %q is not a JSON object; treating as empty — all cells will be marked failure\n' \
                "$metadata_file" >&2
        fi
    else
        printf '::warning::bake-buildresult: metadata file %q absent or empty — all cells will be marked failure\n' \
            "$metadata_file" >&2
    fi

    # ------------------------------------------------------------------
    # Step 3 + 4: iterate cells, determine result, write artifact files
    # ------------------------------------------------------------------
    mkdir -p "$out_dir"

    local ncells
    ncells=$(jq 'length' <<< "$cells_json")

    local n_success=0
    local n_failure=0
    local i
    for (( i=0; i<ncells; i++ )); do
        local cell
        cell=$(jq -c ".[$i]" <<< "$cells_json")

        local container tag variant target_id
        container=$(jq -r '.container'        <<< "$cell")
        tag=$(jq -r '.tag'                    <<< "$cell")
        variant=$(jq -r '.variant // ""'      <<< "$cell")
        target_id=$(jq -r '.target_id // ""'  <<< "$cell")

        # Determine result: success only when target_id present in metadata
        # AND has a non-empty containerimage.digest.
        local result="failure"
        if [[ -n "$target_id" ]]; then
            local digest
            digest=$(jq -r --arg tid "$target_id" \
                '.[$tid]["containerimage.digest"] // ""' <<< "$metadata")
            if [[ -n "$digest" ]]; then
                result="success"
            fi
        fi

        # Write artifact — shape is IDENTICAL to auto-build.yaml:1054-1061
        local out_file="${out_dir}/build-result-${container}-${tag}-${arch}.json"
        jq -cn \
            --arg c  "$container" \
            --arg v  "$variant" \
            --arg t  "$tag" \
            --arg a  "$arch" \
            --arg r  "$result" \
            '{container:$c, variant:$v, tag:$t, arch:$a, result:$r}' \
            > "$out_file"

        if [[ "$result" == "success" ]]; then
            (( n_success++ )) || true
        else
            (( n_failure++ )) || true
        fi
    done

    # ------------------------------------------------------------------
    # Step 5: summary notice
    # ------------------------------------------------------------------
    printf '::notice::bake-buildresult: %d success, %d failure (arch %s)\n' \
        "$n_success" "$n_failure" "$arch" >&2

    return 0
}

# ---------------------------------------------------------------------------
# main — standalone entry point
# ---------------------------------------------------------------------------
main() {
    if [[ $# -lt 3 ]]; then
        printf 'Usage: %s <metadata_file> <arch> <out_dir> <container...>\n' \
            "$(basename "$0")" >&2
        return 1
    fi
    emit_bake_build_results "$@"
}

# Guard so bats can source this file without invoking main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
