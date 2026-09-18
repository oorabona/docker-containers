#!/usr/bin/env bash
# SBOM (Software Bill of Materials) utilities
# Provides functions for SBOM generation, comparison, and build history tracking.
#
# Dependencies: jq (required); install_syft requires curl, uname, mktemp, tar, install, mv, mkdir, rm, head, and sha256sum or shasum; syft (installed on demand)
# SBOM format: SPDX JSON (industry standard, supported by GitHub attestations)

_SBOM_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging if available
if [[ -f "$_SBOM_UTILS_DIR/logging.sh" ]]; then
    # shellcheck source=helpers/logging.sh
    # shellcheck disable=SC1091
    if ! source "$_SBOM_UTILS_DIR/logging.sh"; then
        echo "ERROR: Failed to load logging utilities" >&2
        return 1
    fi
else
    log_info()    { echo "INFO: $*" >&2; }
    log_success() { echo "OK: $*" >&2; }
    log_error()   { echo "ERROR: $*" >&2; }
    log_warning() { echo "WARN: $*" >&2; }
fi

# shellcheck source=helpers/retry.sh
# shellcheck disable=SC1091
if ! source "$_SBOM_UTILS_DIR/retry.sh"; then
    log_error "Failed to load retry utilities"
    return 1
fi

# Install syft if not present
install_syft() {
    if command -v syft &>/dev/null; then
        log_info "syft already installed: $(syft version 2>/dev/null | head -1)"
        return 0
    fi

    # Keep the version and release-asset digests together so updating this
    # local convenience installer remains auditable.
    local syft_version="1.51.0"
    local syft_linux_amd64_sha256="2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f"
    local syft_linux_arm64_sha256="6c0466811541ea03add5213a60a1562f0851e4c0b0ecfdee1a694a9455285900"
    local syft_darwin_amd64_sha256="cddf9a044145caf0a1a3194d00d1dd51a1666f4814f2919cdb4768a0c062ad95"
    local syft_darwin_arm64_sha256="4f37f4c7fefce0a68e4cf71ba3f5f9829a99e65d89b29f7ee41b8c2c10ea8c59"
    local syft_asset syft_sha256
    # This helper deliberately supports only the verified Linux and Darwin
    # amd64/arm64 assets below; it is not a complete list of syft releases.
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64|Linux-amd64)
            syft_asset="syft_${syft_version}_linux_amd64.tar.gz"
            syft_sha256="$syft_linux_amd64_sha256"
            ;;
        Linux-aarch64|Linux-arm64)
            syft_asset="syft_${syft_version}_linux_arm64.tar.gz"
            syft_sha256="$syft_linux_arm64_sha256"
            ;;
        Darwin-x86_64|Darwin-amd64)
            syft_asset="syft_${syft_version}_darwin_amd64.tar.gz"
            syft_sha256="$syft_darwin_amd64_sha256"
            ;;
        Darwin-arm64)
            syft_asset="syft_${syft_version}_darwin_arm64.tar.gz"
            syft_sha256="$syft_darwin_arm64_sha256"
            ;;
        *)
            log_error "No verified syft ${syft_version} release asset for $(uname -s)/$(uname -m)"
            return 1
            ;;
    esac

    local syft_tmp syft_archive syft_binary syft_destination syft_stage installed_version syft_version_output line syft_actual_sha256
    local -a syft_checksum_command
    syft_tmp=$(mktemp -d) || {
        log_error "Failed to create temporary directory for syft download"
        return 1
    }
    syft_archive="$syft_tmp/$syft_asset"
    syft_binary="$syft_tmp/syft"

    log_info "Installing syft ${syft_version}..."
    if ! curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/anchore/syft/releases/download/v${syft_version}/${syft_asset}" \
        -o "$syft_archive"; then
        rm -rf "$syft_tmp"
        log_error "Failed to download syft ${syft_version}"
        return 1
    fi
    if command -v sha256sum &>/dev/null; then
        syft_checksum_command=(sha256sum)
    elif command -v shasum &>/dev/null; then
        syft_checksum_command=(shasum -a 256)
    else
        rm -rf "$syft_tmp"
        log_error "No SHA-256 checker available to verify syft ${syft_version}"
        return 1
    fi
    if ! syft_actual_sha256=$("${syft_checksum_command[@]}" "$syft_archive"); then
        rm -rf "$syft_tmp"
        log_error "Downloaded syft ${syft_version} failed SHA-256 verification"
        return 1
    fi
    syft_actual_sha256="${syft_actual_sha256#\\}"
    if [[ "${syft_actual_sha256%% *}" != "$syft_sha256" ]]; then
        rm -rf "$syft_tmp"
        log_error "Downloaded syft ${syft_version} failed SHA-256 verification"
        return 1
    fi
    if ! tar -xzf "$syft_archive" -C "$syft_tmp" syft || [[ ! -f "$syft_binary" ]]; then
        rm -rf "$syft_tmp"
        log_error "Failed to extract verified syft ${syft_version} archive"
        return 1
    fi

    syft_destination="/usr/local/bin/syft"
    if syft_stage=$(mktemp "${syft_destination}.tmp.XXXXXX") && install -m 0755 "$syft_binary" "$syft_stage"; then
        :
    else
        [[ -n "$syft_stage" ]] && rm -f "$syft_stage"
        local user_bin="$HOME/.local/bin"
        syft_destination="$user_bin/syft"
        if ! mkdir -p "$user_bin" || ! syft_stage=$(mktemp "${syft_destination}.tmp.XXXXXX") || ! install -m 0755 "$syft_binary" "$syft_stage"; then
            [[ -n "$syft_stage" ]] && rm -f "$syft_stage"
            rm -rf "$syft_tmp"
            log_error "Failed to stage verified syft ${syft_version}"
            return 1
        fi
        export PATH="$user_bin:$PATH"
    fi
    rm -rf "$syft_tmp"

    if ! syft_version_output=$("$syft_stage" version 2>/dev/null); then
        rm -f "$syft_stage"
        log_error "Installed syft did not report its version"
        return 1
    fi
    installed_version=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^Version:[[:space:]]*(.+)$ ]]; then
            installed_version="${BASH_REMATCH[1]}"
            break
        fi
    done <<< "$syft_version_output"
    if [[ -z "$installed_version" ]]; then
        rm -f "$syft_stage"
        log_error "Installed syft did not report its version"
        return 1
    fi
    if [[ "${installed_version#v}" != "$syft_version" ]]; then
        rm -f "$syft_stage"
        log_error "Installed syft reported version ${installed_version}, expected ${syft_version}"
        return 1
    fi
    installed_version="${installed_version#v}"

    if ! mv -f "$syft_stage" "$syft_destination"; then
        rm -f "$syft_stage"
        log_error "Failed to install verified syft ${syft_version}"
        return 1
    fi

    log_success "syft ${installed_version} installed successfully" || :
    return 0
}

# Generate SBOM from a registry image
# Usage: generate_sbom <image_ref> <output_file>
# image_ref: full image reference (e.g., ghcr.io/owner/repo:tag)
# output_file: path for the SPDX JSON output
# The public SBOM operations use subshells only to isolate their shell options
# from scripts that source this helper. Their failure contract is explicit:
# every required operation is checked and failure is returned to the caller.
generate_sbom() (
    set -uo pipefail
    if [[ "$#" -ne 2 || -z "$1" || -z "$2" ]]; then
        log_error "generate_sbom requires an image reference and output path"
        return 2
    fi
    local image_ref="$1"
    local output_file="$2"

    if ! command -v syft &>/dev/null; then
        log_error "syft not found. Run install_syft first."
        return 1
    fi

    if [[ -d "$output_file" ]]; then
        log_error "SBOM output path is a directory: $output_file"
        return 1
    fi

    local output_dir tmp_file output_size
    if ! output_dir=$(dirname -- "$output_file"); then
        log_error "Failed to determine SBOM output directory: $output_file"
        return 1
    fi
    if ! mkdir -p -- "$output_dir"; then
        log_error "Failed to create SBOM output directory: $output_dir"
        return 1
    fi
    if ! tmp_file=$(mktemp "${output_file}.tmp.XXXXXX"); then
        log_error "Failed to create temporary SBOM output: $output_file"
        return 1
    fi

    log_info "Generating SBOM for $image_ref..."
    local syft_args=("registry:${image_ref}" -o "spdx-json=${tmp_file}" --quiet)
    local syft_cmd=(syft)
    if syft --timeout 10m --help &>/dev/null; then
        syft_args=(--timeout 10m "${syft_args[@]}")
    elif command -v timeout &>/dev/null; then
        syft_cmd=(timeout 10m syft)
    fi

    if ! retry_with_backoff 2 30 "${syft_cmd[@]}" "${syft_args[@]}"; then
        rm -f -- "$tmp_file"
        log_error "Failed to generate SBOM for $image_ref"
        return 1
    fi
    if [[ ! -f "$tmp_file" || ! -r "$tmp_file" ]]; then
        rm -f -- "$tmp_file"
        log_error "SBOM producer did not create a readable output: $output_file"
        return 1
    fi
    if ! jq -e 'type == "object"' "$tmp_file" >/dev/null 2>&1; then
        rm -f -- "$tmp_file"
        log_error "SBOM producer did not create valid JSON: $output_file"
        return 1
    fi
    if ! output_size=$(wc -c < "$tmp_file"); then
        rm -f -- "$tmp_file"
        log_error "Failed to measure generated SBOM: $output_file"
        return 1
    fi
    output_size="${output_size//[[:space:]]/}"
    if [[ ! "$output_size" =~ ^[0-9]+$ ]]; then
        rm -f -- "$tmp_file"
        log_error "Generated SBOM has an invalid size: $output_file"
        return 1
    fi
    if ! mv -f -- "$tmp_file" "$output_file"; then
        rm -f -- "$tmp_file"
        log_error "Failed to publish generated SBOM: $output_file"
        return 1
    fi
    log_success "SBOM generated: $output_file (${output_size} bytes)"
    return 0
)

# Extract sorted package list from SBOM (for diffing)
# Usage: extract_package_list <sbom_file>
# Output: one "type:name=version" per line, sorted

# Extract SBOM summary (package counts by type)
# Usage: extract_sbom_summary <sbom_file>
# Output: JSON {"total": N, "apk": N, "pip": N, ...}
extract_sbom_summary() (
    set -uo pipefail
    if [[ "$#" -ne 1 || -z "$1" ]]; then
        log_error "extract_sbom_summary requires an SBOM path"
        return 2
    fi
    local sbom_file="$1"

    if [[ ! -f "$sbom_file" ]]; then
        if ! printf '%s\n' '{"total": 0}'; then
            return 1
        fi
        return 0
    fi

    if ! jq '
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
    ' "$sbom_file" 2>/dev/null; then
        log_error "Failed to extract SBOM summary: $sbom_file"
        return 1
    fi
    return 0
)

# Extract packages grouped by type (for dashboard drill-down)
# Usage: extract_sbom_packages <sbom_file>
# Output: JSON {"apk": [{"n":"busybox","v":"1.37.0"},...], "golang": [...], ...}

# Compare two SBOMs and produce changelog JSON
# Usage: compare_sboms <new_sbom> <old_sbom> <output_file>
# Output: JSON with added/removed/updated arrays + summary counts
compare_sboms() (
    set -uo pipefail
    if [[ "$#" -ne 3 || -z "$1" || -z "$2" || -z "$3" ]]; then
        log_error "compare_sboms requires new SBOM, old SBOM, and output paths"
        return 2
    fi
    local new_sbom="$1"
    local old_sbom="$2"
    local output_file="$3"

    if [[ ! -f "$new_sbom" || ! -r "$new_sbom" ]]; then
        log_error "New SBOM is not readable: $new_sbom"
        return 1
    fi
    if [[ ! -f "$old_sbom" ]]; then
        log_warning "Old SBOM not found: $old_sbom — skipping comparison"
        return 0
    fi

    if [[ -d "$output_file" ]]; then
        log_error "Changelog output path is a directory: $output_file"
        return 1
    fi

    local output_dir tmp_file generated_at
    if ! output_dir=$(dirname -- "$output_file"); then
        log_error "Failed to determine changelog output directory: $output_file"
        return 1
    fi
    if ! mkdir -p -- "$output_dir"; then
        log_error "Failed to create changelog output directory: $output_dir"
        return 1
    fi
    if ! tmp_file=$(mktemp "${output_file}.tmp.XXXXXX"); then
        log_error "Failed to create temporary changelog output: $output_file"
        return 1
    fi

    # Extract package lists as JSON arrays: [{type, name, version}, ...]
    local new_pkgs old_pkgs
    if ! new_pkgs=$(jq '[
        .packages // [] |
        .[] |
        select(.name != null and .versionInfo != null) |
        (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref |
        {
            pkg_type: (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "other" | if . == "" then "other" else . end) else "other" end),
            name: .name,
            version: .versionInfo
        }
    ] | sort_by(.name)' "$new_sbom"); then
        rm -f -- "$tmp_file"
        log_error "Failed to read new SBOM: $new_sbom"
        return 1
    fi

    if ! old_pkgs=$(jq '[
        .packages // [] |
        .[] |
        select(.name != null and .versionInfo != null) |
        (.externalRefs // [] | map(select(.referenceCategory == "PACKAGE-MANAGER")) | first // null) as $ref |
        {
            pkg_type: (if $ref then ($ref.referenceLocator // "" | ltrimstr("pkg:") | split("/")[0] // "other" | if . == "" then "other" else . end) else "other" end),
            name: .name,
            version: .versionInfo
        }
    ] | sort_by(.name)' "$old_sbom"); then
        rm -f -- "$tmp_file"
        log_error "Failed to read old SBOM: $old_sbom"
        return 1
    fi

    if ! generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ"); then
        rm -f -- "$tmp_file"
        log_error "Failed to determine changelog generation time"
        return 1
    fi

    # Compute diff using jq
    if ! jq -n \
        --argjson new_pkgs "$new_pkgs" \
        --argjson old_pkgs "$old_pkgs" \
        --arg generated_at "$generated_at" \
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
    ' > "$tmp_file"; then
        rm -f -- "$tmp_file"
        log_error "Failed to generate changelog: $output_file"
        return 1
    fi
    if [[ ! -f "$tmp_file" || ! -r "$tmp_file" ]] \
        || ! jq -e 'type == "object"' "$tmp_file" >/dev/null 2>&1; then
        rm -f -- "$tmp_file"
        log_error "Generated changelog is not readable valid JSON: $output_file"
        return 1
    fi

    local added removed updated
    if ! added=$(jq -er '.summary.added | select(type == "number")' "$tmp_file") \
        || ! removed=$(jq -er '.summary.removed | select(type == "number")' "$tmp_file") \
        || ! updated=$(jq -er '.summary.updated | select(type == "number")' "$tmp_file"); then
        rm -f -- "$tmp_file"
        log_error "Generated changelog has invalid summary counts: $output_file"
        return 1
    fi
    if ! mv -f -- "$tmp_file" "$output_file"; then
        rm -f -- "$tmp_file"
        log_error "Failed to publish generated changelog: $output_file"
        return 1
    fi
    log_info "Changelog: +$added -$removed ~$updated"
    return 0
)

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
    local latest_is_null=false

    [[ -z "$latest" || "$latest" == "null" ]] && latest_is_null=true

    jq -cn \
        --argjson enrichments "$enrichments_json" \
        --arg pkg_type "$pkg_type" \
        --arg name "$name" \
        --arg installed "$installed" \
        --arg latest "$latest" \
        --arg freshness "$freshness" \
        --argjson latest_is_null "$latest_is_null" \
        '$enrichments + [{
            pkg_type: $pkg_type,
            name: $name,
            installed: $installed,
            latest: (if $latest_is_null then null else $latest end),
            freshness: $freshness
        }]'
}

# Enrich compare_sboms output with latest-version and freshness metadata.
# Usage: enrich_changelog <changelog_file> [current_sbom_file]
enrich_changelog() (
    set -uo pipefail
    if [[ "$#" -lt 1 || "$#" -gt 2 || -z "$1" ]]; then
        log_error "enrich_changelog requires a changelog path"
        return 2
    fi
    local changelog_file="$1"
    # This optional argument is retained for the public call signature. The
    # resolver derives image metadata from the adjacent lineage record instead.
    local current_sbom_file="${2:-}"
    : "$current_sbom_file"

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
            # shellcheck disable=SC1091
            if ! source "${_SBOM_UTILS_DIR}/dependency-freshness.sh"; then
                log_error "Failed to load dependency-freshness helper"
                return 1
            fi
            # dependency-freshness.sh has file-scope errexit; this public
            # function continues to use its explicit return-value contract.
            set +e
        else
            log_warning "dependency-freshness helper unavailable; skipping enrichment"
            return 0
        fi
    fi

    if ! _freshness_reset_apk_state; then
        log_error "Failed to reset dependency freshness state"
        return 1
    fi
    unset DEPENDENCY_FRESHNESS_IMAGE_REF DEPENDENCY_FRESHNESS_PLATFORM

    local lineage_file lineage_image_ref lineage_platform
    lineage_file="${changelog_file%.changelog.json}.json"
    if [[ -f "$lineage_file" ]]; then
        if ! lineage_image_ref=$(jq -r '.images.ghcr // .images.dockerhub // empty' "$lineage_file" 2>/dev/null); then
            log_error "Failed to read lineage image reference: $lineage_file"
            return 1
        fi
        if [[ -n "$lineage_image_ref" ]]; then
            DEPENDENCY_FRESHNESS_IMAGE_REF="$lineage_image_ref"
            export DEPENDENCY_FRESHNESS_IMAGE_REF
        fi
        if ! lineage_platform=$(jq -r '.platform // empty' "$lineage_file" 2>/dev/null); then
            log_error "Failed to read lineage platform: $lineage_file"
            return 1
        fi
        if [[ -n "$lineage_platform" ]]; then
            DEPENDENCY_FRESHNESS_PLATFORM="$lineage_platform"
            export DEPENDENCY_FRESHNESS_PLATFORM
        fi
    fi

    local eligible_json eligible_count queries_json latest_results
    local max_queries_raw max_queries query_count skipped_count skipped_queries_json skipped_results_json
    if ! eligible_json=$(jq -c '
        [
            .changes[]?
            | select(.type == "updated" or .type == "added")
            | select(.pkg_type != null and .name != null)
            | {pkg_type, name, installed: (.to // .version // null)}
            | select(.installed != null)
        ]
    ' "$changelog_file"); then
        log_error "Failed to read changelog changes: $changelog_file"
        return 1
    fi
    if ! eligible_count=$(jq -er 'length | select(type == "number")' <<< "$eligible_json"); then
        log_error "Failed to count eligible changelog changes: $changelog_file"
        return 1
    fi
    if [[ "$eligible_count" -eq 0 ]]; then
        return 0
    fi

    if ! queries_json=$(jq -c 'sort_by([.pkg_type, .name]) | unique_by([.pkg_type, .name])' <<< "$eligible_json"); then
        log_error "Failed to construct dependency freshness queries: $changelog_file"
        return 1
    fi
    if ! query_count=$(jq -er 'length | select(type == "number")' <<< "$queries_json"); then
        log_error "Failed to count dependency freshness queries: $changelog_file"
        return 1
    fi
    max_queries_raw="${DEPENDENCY_FRESHNESS_MAX_QUERIES:-200}"
    if [[ "$max_queries_raw" =~ ^[0-9]+$ ]]; then
        max_queries=$((10#$max_queries_raw))
    else
        max_queries=200
    fi
    skipped_results_json="[]"
    if (( query_count > max_queries )); then
        skipped_count=$((query_count - max_queries))
        if ! skipped_queries_json=$(jq -c --argjson max "$max_queries" '.[$max:]' <<< "$queries_json"); then
            log_error "Failed to select skipped dependency freshness queries: $changelog_file"
            return 1
        fi
        if ! skipped_results_json=$(jq -c '
            map({
                pkg_type,
                name,
                latest: null,
                query_failed: false,
                skipped: true
            })
        ' <<< "$skipped_queries_json"); then
            log_error "Failed to mark skipped dependency freshness queries: $changelog_file"
            return 1
        fi
        if ! queries_json=$(jq -c --argjson max "$max_queries" '.[0:$max]' <<< "$queries_json"); then
            log_error "Failed to limit dependency freshness queries: $changelog_file"
            return 1
        fi
        log_warning "Dependency freshness query cap reached: checking ${max_queries} of ${query_count} unique packages; skipped ${skipped_count} packages as not-computed (set DEPENDENCY_FRESHNESS_MAX_QUERIES to adjust)"
    fi

    if ! latest_results=$(_enrich_changelog_latest_results "$queries_json"); then
        log_warning "Dependency freshness latest-version batch failed; marking affected checks as query-failed"
        latest_results="[]"
    elif ! jq -e 'type == "array"' <<< "$latest_results" >/dev/null 2>&1; then
        log_warning "Dependency freshness latest-version batch returned malformed JSON; marking affected checks as query-failed"
        latest_results="[]"
    fi
    if ! latest_results=$(jq -cn --argjson latest "$latest_results" --argjson skipped "$skipped_results_json" '$latest + $skipped'); then
        log_error "Failed to combine dependency freshness results: $changelog_file"
        return 1
    fi

    local enrichments row pkg_type name installed resolver latest_record latest query_failed skipped freshness version_gt_status
    enrichments="[]"
    local eligible_rows
    if ! eligible_rows=$(jq -c '.[]' <<< "$eligible_json"); then
        log_error "Failed to enumerate eligible changelog changes: $changelog_file"
        return 1
    fi
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        if ! pkg_type=$(jq -er '.pkg_type | select(type == "string")' <<< "$row") \
            || ! name=$(jq -er '.name | select(type == "string")' <<< "$row") \
            || ! installed=$(jq -er '.installed | select(type == "string")' <<< "$row") \
            || ! resolver=$(_freshness_resolver_for "$pkg_type"); then
            log_error "Failed to read dependency freshness query: $changelog_file"
            return 1
        fi

        if ! latest_record=$(jq -c --arg pkg_type "$pkg_type" --arg name "$name" '
            map(select(.pkg_type == $pkg_type and .name == $name)) | first // {latest:null, query_failed:true}
        ' <<< "$latest_results"); then
            log_error "Failed to select dependency freshness result: $changelog_file"
            return 1
        fi
        if ! latest=$(jq -r '.latest // "null"' <<< "$latest_record") \
            || ! query_failed=$(jq -r 'if has("query_failed") then .query_failed else true end' <<< "$latest_record") \
            || ! skipped=$(jq -r 'if has("skipped") then .skipped else false end' <<< "$latest_record"); then
            log_error "Failed to read dependency freshness result: $changelog_file"
            return 1
        fi
        if [[ "$query_failed" != "true" && "$query_failed" != "false" ]] \
            || [[ "$skipped" != "true" && "$skipped" != "false" ]]; then
            log_error "Dependency freshness result has invalid flags: $changelog_file"
            return 1
        fi
        freshness="not-computed"

        if [[ -z "$resolver" ]]; then
            freshness="not-computed"
        elif [[ "$skipped" == "true" ]]; then
            freshness="not-computed"
        elif [[ "$query_failed" == "true" ]]; then
            freshness="query-failed"
        elif [[ "$latest" != "null" && "$installed" == "$latest" ]]; then
            freshness="up-to-date"
        elif [[ "$latest" != "null" ]]; then
            if _freshness_version_gt "$pkg_type" "$latest" "$installed"; then
                freshness="update-available"
            else
                version_gt_status=$?
                if [[ "$version_gt_status" -eq 2 ]]; then
                    freshness="not-computed"
                else
                    freshness="up-to-date"
                fi
            fi
        else
            freshness="query-failed"
        fi

        if ! enrichments=$(_enrich_changelog_add_enrichment \
            "$enrichments" "$pkg_type" "$name" "$installed" "$latest" "$freshness"); then
            log_error "Failed to construct dependency freshness enrichment: $changelog_file"
            return 1
        fi
    done <<< "$eligible_rows"

    local tmp_file
    if ! tmp_file=$(mktemp "${changelog_file}.tmp.XXXXXX"); then
        log_error "Failed to create temporary enriched changelog: $changelog_file"
        return 1
    fi
    if jq --argjson enrichments "$enrichments" '
        def installed_version: .to // .version;
        ($enrichments
            | map({
                key: ([.pkg_type, .name, .installed] | @json),
                value: {latest, freshness}
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
        if [[ ! -f "$tmp_file" || ! -r "$tmp_file" ]] \
            || ! jq -e 'type == "object"' "$tmp_file" >/dev/null 2>&1; then
            rm -f -- "$tmp_file"
            log_warning "Dependency freshness enrichment produced invalid JSON: $changelog_file"
            return 1
        fi
        if ! mv -f -- "$tmp_file" "$changelog_file"; then
            rm -f -- "$tmp_file"
            log_warning "Dependency freshness enrichment failed while writing changelog: $changelog_file"
            return 1
        fi
        log_info "Dependency freshness enriched: $changelog_file"
        return 0
    else
        rm -f -- "$tmp_file"
        log_warning "Dependency freshness enrichment failed; leaving changelog unchanged: $changelog_file"
        return 1
    fi
)

# Append build metadata to history file (keeps last N entries)
# Usage: append_build_history <lineage_file> <sbom_summary_json> <history_file> [max_entries] [changelog_file]
# lineage_file: build lineage JSON with built_at, version, build_digest
# sbom_summary_json: output of extract_sbom_summary (JSON string)
# history_file: path to the history JSON file (created if missing)
# max_entries: max entries to keep (default: 10)
# changelog_file: path to changelog JSON (default: derived from history_file)
append_build_history() (
    set -uo pipefail
    if [[ "$#" -lt 3 || "$#" -gt 5 || -z "$1" || -z "$2" || -z "$3" ]]; then
        log_error "append_build_history requires lineage, summary, and history paths"
        return 2
    fi
    local lineage_file="$1"
    local sbom_summary="$2"
    local history_file="$3"
    local max_entries="${4:-10}"

    if [[ -d "$history_file" ]]; then
        log_error "Build history output path is a directory: $history_file"
        return 1
    fi
    if [[ ! "$max_entries" =~ ^[0-9]+$ ]]; then
        log_error "Build history max_entries must be a non-negative integer: $max_entries"
        return 2
    fi

    local output_dir
    if ! output_dir=$(dirname -- "$history_file"); then
        log_error "Failed to determine build history output directory: $history_file"
        return 1
    fi
    if ! mkdir -p -- "$output_dir"; then
        log_error "Failed to create build history output directory: $output_dir"
        return 1
    fi

    # Extract metadata from lineage file
    local built_at version build_digest duration_seconds extensions_build_seconds extensions_present
    extensions_present="false"
    if [[ -f "$lineage_file" ]]; then
        if ! built_at=$(jq -r '.built_at // empty' "$lineage_file" 2>/dev/null) \
            || ! version=$(jq -r '.version // empty' "$lineage_file" 2>/dev/null) \
            || ! build_digest=$(jq -r '.build_digest // empty' "$lineage_file" 2>/dev/null) \
            || ! duration_seconds=$(jq -c '.duration_seconds // null' "$lineage_file" 2>/dev/null) \
            || ! extensions_present=$(jq -r 'has("extensions_build_seconds")' "$lineage_file" 2>/dev/null) \
            || ! extensions_build_seconds=$(jq -c '.extensions_build_seconds // null' "$lineage_file" 2>/dev/null); then
            log_error "Failed to read build lineage: $lineage_file"
            return 1
        fi
        if [[ "$extensions_present" != "true" && "$extensions_present" != "false" ]]; then
            log_error "Build lineage has invalid extensions metadata: $lineage_file"
            return 1
        fi
        # Only emit extensions_build_seconds when the source lineage actually
        # carries it. Containers without `extensions/config.yaml` (terraform,
        # ansible, …) don't write the field, and we must not synthesise a
        # null entry — the dashboard frontend keys "container has extensions
        # concept" off field presence (Object.hasOwnProperty), not value.
    fi

    # Fallback for missing fields
    if [[ -z "${built_at:-}" ]]; then
        if ! built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ"); then
            log_error "Failed to determine build history timestamp"
            return 1
        fi
    fi
    [[ -z "${version:-}" ]] && version="unknown"
    [[ -z "${build_digest:-}" ]] && build_digest="unknown"
    [[ -z "${duration_seconds:-}" ]] && duration_seconds="null"
    [[ -z "${extensions_build_seconds:-}" ]] && extensions_build_seconds="null"

    # Extract totals from summary
    local packages_total
    if ! packages_total=$(jq -er '(.total // 0) | select(type == "number")' <<< "$sbom_summary" 2>/dev/null); then
        log_error "Failed to read SBOM summary total"
        return 1
    fi
    local packages_by_type
    if ! packages_by_type=$(jq -ce 'del(.total)' <<< "$sbom_summary" 2>/dev/null); then
        log_error "Failed to read SBOM summary package types"
        return 1
    fi

    # Load existing history or start fresh
    local existing_history="[]"
    if [[ -f "$history_file" ]]; then
        if ! existing_history=$(jq -ce 'select(type == "array")' "$history_file" 2>/dev/null); then
            log_error "Failed to read build history: $history_file"
            return 1
        fi
    fi

    # Build changes_summary from changelog if it exists
    local changes_summary=""
    local changelog_file="${5:-${history_file%.history.json}.changelog.json}"
    if [[ -f "$changelog_file" ]]; then
        if ! changes_summary=$(jq -er '
            [(.summary.added // 0), (.summary.removed // 0), (.summary.updated // 0)]
            | map(select(type == "number"))
            | "+\(.[0]) -\(.[1]) ~\(.[2])"
        ' "$changelog_file" 2>/dev/null); then
            log_error "Failed to read build changelog summary: $changelog_file"
            return 1
        fi
    fi

    # Create new entry and prepend to history, keeping max_entries.
    # extensions_build_seconds is conditionally added only when the source
    # lineage carried it — preserves the "container has no extensions concept"
    # signal for non-postgres containers.
    local tmp_file entry_count
    if ! tmp_file=$(mktemp "${history_file}.tmp.XXXXXX"); then
        log_error "Failed to create temporary build history: $history_file"
        return 1
    fi
    if ! jq -n \
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
    ' > "$tmp_file"; then
        rm -f -- "$tmp_file"
        log_error "Failed to generate build history: $history_file"
        return 1
    fi
    if [[ ! -f "$tmp_file" || ! -r "$tmp_file" ]] \
        || ! jq -e 'type == "array"' "$tmp_file" >/dev/null 2>&1; then
        rm -f -- "$tmp_file"
        log_error "Generated build history is not readable valid JSON: $history_file"
        return 1
    fi
    if ! entry_count=$(jq -er 'length | select(type == "number")' "$tmp_file"); then
        rm -f -- "$tmp_file"
        log_error "Generated build history has an invalid entry count: $history_file"
        return 1
    fi
    if ! mv -f -- "$tmp_file" "$history_file"; then
        rm -f -- "$tmp_file"
        log_error "Failed to publish build history: $history_file"
        return 1
    fi

    log_info "Build history updated: $history_file (${entry_count} entries)"
    return 0
)
