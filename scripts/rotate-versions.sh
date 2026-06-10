#!/bin/bash
# Rotate versions in variants.yaml for automated version updates
#
# Usage: rotate-versions.sh <container_dir> <new_version> [major_line]
#
# Arguments:
#   container_dir  Directory containing variants.yaml
#   new_version    The new version tag to add / replace
#   major_line     (optional) Numeric major line (e.g. "6").
#                  When set AND retention_strategy==latest_per_major, only
#                  the versions[].tag matching "^<major_line>." is updated.
#                  Also honoured via MAJOR_LINE env var (arg wins over env).
#
# Algorithm:
#   1. Detect retention_strategy.
#      - latest_per_major with major_line: single-line update path (updates
#        only the matching major entry, leaves all other entries untouched).
#      - latest_per_major without major_line: full re-resolution via
#        latest_per_major_versions helper.
#   2. count-based: read build.version_retention (exit 2 if absent/zero).
#      2a. Check if new_version already exists (idempotent — reconcile cache
#          to the retained variants window, then exit 0).
#      2b. If container has variants: copy variants from first versions[] entry.
#      2c. Prepend new entry to versions[].
#      2d. Trim to version_retention entries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/helpers/variant-utils.sh"

usage() {
    echo "Usage: $(basename "$0") <container_dir> <new_version> [major_line]" >&2
    echo "Exit codes: 0=success, 1=error, 2=not a version_retention container" >&2
    exit 1
}

numeric_version_components() {
    local value="$1"
    local remainder="$value"
    local component

    while [[ "$remainder" =~ ([0-9]+([.][0-9]+)*) ]]; do
        component="${BASH_REMATCH[1]}"
        printf '%s\n' "$component"
        remainder="${remainder#*"$component"}"
    done
}

first_numeric_version_component() {
    local value="$1"

    if [[ "$value" =~ ([0-9]+([.][0-9]+)*) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

version_component_in_window() {
    local component="$1"
    local variant_tag
    local variant_component

    for variant_tag in "${version_window_tags[@]}"; do
        if ! variant_component=$(first_numeric_version_component "$variant_tag"); then
            continue
        fi

        if [[ "$component" == "$variant_component" ]]; then
            return 0
        fi
    done

    return 1
}

rotate_base_image_cache_tags() {
    local config_file="$container_dir/config.yaml"
    local entry_count
    local tag_count
    local i
    local rotated=0

    [[ -f "$config_file" ]] || return 0

    entry_count=$(yq -r '.base_image_cache // [] | length' "$config_file" 2>/dev/null || echo "0")
    [[ "$entry_count" =~ ^[0-9]+$ && "$entry_count" -gt 0 ]] || return 0

    for ((i = 0; i < entry_count; i++)); do
        tag_count=$(yq -r ".base_image_cache[$i].tags // [] | length" "$config_file" 2>/dev/null || echo "0")
        [[ "$tag_count" =~ ^[0-9]+$ && "$tag_count" -gt 0 ]] || continue

        local cache_tags=()
        mapfile -t cache_tags < <(yq -r ".base_image_cache[$i].tags[]" "$config_file")

        local cache_tag
        local component
        local tag_prefix
        local tag_suffix
        local tag_shape
        local prefix=""
        local suffix=""
        local component_shape=""
        local pattern_set=0
        local overlaps_window=0
        local version_keyed=1

        for cache_tag in "${cache_tags[@]}"; do
            if ! component=$(first_numeric_version_component "$cache_tag"); then
                version_keyed=0
                break
            fi

            tag_prefix="${cache_tag%%"$component"*}"
            tag_suffix="${cache_tag#*"$component"}"
            tag_shape="${component//[0-9]/}"

            if [[ "$pattern_set" -eq 0 ]]; then
                prefix="$tag_prefix"
                suffix="$tag_suffix"
                component_shape="$tag_shape"
                pattern_set=1
            elif [[ "$tag_prefix" != "$prefix" || "$tag_suffix" != "$suffix" || "$tag_shape" != "$component_shape" ]]; then
                version_keyed=0
                break
            fi

            if version_component_in_window "$component"; then
                overlaps_window=1
            fi
        done

        [[ "$overlaps_window" -eq 1 ]] || continue
        [[ "$version_keyed" -eq 1 ]] || continue

        local rotated_tags=()
        local new_tag
        local new_component
        local new_component_shape

        for new_tag in "${new_version_tags[@]}"; do
            if ! new_component=$(first_numeric_version_component "$new_tag"); then
                version_keyed=0
                break
            fi

            new_component_shape="${new_component//[0-9]/}"
            if [[ "$new_component_shape" != "$component_shape" ]]; then
                version_keyed=0
                break
            fi

            rotated_tags+=("${prefix}${new_component}${suffix}")
        done

        [[ "$version_keyed" -eq 1 ]] || continue

        local tags_json
        tags_json=$(printf '%s\n' "${rotated_tags[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
        TAGS="$tags_json" yq -i ".base_image_cache[$i].tags = env(TAGS) | .base_image_cache[$i].tags style=\"flow\"" "$config_file"
        rotated=1
    done

    if [[ "$rotated" -eq 1 ]]; then
        echo "Updated $config_file base_image_cache tags to mirror retained versions" >&2
    fi
}

[[ $# -lt 2 ]] && usage

container_dir="$1"
new_version="$2"
# Accept major_line as positional arg $3 or from MAJOR_LINE env var.
# Positional arg wins when both are provided.
major_line="${3:-${MAJOR_LINE:-}}"
variants_file="$container_dir/variants.yaml"

if [[ ! -f "$variants_file" ]]; then
    echo "Error: $variants_file not found" >&2
    exit 1
fi

# Detect retention strategy — handle latest_per_major before count-based logic
strategy=$(yq -r '.build.retention_strategy // ""' "$variants_file" 2>/dev/null) || strategy=""
if [[ "$strategy" == "latest_per_major" ]]; then
    echo "🔄 latest_per_major strategy detected for $container_dir" >&2

    # ── Single-line update path ──────────────────────────────────────────────
    # When major_line is provided (from upstream-monitor's per-major PR flow),
    # update ONLY the versions[].tag entry whose tag starts with "<major_line>.".
    # All other entries are left untouched.  This prevents a 6.x PR from
    # accidentally overwriting the 7.x entry (or vice-versa).
    if [[ -n "$major_line" ]]; then
        # Validate: major_line must be a non-empty integer
        if [[ ! "$major_line" =~ ^[0-9]+$ ]]; then
            echo "::error::invalid major_line value: '$major_line' (must be a non-negative integer)" >&2
            exit 1
        fi

        # Check that a matching entry actually exists in versions[]
        existing_count=$(ML="$major_line" yq -r \
            '[.versions[] | select(.tag | test("^" + strenv(ML) + "\\."))] | length' \
            "$variants_file" 2>/dev/null || echo "0")
        if [[ "$existing_count" -eq 0 ]]; then
            echo "::warning::rotate-versions.sh: no versions[] entry matching ${major_line}.x found in $variants_file — skipping" >&2
            exit 0
        fi

        # Replace only the matching entry's tag value.
        ML="$major_line" NV="$new_version" yq -i \
            '(.versions[] | select(.tag | test("^" + strenv(ML) + "\\.")) | .tag) = strenv(NV)' \
            "$variants_file"
        echo "✅ Updated $variants_file: ${major_line}.x line → $new_version" >&2
        exit 0
    fi

    # ── Full re-resolution path ──────────────────────────────────────────────
    # No major_line provided: resolve ALL retained majors via version.sh and
    # rewrite the entire versions[] list.  Used for periodic rotation passes.

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

mapfile -t old_version_tags < <(yq -r '.versions[].tag' "$variants_file" 2>/dev/null)

# Step 2: Check idempotence — does new_version already exist?
for tag in "${old_version_tags[@]}"; do
    if [[ "$tag" == "$new_version" ]]; then
        new_version_tags=("${old_version_tags[@]}")
        version_window_tags=("${old_version_tags[@]}" "${new_version_tags[@]}")
        rotate_base_image_cache_tags
        echo "Version $new_version already exists in $variants_file — reconciled base_image_cache tags" >&2
        exit 0
    fi
done

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

mapfile -t new_version_tags < <(yq -r '.versions[].tag' "$variants_file" 2>/dev/null)
version_window_tags=("${old_version_tags[@]}" "${new_version_tags[@]}")
rotate_base_image_cache_tags

echo "Rotated $variants_file: added $new_version (retention: $retention)" >&2
