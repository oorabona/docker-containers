#!/bin/bash
# Rotate versions in variants.yaml for automated version updates
#
# Usage: rotate-versions.sh <container_dir> <new_version>
#
# Algorithm:
#   1. Read build.version_retention (exit 2 if absent/zero — not a managed container)
#   2. Check if new_version already exists (idempotent — exit 0)
#   3. If container has variants: copy variants from first versions[] entry
#   4. If no variants: create simple version entry {tag: "new_version"}
#   5. Prepend new entry to versions[]
#   6. Trim to version_retention entries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/helpers/variant-utils.sh"

usage() {
    echo "Usage: $(basename "$0") <container_dir> <new_version>" >&2
    echo "Exit codes: 0=success, 1=error, 2=not a version_retention container" >&2
    exit 1
}

[[ $# -lt 2 ]] && usage

container_dir="$1"
new_version="$2"
variants_file="$container_dir/variants.yaml"

if [[ ! -f "$variants_file" ]]; then
    echo "Error: $variants_file not found" >&2
    exit 1
fi

# Detect retention strategy — handle latest_per_major before count-based logic
strategy=$(yq -r '.build.retention_strategy // ""' "$variants_file" 2>/dev/null) || strategy=""
if [[ "$strategy" == "latest_per_major" ]]; then
    echo "🔄 latest_per_major strategy detected for $container_dir" >&2

    # Capture rc safely under `set -e`: assignment inside the if-condition
    # is exempt, so a non-zero exit from latest_per_major_versions reaches
    # the explicit ::error:: annotation instead of aborting the script
    # before the message can be printed.
    if ! resolved=$(latest_per_major_versions "$container_dir"); then
        echo "::error::Failed to resolve latest_per_major for $container_dir" >&2
        exit 1
    fi
    if [[ -z "$resolved" ]]; then
        echo "::warning::No versions resolved for $container_dir via latest_per_major" >&2
        exit 0
    fi

    # Rewrite variants.yaml versions[] from resolved list (compact JSON avoids
    # multi-line env-var edge cases when passed through to `yq -i`).
    versions_json=$(printf '%s' "$resolved" | jq -c -R -s 'split("\n") | map(select(length>0)) | map({tag: .})')
    VERSIONS="$versions_json" yq -i '.versions = env(VERSIONS)' "$variants_file"
    echo "✅ Updated $variants_file via latest_per_major: $(printf '%s' "$resolved" | tr '\n' ' ')" >&2
    exit 0
fi

# Step 1: Check version_retention
retention=$(version_retention "$container_dir")
if [[ "$retention" -eq 0 ]]; then
    echo "No version_retention configured for $container_dir — skipping" >&2
    exit 2
fi

# Step 2: Check idempotence — does new_version already exist?
existing_tags=$(yq -r '.versions[].tag' "$variants_file" 2>/dev/null)
while IFS= read -r tag; do
    if [[ "$tag" == "$new_version" ]]; then
        echo "Version $new_version already exists in $variants_file — no changes needed" >&2
        exit 0
    fi
done <<< "$existing_tags"

# Step 3/4: Build the new version entry
first_has_variants=$(yq -r '.versions[0].variants | length // 0' "$variants_file" 2>/dev/null || echo "0")

if [[ -n "$first_has_variants" && "$first_has_variants" -gt 0 ]]; then
    # Container has variants — copy from first entry, update tag
    yq -i "
        .versions |= [{\"tag\": \"$new_version\", \"variants\": .[0].variants}] + .
    " "$variants_file"
else
    # Versions-only — simple entry
    yq -i "
        .versions |= [{\"tag\": \"$new_version\"}] + .
    " "$variants_file"
fi

# Step 6: Trim to retention count
current_count=$(yq -r '.versions | length' "$variants_file")
if [[ "$current_count" -gt "$retention" ]]; then
    yq -i ".versions |= .[:$retention]" "$variants_file"
fi

echo "Rotated $variants_file: added $new_version (retention: $retention)" >&2
