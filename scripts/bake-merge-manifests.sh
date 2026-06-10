#!/usr/bin/env bash
# bake-merge-manifests.sh — ADR-013 R3: merge per-arch intermediate refs into
# final published multi-arch manifests on GHCR (strict/fail-closed).
#
# Usage:
#   scripts/bake-merge-manifests.sh                    # whole fleet
#   scripts/bake-merge-manifests.sh web-shell debian   # specific containers
#
# The cell plan comes from:
#   scripts/generate-bake-hcl.sh --cells [containers...]
#
# For each cell the script creates a merged manifest from:
#   <intermediate_ref>-amd64  and  <intermediate_ref>-arm64
#
# GHCR-ONLY: bake intermediates live only on GHCR (REMOTE_CR) per the
# egress-containment design (ADR-013).  Cross-registry DockerHub manifest
# creation is deferred to the production cutover — the existing auto-build.yaml
# pipeline continues to publish DockerHub.
#
# GHCR publish is STRICT (fail-closed): both arch sources required; any failure
# fails the cell and the overall run.
#
# Tag routing: delegates to helpers/variant-utils.sh::compute_cell_tag_suffixes
# (GHCR-only, routing helper).  Rolling :latest/:latest-<flavor> aliases are
# gated on is_latest_version==true to prevent retained versions clobbering :latest.
#
# Dry-run: set DRY_RUN=true (or DOCKER="echo docker") to emit the
# imagetools create command lines without executing them.
#
# Requirements:
#   bash 4+, docker (with buildx imagetools), jq

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------
# shellcheck source=../helpers/logging.sh
source "${PROJECT_ROOT}/helpers/logging.sh"
# shellcheck source=../helpers/retry.sh
source "${PROJECT_ROOT}/helpers/retry.sh"
# shellcheck source=../helpers/variant-utils.sh
source "${PROJECT_ROOT}/helpers/variant-utils.sh"

# Force config-only dep resolution (no lineage dir needed for merge)
export _DEPGRAPH_LINEAGE_DIR=/nonexistent

# FIX G: logging.sh already defaults DOCKER; make it explicit so set -u is
# provably safe regardless of sourcing order.
DOCKER="${DOCKER:-docker}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# REMOTE_CR: GHCR namespace (default matches bake variable default)
REMOTE_CR="${REMOTE_CR:-ghcr.io/oorabona}"

# ---------------------------------------------------------------------------
# _merge_cell — merge one cell's arch refs into final GHCR manifests.
#
# GHCR-ONLY: bake intermediates live only on GHCR (REMOTE_CR) per the
# egress-containment design (ADR-013).  Cross-registry DockerHub manifest
# creation is deferred to the production cutover.
#
# GHCR: strict / fail-closed.  Requires both -amd64 and -arm64 sources.
# No single-arch fallback (ADR-013 §4).
#
# F2 / is_latest_version gate: when true, all suffixes from
# compute_cell_tag_suffixes are published (versioned + rolling aliases).
# When false (retained non-latest version), ONLY the versioned suffix is
# published — rolling :latest/:latest-<variant> are suppressed to prevent
# older retained versions from clobbering the :latest pointer.
#
# FIX F: rolling aliases route by VARIANT (not flavor) to match production
# latest-$VARIANT (helpers/create-manifest.sh).  Flavor is non-unique for
# multi-build_flavor containers like github-runner (debian-trixie-base and
# debian-trixie-dev share flavor="debian-trixie" but have distinct variants).
#
# Args: <container> <tag> <flavor> <is_default> <intermediate_ref> <is_latest_version> <variant>
#   intermediate_ref has the literal "${REMOTE_CR}" token already expanded.
# ---------------------------------------------------------------------------
_merge_cell() {
    local container="$1"
    local tag="$2"
    local flavor="$3"
    local is_default="$4"
    local intermediate_ref="$5"
    local is_latest_version="${6:-true}"   # default true for backward compat
    local variant="${7:-$flavor}"          # FIX F: variant for rolling-alias suffix; fall back to flavor

    local ghcr_image="${REMOTE_CR}/${container}"

    local src_amd64="${intermediate_ref}-amd64"
    local src_arm64="${intermediate_ref}-arm64"

    # ------------------------------------------------------------------
    # Compute GHCR final tag refs via compute_cell_tag_suffixes.
    # FIX F: pass $variant (not $flavor) as the rolling-alias discriminator
    # so each cell gets a unique latest-<variant> alias.
    # F2: when is_latest_version==false, keep ONLY the versioned suffix
    # (first line from compute_cell_tag_suffixes); drop rolling aliases.
    # ------------------------------------------------------------------
    local -a ghcr_refs=()
    local sfx
    while IFS= read -r sfx; do
        [[ -n "$sfx" ]] || continue
        # F2 gate: for retained non-latest cells, publish only the versioned
        # suffix (which equals $tag, the first line from the helper).
        if [[ "$is_latest_version" != "true" && "$sfx" != "$tag" ]]; then
            continue
        fi
        ghcr_refs+=("${ghcr_image}:${sfx}")
    done < <(compute_cell_tag_suffixes "$tag" "$variant" "$is_default")

    if [[ ${#ghcr_refs[@]} -eq 0 ]]; then
        printf '::error::No GHCR refs computed for %s:%s — skipping cell\n' \
            "$container" "$tag" >&2
        return 1
    fi

    # ------------------------------------------------------------------
    # GHCR publish — STRICT / fail-closed
    # Both arch sources required.  No single-arch fallback (ADR-013 §4).
    # All GHCR final refs pushed in one imagetools create call so all
    # rolling aliases point at the same merged index.
    # ------------------------------------------------------------------
    local -a ghcr_tag_args=()
    for ref in "${ghcr_refs[@]}"; do
        ghcr_tag_args+=("-t" "$ref")
    done

    log_step "Merging GHCR manifest for ${container}:${tag}" >&2

    # ------------------------------------------------------------------
    # DRY_RUN: emit the command visibly and return without executing.
    # The documented contract (header L27) requires the command line to
    # appear on stdout so operators can inspect it.  The real path below
    # uses $DOCKER indirection (for bats mock testing); DRY_RUN is a
    # separate, unambiguously non-mutating branch.
    # ------------------------------------------------------------------
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        printf 'DRY-RUN: docker buildx imagetools create %s %s %s\n' \
            "${ghcr_tag_args[*]}" "$src_amd64" "$src_arm64"
        printf '::notice::[dry-run] GHCR manifest for %s:%s (%d refs) NOT pushed\n' \
            "$container" "$tag" "${#ghcr_refs[@]}" >&2
        return 0
    fi

    local err_output
    if ! err_output=$(retry_with_backoff 3 10 \
        "$DOCKER" buildx imagetools create \
        "${ghcr_tag_args[@]}" \
        "$src_amd64" \
        "$src_arm64" 2>&1); then
        printf '::error::GHCR merge failed for %s:%s — %s\n' \
            "$container" "$tag" "$err_output" >&2
        return 1
    fi
    printf '::notice::GHCR manifest created for %s:%s (%d refs)\n' \
        "$container" "$tag" "${#ghcr_refs[@]}" >&2

    return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local -a requested=("$@")

    # ------------------------------------------------------------------
    # Obtain cell plan from the generator --cells mode.
    # Generator stderr is intentionally NOT suppressed so diagnostics
    # (including depgraph errors and ::error:: notices) surface in CI logs.
    # ------------------------------------------------------------------
    local cells_json
    if [[ ${#requested[@]} -gt 0 ]]; then
        if ! cells_json=$("${SCRIPT_DIR}/generate-bake-hcl.sh" --cells "${requested[@]}"); then
            printf '::error::generate-bake-hcl.sh --cells failed (see generator error above) — aborting merge\n' >&2
            exit 1
        fi
    else
        if ! cells_json=$("${SCRIPT_DIR}/generate-bake-hcl.sh" --cells); then
            printf '::error::generate-bake-hcl.sh --cells failed (see generator error above) — aborting merge\n' >&2
            exit 1
        fi
    fi

    if ! jq -e 'type == "array"' <<< "$cells_json" >/dev/null 2>&1; then
        printf '::error::generate-bake-hcl.sh --cells returned non-array output\n' >&2
        exit 1
    fi

    local ncells
    ncells=$(jq 'length' <<< "$cells_json")
    if [[ "$ncells" -eq 0 ]]; then
        printf '::warning::No cells to merge (empty plan)\n' >&2
        exit 0
    fi

    printf '::notice::Merging %d cells\n' "$ncells" >&2

    # ------------------------------------------------------------------
    # FIX F (duplicate-final-ref guard): before processing, verify that no
    # two cells would publish the same final GHCR ref.  Two cells sharing a
    # ref means one merge silently overwrites the other (silent corruption).
    # Fail-closed: abort the entire run if any collision is detected.
    # ------------------------------------------------------------------
    local -A _seen_refs=()
    local _ci
    for (( _ci=0; _ci<ncells; _ci++ )); do
        local _chk_cell
        _chk_cell=$(jq -c ".[$_ci]" <<< "$cells_json")
        local _chk_c _chk_tag _chk_flavor _chk_variant _chk_default _chk_latest _chk_iref
        _chk_c=$(jq -r '.container'     <<< "$_chk_cell")
        _chk_tag=$(jq -r '.tag'         <<< "$_chk_cell")
        _chk_flavor=$(jq -r '.flavor // ""'  <<< "$_chk_cell")
        _chk_variant=$(jq -r '.variant // ""' <<< "$_chk_cell")
        _chk_default=$(jq -r 'if .is_default then "true" else "false" end' <<< "$_chk_cell")
        _chk_latest=$(jq -r 'if has("is_latest_version") then (if .is_latest_version then "true" else "false" end) else "true" end' <<< "$_chk_cell")
        _chk_iref=$(jq -r '.intermediate_ref' <<< "$_chk_cell")
        _chk_iref="${_chk_iref//\$\{REMOTE_CR\}/${REMOTE_CR}}"
        # Use the same routing logic as _merge_cell (variant for rolling suffix)
        local _routing_suffix="${_chk_variant:-$_chk_flavor}"
        local _sfx
        while IFS= read -r _sfx; do
            [[ -n "$_sfx" ]] || continue
            if [[ "$_chk_latest" != "true" && "$_sfx" != "$_chk_tag" ]]; then
                continue
            fi
            local _fref="${REMOTE_CR}/${_chk_c}:${_sfx}"
            local _cell_id="${_chk_c}:${_chk_tag}(${_routing_suffix})"
            if [[ -n "${_seen_refs[$_fref]+set}" ]]; then
                printf '::error::Duplicate final ref detected: %s would be published by both %s and %s — aborting\n' \
                    "$_fref" "${_seen_refs[$_fref]}" "$_cell_id" >&2
                exit 1
            fi
            _seen_refs["$_fref"]="$_cell_id"
        done < <(compute_cell_tag_suffixes "$_chk_tag" "$_routing_suffix" "$_chk_default")
    done

    # ------------------------------------------------------------------
    # Process each cell
    # ------------------------------------------------------------------
    local failed=0
    local i
    for (( i=0; i<ncells; i++ )); do
        local cell
        cell=$(jq -c ".[$i]" <<< "$cells_json")

        local container tag flavor variant is_default intermediate_ref is_latest_version
        container=$(jq -r '.container'        <<< "$cell")
        tag=$(jq -r '.tag'                    <<< "$cell")
        flavor=$(jq -r '.flavor // ""'        <<< "$cell")
        # FIX F: variant is the unique per-cell name for rolling-alias routing
        variant=$(jq -r '.variant // ""'      <<< "$cell")
        is_default=$(jq -r 'if .is_default then "true" else "false" end' <<< "$cell")
        # F2: read is_latest_version; default to "true" for backward compat when field absent.
        is_latest_version=$(jq -r 'if has("is_latest_version") then (if .is_latest_version then "true" else "false" end) else "true" end' <<< "$cell")
        # Expand the literal ${REMOTE_CR} token using the resolved env value
        intermediate_ref=$(jq -r '.intermediate_ref' <<< "$cell")
        intermediate_ref="${intermediate_ref//\$\{REMOTE_CR\}/${REMOTE_CR}}"

        if ! _merge_cell "$container" "$tag" "$flavor" "$is_default" \
                "$intermediate_ref" "$is_latest_version" "$variant"; then
            printf '::error::Cell merge FAILED: %s:%s\n' "$container" "$tag" >&2
            failed=$(( failed + 1 ))
        fi
    done

    # ------------------------------------------------------------------
    # Aggregate result: any GHCR failure → non-zero exit (fail-closed)
    # ------------------------------------------------------------------
    if [[ "$failed" -gt 0 ]]; then
        printf '::error::%d cell(s) failed GHCR merge — see above for details\n' \
            "$failed" >&2
        exit 1
    fi

    printf '::notice::All %d cells merged successfully\n' "$ncells" >&2
}

# Allow sourcing for unit tests (BASH_SOURCE[0] != $0 when sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
