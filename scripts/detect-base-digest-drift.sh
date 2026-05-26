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
#                     (image_ref) and output a JSON manifest on stdout.
#                     Defaults to: docker manifest inspect <ref>
#
# Exit codes:
#   0   — Success (drift/unchanged/legacy/error records emitted; drift itself is NOT an error)
#   1   — Fatal script error (e.g., invalid digest shape passed to emit)
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
# Uses the same extraction logic as scripts/build-container.sh:272:
#   docker manifest inspect <ref> | grep -o '"sha256:[a-f0-9]*"' | head -1 | tr -d '"'
#
# This extracts the first SHA256 that appears in the manifest JSON, which for
# a multi-arch image index is the index digest embedded in the response body.
#
# For fixture-based testing, set PROBE_CMD to a function/script that reads
# a pre-captured manifest JSON from a file named after the image ref.
# ---------------------------------------------------------------------------
_probe_digest() {
    local image_ref="$1"
    local raw

    if [[ -n "${PROBE_CMD:-}" ]]; then
        # Stub: PROBE_CMD is a function/path that accepts image_ref as $1
        raw=$("${PROBE_CMD}" "${image_ref}" 2>/dev/null || true)
    else
        raw=$(docker manifest inspect "${image_ref}" 2>/dev/null || true)
    fi

    if [[ -z "$raw" ]]; then
        return 1
    fi

    local digest
    digest=$(printf '%s' "$raw" | grep -o '"sha256:[a-f0-9]*"' | head -1 | tr -d '"' || true)

    if [[ -z "$digest" ]]; then
        return 1
    fi

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
        echo "::warning::Skipping $basename_file: missing 'container' field" >&2
        continue
    fi

    variant_tag=$(jq -re '.tag // empty' "$lineage_file" 2>/dev/null || true)
    if [[ -z "$variant_tag" ]]; then
        echo "::warning::Skipping $basename_file: missing 'tag' field" >&2
        continue
    fi

    base_image_ref=$(jq -re '.base_image_ref // empty' "$lineage_file" 2>/dev/null || true)
    recorded_digest=$(jq -re '.base_image_digest // empty' "$lineage_file" 2>/dev/null || true)

    # Track container ordering
    if [[ -z "${_container_variants[$container]+x}" ]]; then
        _container_order+=("$container")
        _container_variants["$container"]=""
    fi

    # ---------------------------------------------------------------------------
    # Determine status
    # ---------------------------------------------------------------------------

    # Legacy: lineage lacks base_image_digest field
    if [[ -z "$recorded_digest" || "$recorded_digest" == "unresolved" ]]; then
        safe_ref=$(_sanitize_for_json "${base_image_ref:-unknown}")
        variant_json=$(jq -cn \
            --arg variant_tag  "$variant_tag" \
            --arg base_ref     "$safe_ref" \
            --arg status       "legacy" \
            '{variant_tag: $variant_tag, base_image_ref: $base_ref, status: $status, legacy: true}')

        if [[ "$BASELINE_ONLY" == "true" ]]; then
            # In baseline mode, emit legacy records
            _container_variants["$container"]+="${variant_json}"$'\n'
        else
            # Normal mode: legacy is treated as drift-equivalent (will trigger PR)
            _container_variants["$container"]+="${variant_json}"$'\n'
        fi
        continue
    fi

    # Skip if base_image_ref is unresolved (placeholder from pre-#530 lineage)
    if [[ "$base_image_ref" =~ \$ ]]; then
        echo "::warning::Skipping $basename_file: base_image_ref contains unresolved placeholder: $base_image_ref" >&2
        continue
    fi

    # Skip if no base_image_ref
    if [[ -z "$base_image_ref" || "$base_image_ref" == "unknown" ]]; then
        echo "::warning::Skipping $basename_file: base_image_ref is unknown" >&2
        continue
    fi

    # In baseline-only mode, suppress real drift records
    if [[ "$BASELINE_ONLY" == "true" ]]; then
        continue
    fi

    # Probe current digest
    current_digest=""
    probe_failed=false
    if ! current_digest=$(_probe_digest "$base_image_ref"); then
        probe_failed=true
    fi

    if [[ "$probe_failed" == "true" || -z "$current_digest" ]]; then
        echo "::warning::Probe failed for $base_image_ref (container=$container tag=$variant_tag)" >&2
        safe_ref=$(_sanitize_for_json "$base_image_ref")
        safe_recorded=$(_sanitize_for_json "$recorded_digest")
        variant_json=$(jq -cn \
            --arg variant_tag       "$variant_tag" \
            --arg base_ref          "$safe_ref" \
            --arg recorded_digest   "$safe_recorded" \
            --arg status            "error" \
            '{variant_tag: $variant_tag, base_image_ref: $base_ref, recorded_digest: $recorded_digest, status: $status}')
        _container_variants["$container"]+="${variant_json}"$'\n'
        continue
    fi

    # Validate digest shape (injection prevention)
    if ! _validate_digest_shape "$current_digest"; then
        echo "::error::Registry returned malformed digest for $base_image_ref: '$current_digest' — refusing to emit record" >&2
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
        echo "::warning::Skipping container '$container': could not build valid variants JSON" >&2
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
