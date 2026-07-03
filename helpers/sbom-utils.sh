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

source "$_SBOM_UTILS_DIR/retry.sh"

# Install syft if not present
# Downloads the latest release from Anchore's install script
install_syft() {
    if command -v syft &>/dev/null; then
        log_info "syft already installed: $(syft version 2>/dev/null | head -1)"
        return 0
    fi

    local syft_version="v1.42.1"
    log_info "Installing syft ${syft_version}..."
    if curl -sSfL "https://raw.githubusercontent.com/anchore/syft/${syft_version}/install.sh" | sh -s -- -b /usr/local/bin 2>/dev/null; then
        log_success "syft ${syft_version} installed successfully"
    elif curl -sSfL "https://raw.githubusercontent.com/anchore/syft/${syft_version}/install.sh" | sh -s -- -b "$HOME/.local/bin" 2>/dev/null; then
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
    local syft_args=("registry:${image_ref}" -o "spdx-json=${output_file}" --quiet)
    local syft_cmd=(syft)
    if syft --timeout 10m --help &>/dev/null; then
        syft_args=(--timeout 10m "${syft_args[@]}")
    elif command -v timeout &>/dev/null; then
        syft_cmd=(timeout 10m syft)
    fi

    if retry_with_backoff 2 30 "${syft_cmd[@]}" "${syft_args[@]}"; then
        log_success "SBOM generated: $output_file ($(wc -c < "$output_file") bytes)"
    else
        log_error "Failed to generate SBOM for $image_ref"
        return 1
    fi
}

# Extract sorted package list from SBOM (for diffing)
# Usage: extract_package_list <sbom_file>
# Output: one "type:name=version" per line, sorted

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

# Extract packages grouped by type (for dashboard drill-down)
# Usage: extract_sbom_packages <sbom_file>
# Output: JSON {"apk": [{"n":"busybox","v":"1.37.0"},...], "golang": [...], ...}

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

_enrich_changelog_latest_results() {
    local queries_json="$1"
    local helper="${_DEPENDENCY_FRESHNESS_HELPER:-${_SBOM_UTILS_DIR}/dependency-freshness.sh}"
    local concurrency="${DEPENDENCY_FRESHNESS_CONCURRENCY:-4}"
    local max_concurrency=16
    local non_apk_encoded apk_encoded non_apk_results apk_results

    [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || concurrency=4
    if (( concurrency > max_concurrency )); then
        concurrency="$max_concurrency"
    fi
    non_apk_results="[]"
    apk_results="[]"

    non_apk_encoded=$(jq -r '.[] | select(.pkg_type != "apk") | @base64' <<< "$queries_json")
    if [[ -n "$non_apk_encoded" ]]; then
        if (( concurrency > 1 )); then
            non_apk_results=$(
                printf '%s\n' "$non_apk_encoded" \
                    | xargs -r -n1 -P "$concurrency" bash "$helper" __latest_worker \
                    | jq -s '.'
            )
        else
            non_apk_results=$(
                while IFS= read -r encoded; do
                    [[ -n "$encoded" ]] || continue
                    bash "$helper" __latest_worker "$encoded"
                done <<< "$non_apk_encoded" | jq -s '.'
            )
        fi
    fi

    # apk must run in the current shell so all package lookups share the same
    # APKINDEX map; worker-per-package would accidentally download per package.
    apk_encoded=$(jq -r '.[] | select(.pkg_type == "apk") | @base64' <<< "$queries_json")
    if [[ -n "$apk_encoded" ]]; then
        apk_results=$(
            while IFS= read -r encoded; do
                [[ -n "$encoded" ]] || continue
                _freshness_latest_worker "$encoded"
            done <<< "$apk_encoded" | jq -s '.'
        )
    fi

    jq -cn --argjson non_apk "$non_apk_results" --argjson apk "$apk_results" '$non_apk + $apk'
}

_enrich_changelog_add_enrichment() {
    local enrichments_json="$1"
    local pkg_type="$2"
    local name="$3"
    local installed="$4"
    local latest="$5"
    local freshness="$6"
    local capped_by="$7"
    local latest_is_null=false
    local capped_is_null=false

    [[ -z "$latest" || "$latest" == "null" ]] && latest_is_null=true
    [[ -z "$capped_by" || "$capped_by" == "null" ]] && capped_is_null=true

    jq -cn \
        --argjson enrichments "$enrichments_json" \
        --arg pkg_type "$pkg_type" \
        --arg name "$name" \
        --arg installed "$installed" \
        --arg latest "$latest" \
        --arg freshness "$freshness" \
        --arg capped_by "$capped_by" \
        --argjson latest_is_null "$latest_is_null" \
        --argjson capped_is_null "$capped_is_null" \
        '$enrichments + [{
            pkg_type: $pkg_type,
            name: $name,
            installed: $installed,
            latest: (if $latest_is_null then null else $latest end),
            freshness: $freshness,
            capped_by: (if $capped_is_null then null else $capped_by end)
        }]'
}

_enrich_changelog_constraint_source() {
    local current_sbom_file="$1"
    local fallback_json="$2"
    local pkg_type="$3"

    if [[ -n "$current_sbom_file" && -f "$current_sbom_file" ]] \
        && jq -e '(.packages // empty | type) == "array"' "$current_sbom_file" >/dev/null 2>&1; then
        if jq -c --arg pkg_type "$pkg_type" '
            [
                .packages // []
                | .[]
                | select(.name != null and .versionInfo != null)
                | (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref
                | {
                    pkg_type: (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "other" | if . == "" then "other" else . end) else "other" end),
                    name: .name,
                    installed: .versionInfo
                  }
                | select(.pkg_type == $pkg_type)
            ]
            | unique_by([.pkg_type, .name, .installed])
        ' "$current_sbom_file"; then
            return 0
        fi
    fi

    jq -c --arg pkg_type "$pkg_type" '
        [.[] | select(.pkg_type == $pkg_type)]
        | unique_by([.pkg_type, .name, .installed])
    ' <<< "$fallback_json"
}

_enrich_changelog_constraints_for_ecosystem() {
    local pkg_type="$1"
    local source_json="$2"
    local constraints

    if ! constraints=$(_freshness_constraints_for_batch "$pkg_type" "$source_json"); then
        log_warning "Dependency freshness ${pkg_type} constraint batch failed; capping checks may be incomplete"
        jq -cn '[]'
        return 0
    fi
    if ! jq -e 'type == "array"' <<< "$constraints" >/dev/null 2>&1; then
        log_warning "Dependency freshness ${pkg_type} constraint batch returned malformed JSON; capping checks may be incomplete"
        jq -cn '[]'
        return 0
    fi

    printf '%s\n' "$constraints"
}

# Enrich compare_sboms output with latest-version and freshness metadata.
# Usage: enrich_changelog <changelog_file> [current_sbom_file]
enrich_changelog() {
    local changelog_file="$1"
    local current_sbom_file="${2:-}"

    if [[ ! -f "$changelog_file" ]]; then
        log_warning "Changelog not found for freshness enrichment: $changelog_file"
        return 0
    fi
    if ! jq -e '(.changes // empty | type) == "array"' "$changelog_file" >/dev/null 2>&1; then
        log_warning "Changelog has no changes[] array; skipping freshness enrichment: $changelog_file"
        return 0
    fi

    if ! declare -F _freshness_resolver_for >/dev/null 2>&1; then
        if [[ -f "${_SBOM_UTILS_DIR}/dependency-freshness.sh" ]]; then
            # shellcheck source=helpers/dependency-freshness.sh
            source "${_SBOM_UTILS_DIR}/dependency-freshness.sh"
        else
            log_warning "dependency-freshness helper unavailable; skipping enrichment"
            return 0
        fi
    fi

    local lineage_file
    lineage_file="${changelog_file%.changelog.json}.json"
    if [[ -f "$lineage_file" ]]; then
        if [[ -z "${DEPENDENCY_FRESHNESS_IMAGE_REF:-}" ]]; then
            DEPENDENCY_FRESHNESS_IMAGE_REF=$(jq -r '.images.ghcr // .images.dockerhub // empty' "$lineage_file" 2>/dev/null || true)
            export DEPENDENCY_FRESHNESS_IMAGE_REF
        fi
        if [[ -z "${DEPENDENCY_FRESHNESS_PLATFORM:-}" ]]; then
            DEPENDENCY_FRESHNESS_PLATFORM=$(jq -r '.platform // empty' "$lineage_file" 2>/dev/null || true)
            export DEPENDENCY_FRESHNESS_PLATFORM
        fi
    fi

    local eligible_json eligible_count queries_json latest_results
    eligible_json=$(jq -c '
        [
            .changes[]?
            | select(.type == "updated" or .type == "added")
            | select(.pkg_type != null and .name != null)
            | {pkg_type, name, installed: (.to // .version // null)}
            | select(.installed != null)
        ]
    ' "$changelog_file")
    eligible_count=$(jq 'length' <<< "$eligible_json")
    if [[ "$eligible_count" -eq 0 ]]; then
        return 0
    fi

    queries_json=$(jq -c 'unique_by([.pkg_type, .name])' <<< "$eligible_json")
    if ! latest_results=$(_enrich_changelog_latest_results "$queries_json"); then
        log_warning "Dependency freshness latest-version batch failed; marking affected checks as query-failed"
        latest_results="[]"
    elif ! jq -e 'type == "array"' <<< "$latest_results" >/dev/null 2>&1; then
        log_warning "Dependency freshness latest-version batch returned malformed JSON; marking affected checks as query-failed"
        latest_results="[]"
    fi

    local npm_constraints gem_constraints npm_changed_count gem_changed_count constraint_source_json
    npm_constraints="[]"
    gem_constraints="[]"
    npm_changed_count=$(jq '[.[] | select(.pkg_type == "npm")] | length' <<< "$eligible_json")
    gem_changed_count=$(jq '[.[] | select(.pkg_type == "gem")] | length' <<< "$eligible_json")
    if (( npm_changed_count > 0 )); then
        constraint_source_json=$(_enrich_changelog_constraint_source "$current_sbom_file" "$eligible_json" npm)
        npm_constraints=$(_enrich_changelog_constraints_for_ecosystem npm "$constraint_source_json")
    fi
    if (( gem_changed_count > 0 )); then
        constraint_source_json=$(_enrich_changelog_constraint_source "$current_sbom_file" "$eligible_json" gem)
        gem_constraints=$(_enrich_changelog_constraints_for_ecosystem gem "$constraint_source_json")
    fi

    local enrichments row pkg_type name installed resolver latest_record latest query_failed freshness capped_by constraints
    enrichments="[]"
    while IFS= read -r row; do
        pkg_type=$(jq -r '.pkg_type' <<< "$row")
        name=$(jq -r '.name' <<< "$row")
        installed=$(jq -r '.installed' <<< "$row")
        resolver=$(_freshness_resolver_for "$pkg_type")

        latest_record=$(jq -c --arg pkg_type "$pkg_type" --arg name "$name" '
            map(select(.pkg_type == $pkg_type and .name == $name)) | first // {latest:null, query_failed:true}
        ' <<< "$latest_results")
        latest=$(jq -r '.latest // "null"' <<< "$latest_record")
        query_failed=$(jq -r 'if has("query_failed") then .query_failed else true end' <<< "$latest_record")
        freshness="not-computed"
        capped_by="null"

        if [[ -z "$resolver" ]]; then
            freshness="not-computed"
        elif [[ "$query_failed" == "true" ]]; then
            freshness="query-failed"
        elif [[ "$latest" != "null" && "$installed" == "$latest" ]]; then
            freshness="up-to-date"
        elif [[ "$pkg_type" == "npm" || "$pkg_type" == "gem" ]]; then
            constraints="$npm_constraints"
            [[ "$pkg_type" == "gem" ]] && constraints="$gem_constraints"
            if capped_by=$(_freshness_find_capping_constraint "$pkg_type" "$name" "$installed" "$latest" "$constraints" 2>/dev/null); then
                freshness="capped"
            else
                freshness="constraint-not-detected"
                capped_by="null"
            fi
        else
            freshness="not-computed"
        fi

        enrichments=$(_enrich_changelog_add_enrichment \
            "$enrichments" "$pkg_type" "$name" "$installed" "$latest" "$freshness" "$capped_by")
    done < <(jq -c '.[]' <<< "$eligible_json")

    local tmp_file
    tmp_file=$(mktemp)
    if jq --argjson enrichments "$enrichments" '
        def installed_version: .to // .version;
        ($enrichments
            | map({
                key: ([.pkg_type, .name, .installed] | @json),
                value: {latest, freshness, capped_by}
              })
            | from_entries) as $enrichment_map
        | .changes = ((.changes // []) | map(
            if (.type == "updated" or .type == "added") then
                ([.pkg_type, .name, installed_version] | @json) as $key
                | if $enrichment_map[$key] then . + $enrichment_map[$key] else . end
            else
                .
            end
          ))
    ' "$changelog_file" > "$tmp_file"; then
        if mv "$tmp_file" "$changelog_file"; then
            log_info "Dependency freshness enriched: $changelog_file"
            return 0
        fi
        rm -f "$tmp_file"
        log_warning "Dependency freshness enrichment failed while writing changelog: $changelog_file"
        return 1
    else
        rm -f "$tmp_file"
        log_warning "Dependency freshness enrichment failed; leaving changelog unchanged: $changelog_file"
        return 1
    fi
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
    local built_at version build_digest duration_seconds extensions_build_seconds extensions_present
    extensions_present="false"
    if [[ -f "$lineage_file" ]]; then
        built_at=$(jq -r '.built_at // empty' "$lineage_file" 2>/dev/null || echo "")
        version=$(jq -r '.version // empty' "$lineage_file" 2>/dev/null || echo "")
        build_digest=$(jq -r '.build_digest // empty' "$lineage_file" 2>/dev/null || echo "")
        duration_seconds=$(jq '.duration_seconds // null' "$lineage_file" 2>/dev/null || echo "null")
        # Only emit extensions_build_seconds when the source lineage actually
        # carries it. Containers without `extensions/config.yaml` (terraform,
        # ansible, …) don't write the field, and we must not synthesise a
        # null entry — the dashboard frontend keys "container has extensions
        # concept" off field presence (Object.hasOwnProperty), not value.
        extensions_present=$(jq 'has("extensions_build_seconds")' "$lineage_file" 2>/dev/null || echo "false")
        extensions_build_seconds=$(jq '.extensions_build_seconds // null' "$lineage_file" 2>/dev/null || echo "null")
    fi

    # Fallback for missing fields
    [[ -z "${built_at:-}" ]] && built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    [[ -z "${version:-}" ]] && version="unknown"
    [[ -z "${build_digest:-}" ]] && build_digest="unknown"
    [[ -z "${duration_seconds:-}" ]] && duration_seconds="null"
    [[ -z "${extensions_build_seconds:-}" ]] && extensions_build_seconds="null"

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

    # Create new entry and prepend to history, keeping max_entries.
    # extensions_build_seconds is conditionally added only when the source
    # lineage carried it — preserves the "container has no extensions concept"
    # signal for non-postgres containers.
    jq -n \
        --argjson history "$existing_history" \
        --arg built_at "$built_at" \
        --arg version "$version" \
        --arg build_digest "$build_digest" \
        --argjson packages_total "$packages_total" \
        --argjson packages_by_type "$packages_by_type" \
        --arg changes_summary "$changes_summary" \
        --argjson duration "$duration_seconds" \
        --argjson ext_present "$extensions_present" \
        --argjson ext_duration "$extensions_build_seconds" \
        --argjson max "$max_entries" \
    '
        [({
            built_at: $built_at,
            version: $version,
            build_digest: $build_digest,
            packages_total: $packages_total,
            packages_by_type: $packages_by_type,
            changes_summary: $changes_summary,
            duration_seconds: $duration
        } + (if $ext_present then {extensions_build_seconds: $ext_duration} else {} end))] + $history |
        .[:$max]
    ' > "$history_file"

    log_info "Build history updated: $history_file ($(jq 'length' "$history_file") entries)"
}
