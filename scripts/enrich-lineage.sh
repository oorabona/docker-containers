#!/usr/bin/env bash
# enrich-lineage.sh — Enrich .build-lineage/<container>-<tag>.json with multi-arch
# manifest data, sizes, platforms, and attestation links — fields that are IMMUTABLE
# post-build but were previously fetched per-dashboard-regen, causing 70+ min
# dashboard runtime on Windows variants (#515).
#
# Idempotent: running on already-enriched lineage is a no-op (fields preserved).
# Failure-tolerant: per-lineage errors are logged as ::warning:: but don't abort
# the batch. Missing GHCR data → field set to null (dashboard falls back to network).
#
# Usage:
#   enrich-lineage.sh [--owner <owner>] [--lineage-dir <dir>]
#
# Env requirements:
#   GH_TOKEN          — needed for gh api attestation lookup (CI: GITHUB_TOKEN)
#   GHCR auth         — implicit via ghcr_get_token() using gh auth token or anonymous

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OWNER="oorabona"
LINEAGE_DIR="${PROJECT_ROOT}/.build-lineage"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)
            OWNER="$2"
            shift 2
            ;;
        --lineage-dir)
            LINEAGE_DIR="$2"
            shift 2
            ;;
        *)
            echo "::error::Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------
# shellcheck source=../helpers/logging.sh
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/helpers/logging.sh"
# shellcheck source=../helpers/registry-utils.sh
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/helpers/registry-utils.sh"
# shellcheck source=../helpers/attestation-utils.sh
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/helpers/attestation-utils.sh"
# shellcheck source=../helpers/lineage-utils.sh
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/helpers/lineage-utils.sh"

# ---------------------------------------------------------------------------
# Constants: files to skip (not container lineage files)
# ---------------------------------------------------------------------------
# Pattern matches: *.sbom.json  *.changelog.json  *.history.json  ext-*.json
_is_skippable_file() {
    is_lineage_sidecar "$1"
}

# ---------------------------------------------------------------------------
# Main enrichment loop
# ---------------------------------------------------------------------------
enriched=0
skipped=0
errors=0

if [[ ! -d "$LINEAGE_DIR" ]]; then
    echo "::notice::Lineage directory $LINEAGE_DIR does not exist — 0 enriched"
    exit 0
fi

# Collect all *.json files in the lineage dir (non-recursive; lineage files are flat)
while IFS= read -r lineage_file; do
    basename_file="$(basename "$lineage_file")"

    # Skip non-lineage files
    if _is_skippable_file "$basename_file"; then
        skipped=$((skipped + 1))
        continue
    fi

    # Validate JSON
    if ! container=$(jq -re '.container // empty' "$lineage_file" 2>/dev/null); then
        echo "::warning::Skipping $basename_file: missing or null 'container' field (malformed JSON?)" >&2
        errors=$((errors + 1))
        continue
    fi

    tag=$(jq -r '.tag // empty' "$lineage_file" 2>/dev/null) || tag=""
    if [[ -z "$tag" ]]; then
        echo "::warning::Skipping $basename_file: missing or empty 'tag' field" >&2
        errors=$((errors + 1))
        continue
    fi

    # Idempotency check: if multi_arch_index_digest is already non-null, skip.
    existing_digest=$(jq -r '.multi_arch_index_digest // empty' "$lineage_file" 2>/dev/null) || existing_digest=""
    if [[ -n "$existing_digest" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    image_path="${OWNER}/${container}"

    # --- Collect new fields, tolerating individual failures ---

    # 1. Multi-arch digests (index + per-platform)
    multi_arch_digests='{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
    if raw_digests=$(ghcr_get_multi_arch_digests "$image_path" "$tag" 2>/dev/null) && [[ -n "$raw_digests" ]]; then
        multi_arch_digests="$raw_digests"
    fi

    # 2. Manifest sizes (arch:bytes lines) → parse into fields + platforms list
    size_amd64_bytes="null"
    size_arm64_bytes="null"
    multi_arch_platforms="[]"

    if raw_sizes=$(ghcr_get_manifest_sizes "$image_path" "$tag" 2>/dev/null) && [[ -n "$raw_sizes" ]]; then
        # Build JSON array of arch names (filter "unknown")
        # raw_sizes format: "amd64:12345678\narm64:23456789\n..."
        arch_list=$(printf '%s' "$raw_sizes" | awk -F: '$1 != "unknown" && $1 != "" {print $1}' \
            | jq -R . | jq -s '.' 2>/dev/null) || arch_list="[]"
        [[ -n "$arch_list" ]] && multi_arch_platforms="$arch_list"

        # Extract per-arch sizes in bytes
        raw_amd64=$(printf '%s' "$raw_sizes" | grep -E '^amd64:' | cut -d: -f2 | head -1) || raw_amd64=""
        raw_arm64=$(printf '%s' "$raw_sizes" | grep -E '^arm64:' | cut -d: -f2 | head -1) || raw_arm64=""
        [[ -n "$raw_amd64" && "$raw_amd64" =~ ^[0-9]+$ ]] && size_amd64_bytes="$raw_amd64"
        [[ -n "$raw_arm64" && "$raw_arm64" =~ ^[0-9]+$ ]] && size_arm64_bytes="$raw_arm64"
    fi

    # 3. Attestation (keyed on oci_subject_digest)
    attestation_id_val="null"
    attestation_url_val="null"
    oci_subject_digest=$(jq -r '.oci_subject_digest // empty' "$lineage_file" 2>/dev/null) || oci_subject_digest=""

    if [[ -n "$oci_subject_digest" && "$oci_subject_digest" != "null" && "$oci_subject_digest" != "unknown" ]]; then
        if att_id=$(get_attestation_id "$oci_subject_digest" 2>/dev/null) && [[ -n "$att_id" ]]; then
            attestation_id_val="\"${att_id}\""
            att_url=$(get_attestation_url "$att_id" 2>/dev/null) || att_url=""
            [[ -n "$att_url" ]] && attestation_url_val="\"${att_url}\""
        fi
    fi

    # --- Merge fields into lineage file (atomic write) ---
    # Build the update expression as a single jq call to avoid multiple reads
    tmp_file=$(mktemp "${LINEAGE_DIR}/.enrich-tmp.XXXXXX")
    update_ok=0

    if jq \
        --argjson multi_arch_digests "$multi_arch_digests" \
        --argjson multi_arch_platforms "$multi_arch_platforms" \
        --argjson size_amd64_bytes "$size_amd64_bytes" \
        --argjson size_arm64_bytes "$size_arm64_bytes" \
        --argjson attestation_id "$attestation_id_val" \
        --argjson attestation_url "$attestation_url_val" \
        '. + {
            multi_arch_index_digest:   $multi_arch_digests.index_digest,
            manifest_digest_amd64:     $multi_arch_digests.manifest_digest_amd64,
            manifest_digest_arm64:     $multi_arch_digests.manifest_digest_arm64,
            multi_arch_platforms:      $multi_arch_platforms,
            size_amd64_bytes:          $size_amd64_bytes,
            size_arm64_bytes:          $size_arm64_bytes,
            attestation_id:            $attestation_id,
            attestation_url:           $attestation_url
        }' "$lineage_file" > "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$lineage_file"
        update_ok=1
    else
        rm -f "$tmp_file" 2>/dev/null || true
        echo "::warning::Failed to enrich $basename_file: jq merge failed" >&2
        errors=$((errors + 1))
    fi

    [[ "$update_ok" -eq 1 ]] && enriched=$((enriched + 1))

done < <(find "$LINEAGE_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)

echo "::notice::Enriched $enriched lineage files ($skipped skipped, $errors errors)"
