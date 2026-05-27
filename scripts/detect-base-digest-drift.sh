#!/usr/bin/env bash
# detect-base-digest-drift.sh — Compare recorded base_image_digest in .build-lineage/
# against the current registry digest for each container/variant.
#
# Outputs a JSON array on stdout, grouped per container:
#   [{"container":"foo","variants":[{"variant_tag":"1.0-alpine","status":"drift",...},...]}]
#
# Tri-state status per variant:
#   drift     — recorded_digest != current_digest (real drift)
#   unchanged — recorded_digest == current_digest (no action needed)
#   error     — registry probe failed (timeout, 401, 404); NOT collapsed to drift
#   legacy    — lineage lacks base_image_digest field (pre-v2); rebuild baselines it
#
# Usage:
#   detect-base-digest-drift.sh [--baseline-only] [LINEAGE_DIR]
#
# Options:
#   --baseline-only   Emit ONLY status:legacy records; suppress real drifts.
#                     Use ONCE after #532 merge to baseline pre-v2 lineage.
#   LINEAGE_DIR       Override lineage directory (default: .build-lineage/)
#
# Env:
#   PROBE_CMD         Override probe command for testing. Must accept one arg
#                     (image_ref) and print the image-index manifest digest to
#                     stdout (sha256:... string).
#                     Defaults to: docker buildx imagetools inspect --format
#                       '{{json .Manifest}}' <ref> | jq -r '.digest'
#                     (canonical multi-arch image-index digest via buildx
#                     imagetools — order-independent, single source of truth,
#                     matches scripts/build-container.sh digest extraction)
#
# Exit codes:
#   0   — Success (drift/unchanged/legacy/error records emitted; drift itself is NOT an error)
#   1   — Fatal script error (e.g., invalid digest shape passed to emit)
#   2   — Tooling failure (./make list unavailable or returned empty)
#
# Digest shape validation (injection prevention):
#   Every digest extracted from the registry is validated against
#   ^sha256:[a-f0-9]{64}$ before inclusion in any output record.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------
# shellcheck source=../helpers/lineage-utils.sh
source "${PROJECT_ROOT}/helpers/lineage-utils.sh"

# ---------------------------------------------------------------------------
# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a `::keyword::value` GitHub Actions
# workflow command.  Without this, a newline/CR/`%` in the value could
# terminate the command early and inject another (e.g. `::add-mask::`,
# `::stop-commands::`).  Mapping per GitHub's runner spec:
#   %  → %25
#   \n → %0A
#   \r → %0D
#
# Pattern sourced from helpers/base-cache-utils.sh::_escape_gha_command;
# inlined here to avoid importing the full base-cache helper.
# ---------------------------------------------------------------------------
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
BASELINE_ONLY=false
LINEAGE_DIR="${PROJECT_ROOT}/.build-lineage"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-only)
            BASELINE_ONLY=true
            shift
            ;;
        -*)
            echo "::error::Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            LINEAGE_DIR="$1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Probe function — extract IMAGE-INDEX digest from a registry manifest
#
# Uses `docker buildx imagetools inspect --format '{{json .Manifest}}'` to
# obtain the IMAGE-INDEX (manifest-list) digest.  This is the same method
# used by the writer in build-container.sh, so writer and probe always agree
# on multi-arch images.
#
# The previous `docker manifest inspect | jq -r '.digest'` approach was
# unreliable: `docker manifest inspect` does NOT include a top-level `.digest`
# field in its JSON body (the digest is only in the HTTP response Content-Digest
# header).  imagetools inspect --format '{{json .Manifest}}' exposes the
# authoritative OCI index descriptor including `.digest`.
#
# For fixture-based testing, set PROBE_CMD to a function/script that accepts
# image_ref as $1 and outputs the `{{json .Manifest}}` JSON on stdout.
# ---------------------------------------------------------------------------
_probe_digest() {
    local image_ref="$1"
    local raw
    local probe_stderr
    local probe_exit=0
    local safe_ref
    safe_ref=$(_escape_gha_command "$image_ref")

    # Explicit cleanup on every return path below.  We do NOT use
    # `trap '...' RETURN` because bash RETURN traps are GLOBAL — they fire on
    # every subsequent function return in the same shell, not just returns from
    # the function that set them.  Under set -u that crashes the script after
    # the first _probe_digest call when probe_stderr is out of scope.
    probe_stderr=$(mktemp)

    if [[ -n "${PROBE_CMD:-}" ]]; then
        # Stub: PROBE_CMD is a function/path that accepts image_ref as $1
        raw=$("${PROBE_CMD}" "${image_ref}" 2>"$probe_stderr") || probe_exit=$?
        if [[ $probe_exit -ne 0 ]]; then
            local err_detail
            err_detail=$(cat "$probe_stderr" 2>/dev/null || true)
            [[ -n "$err_detail" ]] && printf '::error::probe-cmd-error for %s: %s\n' "$safe_ref" "$(_escape_gha_command "$err_detail")" >&2
            rm -f "$probe_stderr"
            return 1
        fi
    else
        raw=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "${image_ref}" 2>"$probe_stderr") || probe_exit=$?
        if [[ $probe_exit -ne 0 ]]; then
            local err_detail
            err_detail=$(cat "$probe_stderr" 2>/dev/null || true)
            printf '::error::imagetools inspect failed for %s: %s\n' "$safe_ref" "$(_escape_gha_command "$err_detail")" >&2
            rm -f "$probe_stderr"
            return 1
        fi
    fi

    if [[ -z "$raw" ]]; then
        printf '::error::imagetools inspect returned empty output for %s\n' "$safe_ref" >&2
        rm -f "$probe_stderr"
        return 1
    fi

    # Extract image-index digest: .digest from the OCI index descriptor JSON
    local digest
    digest=$(printf '%s' "$raw" | jq -r '.digest // empty' 2>/dev/null || true)

    if [[ -z "$digest" ]]; then
        printf '::error::could not extract digest from manifest for %s\n' "$safe_ref" >&2
        rm -f "$probe_stderr"
        return 1
    fi

    rm -f "$probe_stderr"
    printf '%s' "$digest"
    return 0
}

# ---------------------------------------------------------------------------
# Digest shape validation
# Validates ^sha256:[a-f0-9]{64}$ — refuse if invalid.
# ---------------------------------------------------------------------------
_validate_digest_shape() {
    local digest="$1"
    # Must match sha256: followed by exactly 64 lowercase hex chars
    if [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Sanitize a string for safe embedding in JSON string values.
# Strips/replaces: backticks, pipes, newlines, carriage returns.
# ---------------------------------------------------------------------------
_sanitize_for_json() {
    local val="$1"
    # Use printf %s to avoid escape interpretation, then sed for replacement
    printf '%s' "$val" | tr -d '`|\n\r'
}

# ---------------------------------------------------------------------------
# Validate base_image_ref shape and registry allowlist (SSRF prevention).
#
# A poisoned lineage cache with an attacker-controlled base_image_ref could
# cause the workflow to probe an untrusted registry with Docker credentials,
# potentially leaking tokens or enabling SSRF abuse.
#
# Accepts:
#   - Docker Hub bare names:  alpine:3.21, postgres:17-alpine, org/image:tag
#   - Explicit GHCR refs:     ghcr.io/owner/image:tag[@digest]
#   - Microsoft MCR refs:     mcr.microsoft.com/windows/servercore:ltsc2022
#
# Rejects anything whose registry component is not in the above set.
#
# Registry detection (per OCI Distribution Spec):
#   An explicit registry is present only when the ref contains a '/' AND the
#   first path segment (before the first '/') contains a '.' (FQDN) or a ':'
#   (host:port pattern like localhost:5000).
#   If the ref has no '/', it is always a Docker Hub bare name (image:tag).
#   If the ref has '/' but the first segment has no '.' and no ':', the first
#   segment is a Docker Hub org name (e.g., hashicorp/terraform:1.14.4).
#
# Returns 0 if valid, 1 if rejected.
# ---------------------------------------------------------------------------
_validate_image_ref() {
    local ref="$1"

    # Reject refs starting with '/' — first_segment would be empty, which
    # falls through the OCI registry-host check with no meaningful value.
    [[ "$ref" == /* ]] && return 1

    # Must be non-empty and free of whitespace/control chars
    if [[ -z "$ref" || "$ref" =~ [[:space:][:cntrl:]] ]]; then
        return 1
    fi

    # No '/' in ref → always a Docker Hub bare name (image:tag or image:version)
    # e.g. alpine:3.21, postgres:17-alpine, ubuntu:latest
    if [[ "$ref" != *"/"* ]]; then
        return 0
    fi

    # Ref has at least one '/' — check if the first segment is an explicit registry.
    # Per OCI spec, the first segment is a registry host only if it contains '.'
    # (FQDN) or ':' (host:port).  Otherwise it is a Docker Hub org name.
    local first_segment="${ref%%/*}"

    # Reject localhost-as-registry: Docker/OCI treats bare 'localhost' (and
    # 'localhost:PORT') as an explicit registry host, not a Docker Hub namespace.
    # Allowing it would bypass the registry allowlist on self-hosted runners.
    if [[ "$first_segment" == "localhost" || "$first_segment" == localhost:* ]]; then
        return 1
    fi

    # Docker Hub org/image pattern (e.g. hashicorp/terraform:1.14.4)
    if [[ "$first_segment" != *"."* && "$first_segment" != *":"* ]]; then
        return 0
    fi

    # Explicit registry FQDN or host:port — check against allowlist
    local registry="$first_segment"
    case "$registry" in
        docker.io | \
        ghcr.io | \
        registry-1.docker.io | \
        index.docker.io | \
        mcr.microsoft.com)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Walk lineage directory
# ---------------------------------------------------------------------------
if [[ ! -d "$LINEAGE_DIR" ]]; then
    echo "::warning::Lineage directory '$LINEAGE_DIR' does not exist — nothing to check" >&2
    printf '[]'
    exit 0
fi

# Collect all *.json files; sort for deterministic output
mapfile -t lineage_files < <(find "$LINEAGE_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)

if [[ ${#lineage_files[@]} -eq 0 ]]; then
    echo "::warning::Lineage cache empty — no .json files in '$LINEAGE_DIR'; skipping drift check" >&2
    printf '[]'
    exit 0
fi

# ---------------------------------------------------------------------------
# Per-variant processing — build associative maps keyed by container name
# ---------------------------------------------------------------------------
# We accumulate variant JSON fragments per container name, then assemble.

declare -A _container_variants  # container_name -> newline-separated JSON fragments
declare -a _container_order     # ordered list of unique container names seen

for lineage_file in "${lineage_files[@]}"; do
    basename_file="$(basename "$lineage_file")"

    # Skip sidecar files via single source of truth
    if is_lineage_sidecar "$basename_file"; then
        continue
    fi

    # Parse required fields
    container=$(jq -re '.container // empty' "$lineage_file" 2>/dev/null || true)
    if [[ -z "$container" ]]; then
        printf '::warning::Skipping %s: missing '\''container'\'' field\n' "$(_escape_gha_command "$basename_file")" >&2
        continue
    fi

    # Control-character rejection — MUST be BEFORE any validation or caching.
    # A value like $'ansible\nmalicious' contains a newline which grep -xF treats
    # as TWO patterns, so "ansible" matches and "malicious" passes validation silently.
    # Explicit cntrl-char rejection at entry point closes that bypass entirely.
    if [[ "$container" =~ [[:cntrl:]] ]]; then
        printf '::warning::Rejecting lineage entry %s: container name contains control chars: %s\n' \
            "$(_escape_gha_command "$basename_file")" "$(printf '%q' "$container")" >&2
        continue
    fi

    # Validate container name against canonical list (poisoning prevention)
    # A corrupted entry (e.g. container: "docs", container: ".github", or a path
    # with "/") could otherwise cause the bot to act on non-container directories.
    #
    # _VALID_CONTAINERS_OVERRIDE: test hook — when set, use this newline-separated
    # list instead of ./make list (avoids needing the full project context in tests).
    if [[ -z "${_valid_containers+x}" ]]; then
        # Cache the list on first use (avoids re-running ./make list per file)
        if [[ -n "${_VALID_CONTAINERS_OVERRIDE:-}" ]]; then
            _valid_containers="$_VALID_CONTAINERS_OVERRIDE"
        else
            _valid_containers=$(cd "$PROJECT_ROOT" && ./make list) || _valid_containers=""
            if [[ -z "$_valid_containers" ]]; then
                printf '::error::./make list returned empty — canonical container list unavailable\n' >&2
                exit 2
            fi
        fi
    fi
    if ! grep -qxF -- "$container" <<<"$_valid_containers"; then
        printf '::warning::Skipping %s: invalid container name '\''%s'\'' (not in ./make list)\n' \
            "$(_escape_gha_command "$basename_file")" "$(_escape_gha_command "$container")" >&2
        continue
    fi

    variant_tag=$(jq -re '.tag // empty' "$lineage_file" 2>/dev/null || true)
    if [[ -z "$variant_tag" ]]; then
        printf '::warning::Skipping %s: missing '\''tag'\'' field\n' "$(_escape_gha_command "$basename_file")" >&2
        continue
    fi

    # Reject tags with control characters before any grep/markdown operations.
    # A tag like "active\npayload" would pass grep -xF (multiple patterns) and
    # reach markdown with incomplete escaping. Validate early to close bypass.
    if [[ "$variant_tag" =~ [[:cntrl:]] ]]; then
        printf '::warning::Rejecting lineage entry %s: tag contains control chars: %s\n' \
            "$(_escape_gha_command "$basename_file")" "$(printf '%q' "$variant_tag")" >&2
        continue
    fi

    # Sanitize tag for safe embedding in GHA commands / markdown.
    # Applied here so every downstream use of $variant_tag_safe is already clean.
    variant_tag_safe=$(_escape_gha_command "$variant_tag")

    # Filter to active build-matrix tags only (NORMAL MODE ONLY).
    # In --baseline-only mode, we intentionally emit ALL pre-v2 entries including
    # stale ones, so the stale-lineage filter is bypassed until baseline is complete.
    # In normal (cron) mode: stale lineage files for dropped/non-retained tags persist
    # in the cache after rotation. Without this filter each cron run re-detects drift
    # on them, opens a PR, the PR rebuild only updates current retained tags → stale
    # lineage unchanged → next cron re-detects → infinite PR loop.
    if [[ "$BASELINE_ONLY" != "true" ]]; then
        # _ACTIVE_TAGS_OVERRIDE_<container>: test hook — set to a newline-separated list
        # of active tags for a container to bypass ./make list-builds in tests.
        # If _VALID_CONTAINERS_OVERRIDE is set (test mode) and _ACTIVE_TAGS_OVERRIDE_*
        # is NOT set, disable filtering for that container (test-mode default).
        #
        # Cache key: _active_tags_cache_<container> (associative array not available in
        # bash <4.2 without namerefs; use indirect variable via printf '%s' trick).
        _active_tags_var="_active_tags_cache_${container//-/_}"
        if [[ -z "${!_active_tags_var+x}" ]]; then
            # Check for per-container test hook first
            _override_var="_ACTIVE_TAGS_OVERRIDE_${container//-/_}"
            if [[ -n "${!_override_var:-}" ]]; then
                # Override is explicitly set (even if empty) — use it as-is
                printf -v "$_active_tags_var" '%s' "${!_override_var}"
            elif [[ -n "${_VALID_CONTAINERS_OVERRIDE:-}" ]]; then
                # Test mode detected but no per-container override — disable filtering
                printf -v "$_active_tags_var" '%s' "__TEST_NO_FILTER__"
            else
                # Production mode: list-builds may fail transiently (upstream discovery, version script timeout).
                # FAIL CLOSED: skip ALL variants for this container (no drift detection) rather than
                # disabling the stale-lineage filter.  Disabling the filter is worse — it allows stale
                # lineage entries to re-trigger drift PRs on every cron run (infinite PR loop).
                # A missed drift during a transient failure is recoverable; a runaway PR loop is not.
                _lb_rc=0
                _fetched=$(cd "$PROJECT_ROOT" && ./make list-builds "$container" 2>/dev/null) || _lb_rc=$?
                if [[ "$_lb_rc" -ne 0 ]]; then
                    printf '::warning::./make list-builds %s failed (rc=%s) — skipping entire container (fail-closed; retry next cron run)\n' "$container" "$_lb_rc" >&2
                    # Mark container as fully skipped so the outer loop continues to the next container
                    printf -v "$_active_tags_var" '%s' "__CONTAINER_SKIP__"
                else
                    _fetched=$(printf '%s' "$_fetched" | jq -r '.[].tag // empty' 2>/dev/null | sort -u || echo "")
                    if [[ -z "$_fetched" ]]; then
                        printf '::warning::./make list-builds %s returned no tags — skipping entire container (fail-closed; retry next cron run)\n' "$container" >&2
                        printf -v "$_active_tags_var" '%s' "__CONTAINER_SKIP__"
                    else
                        printf -v "$_active_tags_var" '%s' "$_fetched"
                    fi
                fi
            fi
        fi
        _active_tags="${!_active_tags_var}"
        # Fail-closed: if list-builds failed for this container, skip ALL its variants
        if [[ "$_active_tags" == "__CONTAINER_SKIP__" ]]; then
            continue
        fi
        # Skip filtering if: test-mode no-filter (__TEST_NO_FILTER__),
        # empty override (backward compat), or tag matches active set
        if [[ "$_active_tags" != "__TEST_NO_FILTER__" && -n "$_active_tags" ]] && ! grep -qxF -- "$variant_tag" <<<"$_active_tags"; then
            printf '::notice::Skipping stale lineage entry: %s:%s (no longer in active build matrix)\n' \
                "$(_escape_gha_command "$container")" "$variant_tag_safe" >&2
            continue
        fi
    fi

    base_image_ref=$(jq -re '.base_image_ref // empty' "$lineage_file" 2>/dev/null || true)
    recorded_digest=$(jq -re '.base_image_digest // empty' "$lineage_file" 2>/dev/null || true)
    error_reason=""

    # Track container ordering
    if [[ -z "${_container_variants[$container]+x}" ]]; then
        _container_order+=("$container")
        _container_variants["$container"]=""
    fi

    # ---------------------------------------------------------------------------
    # Determine status
    # ---------------------------------------------------------------------------

    # Fix 4 (baseline-only precedence):
    # In --baseline-only mode the goal is to baseline ALL pre-v2 entries, including
    # ones where base_image_ref still contains a placeholder.  So legacy-emit takes
    # precedence over the placeholder-skip in baseline mode.
    #
    # In normal (cron) mode the placeholder-skip MUST run first: a file with ${...}
    # in base_image_ref and no recorded digest must not be mis-classified as legacy
    # and trigger a bogus drift PR.
    if [[ "$BASELINE_ONLY" == "true" ]]; then
        # Baseline mode: emit legacy first (even for placeholder refs)
        if [[ -z "$recorded_digest" || "$recorded_digest" == "unresolved" ]]; then
            safe_ref=$(_sanitize_for_json "${base_image_ref:-unknown}")
            variant_json=$(jq -cn \
                --arg variant_tag  "$variant_tag" \
                --arg base_ref     "$safe_ref" \
                --arg status       "legacy" \
                '{variant_tag: $variant_tag, base_image_ref: $base_ref, status: $status, legacy: true}')
            _container_variants["$container"]+="${variant_json}"$'\n'
            continue
        fi

        # Skip if base_image_ref is a placeholder (non-legacy entry with unresolved ref)
        if [[ "$base_image_ref" =~ \$ ]]; then
            printf '::warning::Skipping %s: base_image_ref contains unresolved placeholder: %s\n' \
                "$(_escape_gha_command "$basename_file")" "$(_escape_gha_command "$base_image_ref")" >&2
            continue
        fi

        # In baseline-only mode, suppress real drift records for fully-resolved entries
        continue
    fi

    # Normal mode: placeholder-skip runs before legacy check to prevent mis-classification
    if [[ "$base_image_ref" =~ \$ ]]; then
        printf '::warning::Skipping %s: base_image_ref contains unresolved placeholder: %s\n' \
            "$(_escape_gha_command "$basename_file")" "$(_escape_gha_command "$base_image_ref")" >&2
        continue
    fi

    # Skip if base_image_ref is unknown or missing (must run BEFORE legacy check
    # which would otherwise emit a legacy record for a corrupt/unknown entry).
    if [[ -z "$base_image_ref" || "$base_image_ref" == "unknown" ]]; then
        printf '::warning::Skipping %s: base_image_ref is unknown or missing\n' "$(_escape_gha_command "$basename_file")" >&2
        continue
    fi

    # Legacy: lineage lacks base_image_digest field (known base_image_ref only)
    if [[ -z "$recorded_digest" || "$recorded_digest" == "unresolved" ]]; then
        safe_ref=$(_sanitize_for_json "$base_image_ref")
        variant_json=$(jq -cn \
            --arg variant_tag  "$variant_tag" \
            --arg base_ref     "$safe_ref" \
            --arg status       "legacy" \
            '{variant_tag: $variant_tag, base_image_ref: $base_ref, status: $status, legacy: true}')
        # Normal mode: legacy is treated as drift-equivalent (will trigger PR)
        _container_variants["$container"]+="${variant_json}"$'\n'
        continue
    fi

    # Validate base_image_ref before probing (SSRF prevention).
    # Poisoned lineage with an attacker-controlled ref could cause the workflow
    # to probe an untrusted registry with Docker credentials.
    if ! _validate_image_ref "$base_image_ref"; then
        printf '::warning::Refusing to probe untrusted base_image_ref for %s:%s: %s\n' \
            "$(_escape_gha_command "$container")" "$variant_tag_safe" \
            "$(_escape_gha_command "$base_image_ref")" >&2
        continue
    fi

    # Probe current digest
    current_digest=""
    probe_failed=false
    if ! current_digest=$(_probe_digest "$base_image_ref"); then
        probe_failed=true
    fi

    if [[ "$probe_failed" == "true" || -z "$current_digest" ]]; then
        error_reason="registry probe failed for ${base_image_ref} (container=${container} tag=${variant_tag})"
        printf '::error::probe-error: %s\n' "$(_escape_gha_command "$error_reason")" >&2
        safe_ref=$(_sanitize_for_json "$base_image_ref")
        safe_recorded=$(_sanitize_for_json "$recorded_digest")
        safe_error=$(_sanitize_for_json "$error_reason")
        variant_json=$(jq -cn \
            --arg variant_tag       "$variant_tag" \
            --arg base_ref          "$safe_ref" \
            --arg recorded_digest   "$safe_recorded" \
            --arg status            "error" \
            --arg error_reason      "$safe_error" \
            '{variant_tag: $variant_tag, base_image_ref: $base_ref, recorded_digest: $recorded_digest, status: $status, error_reason: $error_reason}')
        _container_variants["$container"]+="${variant_json}"$'\n'
        continue
    fi

    # Validate digest shape (injection prevention)
    if ! _validate_digest_shape "$current_digest"; then
        printf '::error::Registry returned malformed digest for %s: '\''%s'\'' — refusing to emit record\n' \
            "$(_escape_gha_command "$base_image_ref")" "$(_escape_gha_command "$current_digest")" >&2
        exit 1
    fi

    # Compare
    safe_ref=$(_sanitize_for_json "$base_image_ref")
    safe_recorded=$(_sanitize_for_json "$recorded_digest")

    if [[ "$current_digest" == "$recorded_digest" ]]; then
        variant_json=$(jq -cn \
            --arg variant_tag       "$variant_tag" \
            --arg base_ref          "$safe_ref" \
            --arg recorded_digest   "$safe_recorded" \
            --arg current_digest    "$current_digest" \
            --arg status            "unchanged" \
            '{variant_tag: $variant_tag, base_image_ref: $base_ref, recorded_digest: $recorded_digest, current_digest: $current_digest, status: $status}')
    else
        variant_json=$(jq -cn \
            --arg variant_tag       "$variant_tag" \
            --arg base_ref          "$safe_ref" \
            --arg recorded_digest   "$safe_recorded" \
            --arg current_digest    "$current_digest" \
            --arg status            "drift" \
            '{variant_tag: $variant_tag, base_image_ref: $base_ref, recorded_digest: $recorded_digest, current_digest: $current_digest, status: $status}')
    fi

    _container_variants["$container"]+="${variant_json}"$'\n'
done

# ---------------------------------------------------------------------------
# Assemble final JSON output: array of {container, variants[]}
# ---------------------------------------------------------------------------
output="["
first_container=true

for container in "${_container_order[@]}"; do
    fragments="${_container_variants[$container]}"

    # Skip containers with no variant records (e.g., all skipped)
    if [[ -z "$fragments" ]]; then
        continue
    fi

    # Build variants array from newline-separated JSON fragments
    variants_array="["
    first_variant=true
    while IFS= read -r frag; do
        [[ -z "$frag" ]] && continue
        if [[ "$first_variant" == "true" ]]; then
            first_variant=false
        else
            variants_array+=","
        fi
        variants_array+="$frag"
    done <<< "$fragments"
    variants_array+="]"

    # Validate the variants array is valid JSON
    if ! printf '%s' "$variants_array" | jq '.' >/dev/null 2>&1; then
        printf '::warning::Skipping container '\''%s'\'': could not build valid variants JSON\n' \
            "$(_escape_gha_command "$container")" >&2
        continue
    fi

    container_json=$(jq -cn \
        --arg container "$container" \
        --argjson variants "$variants_array" \
        '{container: $container, variants: $variants}')

    if [[ "$first_container" == "true" ]]; then
        first_container=false
    else
        output+=","
    fi
    output+="$container_json"
done

output+="]"

# Final validation — output must be valid JSON
if ! printf '%s' "$output" | jq '.' >/dev/null 2>&1; then
    echo "::error::Internal error: output is not valid JSON" >&2
    exit 1
fi

printf '%s' "$output"
