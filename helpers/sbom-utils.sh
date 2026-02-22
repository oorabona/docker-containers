#!/bin/bash
# SBOM (Software Bill of Materials) utilities
# Provides functions for SBOM generation, comparison, and build history tracking.
#
# Dependencies: jq (required), syft (installed on demand)
# SBOM format: SPDX JSON (industry standard, supported by GitHub attestations)

set -euo pipefail

_SBOM_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging if available
if [[ -f "$_SBOM_UTILS_DIR/logging.sh" ]]; then
    source "$_SBOM_UTILS_DIR/logging.sh"
else
    log_info()    { echo "INFO: $*" >&2; }
    log_success() { echo "OK: $*" >&2; }
    log_error()   { echo "ERROR: $*" >&2; }
    log_warning() { echo "WARN: $*" >&2; }
fi

# Install syft if not present
# Downloads the latest release from Anchore's install script
install_syft() {
    if command -v syft &>/dev/null; then
        log_info "syft already installed: $(syft version 2>/dev/null | head -1)"
        return 0
    fi

    log_info "Installing syft..."
    if curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin 2>/dev/null; then
        log_success "syft installed successfully"
    elif curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b "$HOME/.local/bin" 2>/dev/null; then
        export PATH="$HOME/.local/bin:$PATH"
        log_success "syft installed to ~/.local/bin"
    else
        log_error "Failed to install syft"
        return 1
    fi
}

# Generate SBOM from a registry image
# Usage: generate_sbom <image_ref> <output_file>
# image_ref: full image reference (e.g., ghcr.io/owner/repo:tag)
# output_file: path for the SPDX JSON output
generate_sbom() {
    local image_ref="$1"
    local output_file="$2"

    if ! command -v syft &>/dev/null; then
        log_error "syft not found. Run install_syft first."
        return 1
    fi

    local output_dir
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir"

    log_info "Generating SBOM for $image_ref..."
    if syft "registry:${image_ref}" -o "spdx-json=${output_file}" --quiet 2>/dev/null; then
        log_success "SBOM generated: $output_file ($(wc -c < "$output_file") bytes)"
    else
        log_error "Failed to generate SBOM for $image_ref"
        return 1
    fi
}

# Extract sorted package list from SBOM (for diffing)
# Usage: extract_package_list <sbom_file>
# Output: one "type:name=version" per line, sorted
extract_package_list() {
    local sbom_file="$1"

    if [[ ! -f "$sbom_file" ]]; then
        log_error "SBOM file not found: $sbom_file"
        return 1
    fi

    jq -r '
        .packages // [] |
        map(select(.name != null and .versionInfo != null)) |
        map(
            (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref |
            (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "unknown" | if . == "" then "unknown" else . end) else "unknown" end) + ":" +
            .name + "=" + .versionInfo
        ) |
        sort |
        .[]
    ' "$sbom_file" 2>/dev/null
}

# Extract SBOM summary (package counts by type)
# Usage: extract_sbom_summary <sbom_file>
# Output: JSON {"total": N, "apk": N, "pip": N, ...}
extract_sbom_summary() {
    local sbom_file="$1"

    if [[ ! -f "$sbom_file" ]]; then
        echo '{"total": 0}'
        return
    fi

    jq '
        .packages // [] |
        length as $total |
        [.[] |
            (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref |
            (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "other" | if . == "" then "other" else . end) else "other" end)
        ] |
        group_by(.) |
        map({key: .[0], value: length}) |
        from_entries |
        . + {total: $total}
    ' "$sbom_file" 2>/dev/null || echo '{"total": 0}'
}

# Compare two SBOMs and produce changelog JSON
# Usage: compare_sboms <new_sbom> <old_sbom> <output_file>
# Output: JSON with added/removed/updated arrays + summary counts
compare_sboms() {
    local new_sbom="$1"
    local old_sbom="$2"
    local output_file="$3"

    if [[ ! -f "$new_sbom" ]]; then
        log_error "New SBOM not found: $new_sbom"
        return 1
    fi
    if [[ ! -f "$old_sbom" ]]; then
        log_warning "Old SBOM not found: $old_sbom — skipping comparison"
        return 0
    fi

    local output_dir
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir"

    # Extract package lists as JSON arrays: [{type, name, version}, ...]
    local new_pkgs old_pkgs
    new_pkgs=$(jq '[
        .packages // [] |
        .[] |
        select(.name != null and .versionInfo != null) |
        (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref |
        {
            pkg_type: (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "other" | if . == "" then "other" else . end) else "other" end),
            name: .name,
            version: .versionInfo
        }
    ] | sort_by(.name)' "$new_sbom")

    old_pkgs=$(jq '[
        .packages // [] |
        .[] |
        select(.name != null and .versionInfo != null) |
        (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref |
        {
            pkg_type: (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "other" | if . == "" then "other" else . end) else "other" end),
            name: .name,
            version: .versionInfo
        }
    ] | sort_by(.name)' "$old_sbom")

    # Compute diff using jq
    jq -n \
        --argjson new_pkgs "$new_pkgs" \
        --argjson old_pkgs "$old_pkgs" \
        --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '
        # Build lookup maps: name -> {version, pkg_type}
        ($old_pkgs | map({key: .name, value: {version: .version, pkg_type: .pkg_type}}) | from_entries) as $old_map |
        ($new_pkgs | map({key: .name, value: {version: .version, pkg_type: .pkg_type}}) | from_entries) as $new_map |

        # Added: in new but not in old
        [($new_pkgs | .[] | select(.name as $n | $old_map | has($n) | not) |
            {type: "added", name: .name, pkg_type: .pkg_type, version: .version})] as $added |

        # Removed: in old but not in new
        [($old_pkgs | .[] | select(.name as $n | $new_map | has($n) | not) |
            {type: "removed", name: .name, pkg_type: .pkg_type, version: .version})] as $removed |

        # Updated: in both but version differs
        [($new_pkgs | .[] |
            select(.name as $n | $old_map | has($n)) |
            select(.version != ($old_map[.name].version)) |
            {type: "updated", name: .name, pkg_type: .pkg_type,
             from: ($old_map[.name].version), to: .version})] as $updated |

        {
            generated_at: $generated_at,
            summary: {
                added: ($added | length),
                removed: ($removed | length),
                updated: ($updated | length)
            },
            changes: ($added + $removed + $updated | sort_by(.name))
        }
    ' > "$output_file"

    local added removed updated
    added=$(jq '.summary.added' "$output_file")
    removed=$(jq '.summary.removed' "$output_file")
    updated=$(jq '.summary.updated' "$output_file")
    log_info "Changelog: +$added -$removed ~$updated"
}

# Append build metadata to history file (keeps last N entries)
# Usage: append_build_history <lineage_file> <sbom_summary_json> <history_file> [max_entries] [changelog_file]
# lineage_file: build lineage JSON with built_at, version, build_digest
# sbom_summary_json: output of extract_sbom_summary (JSON string)
# history_file: path to the history JSON file (created if missing)
# max_entries: max entries to keep (default: 10)
# changelog_file: path to changelog JSON (default: derived from history_file)
append_build_history() {
    local lineage_file="$1"
    local sbom_summary="$2"
    local history_file="$3"
    local max_entries="${4:-10}"

    local output_dir
    output_dir=$(dirname "$history_file")
    mkdir -p "$output_dir"

    # Extract metadata from lineage file
    local built_at version build_digest
    if [[ -f "$lineage_file" ]]; then
        built_at=$(jq -r '.built_at // empty' "$lineage_file" 2>/dev/null || echo "")
        version=$(jq -r '.version // empty' "$lineage_file" 2>/dev/null || echo "")
        build_digest=$(jq -r '.build_digest // empty' "$lineage_file" 2>/dev/null || echo "")
    fi

    # Fallback for missing fields
    [[ -z "${built_at:-}" ]] && built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    [[ -z "${version:-}" ]] && version="unknown"
    [[ -z "${build_digest:-}" ]] && build_digest="unknown"

    # Extract totals from summary
    local packages_total
    packages_total=$(echo "$sbom_summary" | jq '.total // 0' 2>/dev/null || echo "0")
    local packages_by_type
    packages_by_type=$(echo "$sbom_summary" | jq 'del(.total)' 2>/dev/null || echo "{}")

    # Load existing history or start fresh
    local existing_history="[]"
    if [[ -f "$history_file" ]]; then
        existing_history=$(jq '.' "$history_file" 2>/dev/null || echo "[]")
    fi

    # Build changes_summary from changelog if it exists
    local changes_summary=""
    local changelog_file="${5:-${history_file%.history.json}.changelog.json}"
    if [[ -f "$changelog_file" ]]; then
        local added removed updated
        added=$(jq '.summary.added // 0' "$changelog_file" 2>/dev/null || echo "0")
        removed=$(jq '.summary.removed // 0' "$changelog_file" 2>/dev/null || echo "0")
        updated=$(jq '.summary.updated // 0' "$changelog_file" 2>/dev/null || echo "0")
        changes_summary="+${added} -${removed} ~${updated}"
    fi

    # Create new entry and prepend to history, keeping max_entries
    jq -n \
        --argjson history "$existing_history" \
        --arg built_at "$built_at" \
        --arg version "$version" \
        --arg build_digest "$build_digest" \
        --argjson packages_total "$packages_total" \
        --argjson packages_by_type "$packages_by_type" \
        --arg changes_summary "$changes_summary" \
        --argjson max "$max_entries" \
    '
        [{
            built_at: $built_at,
            version: $version,
            build_digest: $build_digest,
            packages_total: $packages_total,
            packages_by_type: $packages_by_type,
            changes_summary: $changes_summary
        }] + $history |
        .[:$max]
    ' > "$history_file"

    log_info "Build history updated: $history_file ($(jq 'length' "$history_file") entries)"
}
