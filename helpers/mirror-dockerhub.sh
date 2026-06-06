#!/usr/bin/env bash
# mirror-dockerhub.sh — Best-effort GHCR→DockerHub mirror for bake-managed containers.
#
# Usage (library):
#   source helpers/mirror-dockerhub.sh
#   mirror_to_dockerhub <container...>
#
# Usage (standalone):
#   helpers/mirror-dockerhub.sh web-shell github-runner wordpress
#
# For each bake-managed container the function mirrors its canonical GHCR final tags
# to docker.io/oorabona/<container>:<tag> using `docker buildx imagetools create`.
#
# Tag set: identical to what bake-merge-manifests.sh publishes — versioned + rolling
# aliases, gated on is_latest_version (retained non-latest versions only get the
# versioned tag; no rolling :latest/:latest-<variant> to avoid clobbering).
#
# BEST-EFFORT: a failure on any individual tag emits ::warning:: and continues.
# The function returns 0 even when individual mirrors fail — it never gates the build.
#
# SKIP: when DOCKERHUB_USERNAME is unset the function emits ::notice:: and returns 0.
#
# DRY_RUN / DOCKER indirection:
#   - When DRY_RUN=true the explicit dry-run branch at the mirror call site prints
#     the imagetools command to stderr and skips execution entirely.
#   - On the real (non-dry-run) path, "$DOCKER" (quoted, injection-safe) invokes
#     the docker binary.  DOCKER="${DOCKER:-docker}" so callers can override it;
#     bats tests set DOCKER to a logging mock script (no DRY_RUN involved).
#
# Requirements: bash 4+, docker (buildx imagetools), jq
# shellcheck source=./logging.sh
# shellcheck source=./variant-utils.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script dir whether sourced or executed directly
# ---------------------------------------------------------------------------
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _MDH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    _MDH_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# shellcheck disable=SC1091
source "${_MDH_SCRIPT_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${_MDH_SCRIPT_DIR}/variant-utils.sh"

# DOCKER is already set by logging.sh (honours DRY_RUN); provide a fallback
# only when the caller sourced this file before logging.sh.
DOCKER="${DOCKER:-docker}"

# ---------------------------------------------------------------------------
# mirror_to_dockerhub <container...>
#
# Mirrors canonical GHCR tags to docker.io/oorabona/<container>:<tag>
# for each named container.  The GHCR namespace is taken from REMOTE_CR
# (default: ghcr.io/oorabona, matching bake-merge-manifests.sh).
#
# Arguments:
#   container...  — one or more container names (e.g. web-shell github-runner)
#
# Environment variables honoured:
#   DOCKERHUB_USERNAME          — DockerHub account name (skips entirely when unset/empty)
#   REMOTE_CR                   — GHCR namespace (default: ghcr.io/oorabona)
#   BAKE_GENERATE_ALL_RETAINED  — when "true", pass --all-retained to the generator so the
#                                 mirrored tag set matches what bake-merge published (same
#                                 contract as helpers/bake-buildresult.sh)
#   DRY_RUN                     — when "true", print commands without executing
#   DOCKER                      — docker binary / mock (set by logging.sh)
#
# Return value:
#   0 always (best-effort; individual failures do not propagate)
# ---------------------------------------------------------------------------
mirror_to_dockerhub() {
    local -a containers=("$@")

    # Skip entirely when DockerHub credentials are absent.
    if [[ -z "${DOCKERHUB_USERNAME:-}" ]]; then
        printf '::notice::mirror-dockerhub: DOCKERHUB_USERNAME unset — skipping DockerHub mirror\n' >&2
        return 0
    fi

    local remote_cr="${REMOTE_CR:-ghcr.io/oorabona}"

    # Enumerate cells via the bake generator (same as bake-merge-manifests.sh).
    # Honor BAKE_GENERATE_ALL_RETAINED so the mirrored tag set matches what
    # bake-merge published (retained tags must not be absent on DockerHub).
    local _gen_retained_flag=()
    if [[ "${BAKE_GENERATE_ALL_RETAINED:-false}" == "true" ]]; then
        _gen_retained_flag=("--all-retained")
    fi

    local cells_json
    local generator="${_MDH_SCRIPT_DIR}/../scripts/generate-bake-hcl.sh"
    if ! cells_json=$("$generator" --cells "${_gen_retained_flag[@]}" "${containers[@]}"); then
        printf '::warning::mirror-dockerhub: generate-bake-hcl.sh --cells failed — skipping DockerHub mirror\n' >&2
        return 0
    fi

    if ! jq -e 'type == "array"' <<< "$cells_json" >/dev/null 2>&1; then
        printf '::warning::mirror-dockerhub: --cells returned non-array — skipping DockerHub mirror\n' >&2
        return 0
    fi

    local ncells
    ncells=$(jq 'length' <<< "$cells_json")

    if [[ "$ncells" -eq 0 ]]; then
        printf '::notice::mirror-dockerhub: no cells to mirror\n' >&2
        return 0
    fi

    local i
    for (( i=0; i<ncells; i++ )); do
        local cell
        cell=$(jq -c ".[$i]" <<< "$cells_json")

        local container tag variant flavor is_default is_latest_version intermediate_ref
        container=$(jq -r '.container'        <<< "$cell")
        tag=$(jq -r '.tag'                    <<< "$cell")
        variant=$(jq -r '.variant // ""'      <<< "$cell")
        flavor=$(jq -r '.flavor // ""'        <<< "$cell")
        is_default=$(jq -r 'if .is_default then "true" else "false" end' <<< "$cell")
        # Gate rolling aliases on is_latest_version (same logic as _merge_cell)
        is_latest_version=$(jq -r 'if has("is_latest_version") then (if .is_latest_version then "true" else "false" end) else "true" end' <<< "$cell")
        # intermediate_ref holds the GHCR per-arch base ref (token already expanded
        # by --cells for the default REMOTE_CR; override expansion when REMOTE_CR differs)
        intermediate_ref=$(jq -r '.intermediate_ref' <<< "$cell")
        intermediate_ref="${intermediate_ref//\$\{REMOTE_CR\}/${remote_cr}}"

        # The final merged GHCR manifest ref (no arch suffix) is the source for the mirror.
        local ghcr_src="${remote_cr}/${container}:${tag}"

        # Compute the rolling-alias discriminator: variant preferred over flavor
        # (matches bake-merge-manifests.sh FIX F routing logic).
        local routing_suffix="${variant:-${flavor}}"

        # Enumerate tags using the same routing as compute_cell_tag_suffixes.
        # For retained non-latest cells, publish ONLY the versioned tag.
        local sfx
        while IFS= read -r sfx; do
            [[ -n "$sfx" ]] || continue
            # F2 gate: retained non-latest → versioned tag only
            if [[ "$is_latest_version" != "true" && "$sfx" != "$tag" ]]; then
                continue
            fi

            local dh_dst="docker.io/${DOCKERHUB_USERNAME}/${container}:${sfx}"

            # Dry-run: explicit branch prints the command and skips execution.
            # Real path: "$DOCKER" (quoted) runs the actual binary or bats mock.
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                printf 'DRY-RUN: docker buildx imagetools create -t %s %s\n' \
                    "$dh_dst" "$ghcr_src" >&2
            else
                if ! "$DOCKER" buildx imagetools create -t "$dh_dst" "$ghcr_src" 2>&1; then
                    printf '::warning::mirror-dockerhub: imagetools create failed for %s (best-effort, continuing)\n' \
                        "$dh_dst" >&2
                fi
            fi
        done < <(compute_cell_tag_suffixes "$tag" "$routing_suffix" "$is_default")
    done

    return 0
}

# ---------------------------------------------------------------------------
# main — standalone entry point
# ---------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        printf 'Usage: %s <container...>\n' "$(basename "$0")" >&2
        return 1
    fi
    mirror_to_dockerhub "$@"
}

# Guard: only invoke main when executed directly (not sourced by bats or callers)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
