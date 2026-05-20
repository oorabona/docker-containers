#!/bin/bash
# Generate dashboard data as YAML for Jekyll consumption
# This script outputs container data that Jekyll can iterate over
#
# Architecture: data is collected as JSON objects, then converted to YAML via yq.
# This eliminates fragile echo/heredoc YAML generation and ensures consistency
# between containers.yml and per-container page files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/helpers/logging.sh"
source "$SCRIPT_DIR/helpers/variant-utils.sh"
source "$SCRIPT_DIR/helpers/build-args-utils.sh"
source "$SCRIPT_DIR/helpers/registry-utils.sh"
source "$SCRIPT_DIR/helpers/version-utils.sh"
source "$SCRIPT_DIR/helpers/sbom-utils.sh"
source "$SCRIPT_DIR/helpers/attestation-utils.sh"
source "$SCRIPT_DIR/helpers/trivy-utils.sh"
source "$SCRIPT_DIR/helpers/extension-utils.sh"

# Cross-subshell cache for Trivy summary — collect_variant_json runs in $(…)
# subshells, so the in-memory _TRIVY_SUMMARY_MAP is lost after each call.
# Materialize the cache to a file so sibling subshells share one API fetch.
TRIVY_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/trivy-summary-cache.XXXXXX")
export TRIVY_CACHE_FILE
trap 'rm -f -- "$TRIVY_CACHE_FILE"' EXIT

DATA_FILE="$SCRIPT_DIR/docs/site/_data/containers.yml"
STATS_FILE="$SCRIPT_DIR/docs/site/_data/stats.yml"
CONTAINERS_DIR="$SCRIPT_DIR/docs/site/_containers"

# --- Lineage resolution helpers ---

# Resolve the lineage JSON file for a container
# Tries {container}.json first, then falls back to {container}-*.json (first match)
resolve_lineage_file() {
    local container="$1"
    local lineage_dir="$SCRIPT_DIR/.build-lineage"
    local lineage_file="$lineage_dir/${container}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
        return
    fi
    # Fallback: flavored lineage files (e.g. postgres-base.json)
    local fallback
    fallback=$(find "$lineage_dir" -maxdepth 1 -name "${container}-*.json" -print -quit 2>/dev/null)
    if [[ -n "$fallback" ]]; then
        echo "$fallback"
    fi
}

# Resolve lineage file for a specific variant of a container
# Primary: {container}-{tag}.json (e.g. postgres-18-alpine.json)
# Fallback 1: {container}-{flavor}.json (legacy format, e.g. postgres-base.json)
# Fallback 2: {container}.json (non-variant containers)
resolve_variant_lineage_file() {
    local container="$1"
    local tag="$2"
    local flavor="${3:-}"
    local lineage_dir="$SCRIPT_DIR/.build-lineage"
    # Primary: per-tag lineage file (new format)
    local lineage_file="$lineage_dir/${container}-${tag}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
        return
    fi
    # Fallback 1: per-flavor lineage file (legacy format)
    if [[ -n "$flavor" ]]; then
        lineage_file="$lineage_dir/${container}-${flavor}.json"
        if [[ -f "$lineage_file" ]]; then
            echo "$lineage_file"
            return
        fi
    fi
    # Fallback 2: main container lineage
    lineage_file="$lineage_dir/${container}.json"
    if [[ -f "$lineage_file" ]]; then
        echo "$lineage_file"
    fi
}

# Get a field from the build lineage JSON for a container
# Falls back to "unknown" if lineage data doesn't exist
get_build_lineage_field() {
    local container="$1"
    local field="$2"
    local lineage_file
    lineage_file=$(resolve_lineage_file "$container")
    if [[ -n "$lineage_file" ]]; then
        jq -r ".[\"$field\"] // \"unknown\"" "$lineage_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get container-level build_args from lineage as JSON array [{name, value}, ...]
# Falls back to config.yaml when lineage files are unavailable
get_build_lineage_args_json() {
    local container="$1"

    # Try lineage file first
    local lineage_file
    lineage_file=$(resolve_lineage_file "$container")
    if [[ -n "$lineage_file" ]]; then
        local args
        args=$(jq '.build_args // {}' "$lineage_file" 2>/dev/null)
        if [[ "$args" != "{}" && -n "$args" ]]; then
            echo "$args" | jq '[to_entries[] | {name: .key, value: (.value | tostring)}]'
            return
        fi
    fi

    # Fallback to config.yaml
    local lines
    lines=$(build_args_lines "$SCRIPT_DIR/$container")
    if [[ -n "$lines" ]]; then
        echo "$lines" | jq -R 'split("=") | {name: .[0], value: (.[1:] | join("="))}' | jq -s '.'
        return
    fi

    echo "[]"
}

# Get build_args filtered for a specific variant as JSON array
# Reads build_args_include from variants.yaml; if absent, includes all build_args
# For containers with extensions (e.g. postgres), resolves extension versions from flavors
# Usage: get_variant_build_args_json <container> <variant_name> [version_tag]
get_variant_build_args_json() {
    local container="$1"
    local variant_name="$2"
    local version_tag="${3:-latest}"
    local container_dir="$SCRIPT_DIR/$container"
    local variants_file="$container_dir/variants.yaml"
    local ext_config="$container_dir/extensions/config.yaml"

    # Strategy 1: containers with build_args in config.yaml (terraform, etc.)
    local args_json
    args_json=$(build_args_json "$container_dir")
    if [[ "$args_json" != "{}" ]] && [[ -n "$args_json" ]]; then
        # Check if this variant has build_args_include filter
        local filter_list=""
        if [[ -f "$variants_file" ]]; then
            filter_list=$(yq -r ".versions[] | select(.tag == \"$version_tag\") | .variants[] | select(.name == \"$variant_name\") | .build_args_include // [] | .[]" "$variants_file" 2>/dev/null)
            # Fallback to "latest" tag
            if [[ -z "$filter_list" ]]; then
                filter_list=$(yq -r '.versions[] | select(.tag == "latest") | .variants[] | select(.name == "'"$variant_name"'") | .build_args_include // [] | .[]' "$variants_file" 2>/dev/null)
            fi
        fi

        if [[ -n "$filter_list" ]]; then
            local jq_filter
            jq_filter=$(echo "$filter_list" | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
            echo "$args_json" | jq '[to_entries[] | select(.key == ('"$jq_filter"')) | {"name": .key, "value": (.value | tostring)}]' 2>/dev/null || echo "[]"
        else
            echo "$args_json" | jq '[to_entries[] | {"name": .key, "value": (.value | tostring)}]' 2>/dev/null || echo "[]"
        fi
        return
    fi

    # Strategy 2: containers with extensions (postgres) — resolve from flavor files
    local flavor_file="$container_dir/flavors/${variant_name}.yaml"
    if [[ -f "$ext_config" ]] && [[ -f "$flavor_file" ]]; then
        local ext_names
        ext_names=$(yq -r '.extensions // [] | .[]' "$flavor_file" 2>/dev/null)
        if [[ -z "$ext_names" ]]; then
            echo "[]"
            return
        fi
        # Build JSON array of {name: ext_name, value: version} from extensions/config.yaml
        local result="["
        local first=true
        while IFS= read -r ext; do
            [[ -z "$ext" ]] && continue
            local ver
            # P1-SECURITY: ext name comes from yq output — use strenv() to prevent injection.
            ver=$(YQ_EXT="$ext" yq -r '.extensions[strenv(YQ_EXT)].version // ""' "$ext_config" 2>/dev/null)
            [[ -z "$ver" ]] && continue
            $first || result+=","
            first=false
            result+="{\"name\":\"${ext}\",\"value\":\"${ver}\"}"
        done <<< "$ext_names"
        result+="]"
        echo "$result"
        return
    fi

    echo "[]"
}

# --- Container metadata helpers ---

# Function to check if a directory should be skipped
is_skip_directory() {
    local container=$1
    [[ "$container" == "helpers" || "$container" == "docs" || "$container" == "backup-"* || \
       "$container" == ".github" || "$container" == "archive"* || "$container" == "_"* || \
       "$container" == "test-"* || "$container" == "scripts" ]]
}

# Get container versions
get_container_versions() {
    local container=$1

    pushd "$container" >/dev/null 2>&1 || {
        echo "unknown|unknown|secondary|Unknown Status"
        return 1
    }

    local current_version latest_version status_color status_text

    local _t0_skopeo=${EPOCHREALTIME:-}
    current_version=$(get_current_published_version "oorabona/$container")
    log_latency "skopeo-list-tags oorabona/$container" "$_t0_skopeo" 60
    # Handle empty result
    [[ -z "$current_version" ]] && current_version="no-published-version"

    latest_version=$(timeout 30 ./version.sh 2>/dev/null | head -1 | tr -d '\n' || echo "unknown")

    popd >/dev/null 2>&1

    if [[ "$current_version" == "no-published-version" ]]; then
        status_color="warning"
        status_text="Not Published Yet"
    elif [[ "$current_version" == "unknown" || "$latest_version" == "unknown" ]]; then
        status_color="secondary"
        status_text="Unknown Status"
    elif [[ "$current_version" == "$latest_version" ]]; then
        status_color="green"
        status_text="Up to Date"
    else
        status_color="warning"
        status_text="Update Available"
    fi

    echo "${current_version}|${latest_version}|${status_color}|${status_text}"
}

# Get container description from README
get_container_description() {
    local container=$1
    local description=""

    if [[ -f "$container/README.md" ]]; then
        description=$(awk '
            BEGIN { found_desc = 0 }
            /^---$/ && NR == 1 { in_frontmatter = 1; next }
            /^---$/ && in_frontmatter { in_frontmatter = 0; next }
            in_frontmatter { next }
            /^# / && !found_desc {
                title = $0
                gsub(/^# /, "", title)
                gsub(/[Dd]ocker [Cc]ontainer[[:space:]]*/, "", title)
                gsub(/^[[:space:]]*/, "", title)
                gsub(/[[:space:]]*$/, "", title)
                if (length(title) > 15 && length(title) < 120) {
                    print title
                    found_desc = 1
                }
            }
            /^[^#\[]/ && !/^\[!?\[/ && length($0) > 20 && !found_desc {
                gsub(/^[[:space:]]*/, "")
                gsub(/[[:space:]]*$/, "")
                if (length($0) > 0) {
                    print $0
                    found_desc = 1
                }
            }
        ' "$container/README.md")
    fi

    if [[ -z "$description" ]]; then
        description="Docker container for ${container}"
    fi

    echo "$description"
}

# Escape YAML string (handle quotes and special chars)
yaml_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

# --- JSON data collection ---
# These functions build container data as JSON objects, eliminating the need
# for manual YAML string construction. The JSON is converted to YAML via yq.

# Resolve variant lineage data as JSON: {build_digest, base_image, oci_subject_digest}
# Includes version mismatch check and fallback base_image derivation.
# `oci_subject_digest` is propagated from the raw lineage file when present so
# downstream attestation lookups can use the OCI digest (the value the
# attestations API is keyed on) rather than the internal build-cache digest.
resolve_variant_lineage_json() {
    local container="$1" tag="$2" version="$3" fallback_base_image="${4:-unknown}" flavor="${5:-}"

    local lineage_file build_digest="unknown" base_image="unknown" oci_subject_digest=""
    lineage_file=$(resolve_variant_lineage_file "$container" "$tag" "$flavor")

    if [[ -n "$lineage_file" ]]; then
        build_digest=$(jq -r '.build_digest // "unknown"' "$lineage_file" 2>/dev/null || echo "unknown")
        base_image=$(jq -r '.base_image_ref // "unknown"' "$lineage_file" 2>/dev/null || echo "unknown")
        oci_subject_digest=$(jq -r '.oci_subject_digest // empty' "$lineage_file" 2>/dev/null || echo "")
        # Version mismatch check: lineage file may be from a different version
        if [[ "$base_image" != "unknown" ]]; then
            local lineage_ver
            lineage_ver=$(jq -r '.version // ""' "$lineage_file" 2>/dev/null || echo "")
            # Compare major version: lineage may store a major-version tag
            # (e.g., "18-alpine") while version is a full version (e.g.,
            # "18.1-alpine"). Extract leading digits to compare.
            local lineage_major="${lineage_ver%%[^0-9]*}"
            local version_major="${version%%[^0-9]*}"
            if [[ -n "$lineage_major" && -n "$version_major" && "$lineage_major" != "$version_major" ]]; then
                base_image="${base_image%%:*}:${version}"
                build_digest="unknown"
                oci_subject_digest=""
            fi
        fi
    else
        # Derive base_image from fallback prefix + version
        local prefix="${fallback_base_image%%:*}"
        if [[ -n "$prefix" && "$prefix" != "unknown" ]]; then
            base_image="${prefix}:${version}"
        fi
    fi

    BD="$build_digest" BI="$base_image" OCI="$oci_subject_digest" \
        yq -n -o json '.build_digest = strenv(BD) | .base_image = strenv(BI) | .oci_subject_digest = strenv(OCI)'
}

# --- SBOM data helpers ---

# Read SBOM summary for a variant
# Returns: JSON object or empty object
get_sbom_summary() {
    local container="$1" tag="$2"
    local sbom_file="$SCRIPT_DIR/.build-lineage/${container}-${tag}.sbom.json"
    if [[ -f "$sbom_file" ]]; then
        local result
        # shellcheck disable=SC2016  # $total/$ref are jq variables, not bash expansions
        if ! result=$(timeout 60 jq '
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
        ' "$sbom_file" 2>/dev/null); then
            echo "::warning::SBOM jq for ${container}:${tag} timed out/failed — empty" >&2
            result="{}"
        fi
        echo "$result"
    else
        echo "{}"
    fi
}

# Read SBOM packages grouped by type (for drill-down)
# Returns: JSON object or empty object
get_sbom_packages() {
    local container="$1" tag="$2"
    local sbom_file="$SCRIPT_DIR/.build-lineage/${container}-${tag}.sbom.json"
    if [[ -f "$sbom_file" ]]; then
        local result
        if ! result=$(timeout 60 jq -r '
            [.packages[]? | {type: (.externalRefs[]? | select(.referenceType == "purl") | .referenceLocator | split("/")[0] | ltrimstr("pkg:")), name: .name, version: .versionInfo}]
            | group_by(.type)
            | map({key: .[0].type, value: [.[] | {n: .name, v: .version}]})
            | from_entries
        ' "$sbom_file" 2>/dev/null); then
            echo "::warning::SBOM jq for ${container}:${tag} timed out/failed — empty" >&2
            result="{}"
        fi
        echo "$result"
    else
        echo "{}"
    fi
}

# Read changelog for a variant
# Returns: changelog JSON or empty object
get_changelog() {
    local container="$1" tag="$2"
    local file="$SCRIPT_DIR/.build-lineage/${container}-${tag}.changelog.json"
    if [[ -f "$file" ]]; then
        jq '.' "$file" 2>/dev/null || echo "{}"
    else
        echo "{}"
    fi
}

# Read build history for a variant
# Returns: history JSON array or empty array
get_build_history() {
    local container="$1" tag="$2"
    local file="$SCRIPT_DIR/.build-lineage/${container}-${tag}.history.json"
    if [[ -f "$file" ]]; then
        jq '.' "$file" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

# Return the JSON array of dependency names visible in the dashboard for a given container+flavor.
#
# Lifecycle-driven (AC-20): lifecycle: is the single source of truth.
# The legacy monitor: boolean is NOT consulted — it was the cause of stable-pin
# entries being incorrectly omitted from variant_deps (RESTY_OPENSSL_VERSION
# has lifecycle: stable-pin + monitor: false → was wrongly excluded).
#
# Inclusion rule (mirrors build_dependency_monitoring_json):
#   tracked     → included (actively monitored)
#   stable-pin  → included (pinned with EOL date — shown with countdown badge)
#   eol-migrate → included (needs migration action)
#   untracked   → excluded (build-only values: parallelism flags, fallback tags)
#   (empty)     → included (backward-compat: empty lifecycle defaults to "tracked")
#
# For postgres (which has per-flavor extension lists):
#   - Reads the flavor's extension list from postgres/flavors/<flavor>.yaml
#   - Intersects with lifecycle-included names with flavor extensions
#   - Returns [] for base flavor (no extensions) or unknown flavors
#
# For all other containers (no flavor concept):
#   - Returns all lifecycle-included dependency_sources names
#   - The "flavor" argument is ignored for non-postgres containers
#
# Usage: variant_deps_for_flavor <container> <flavor>
# Output: JSON array of dep names, e.g. ["RESTY_OPENSSL_VERSION","RESTY_PCRE_VERSION"]
variant_deps_for_flavor() {
    local container="$1"
    local flavor="${2:-}"
    local dep_config="${SCRIPT_DIR:-.}/${container}/config.yaml"

    if [[ ! -f "$dep_config" ]]; then
        echo "[]"
        return 0
    fi

    # Postgres MUST have a flavor; empty/null flavor returns [] (not container-wide).
    if [[ "$container" == "postgres" && ( -z "$flavor" || "$flavor" == "null" ) ]]; then
        echo "[]"
        return 0
    fi

    # Collect dep names by lifecycle (AC-20): exclude only lifecycle: untracked.
    # stable-pin, tracked, eol-migrate, and empty-lifecycle are all included.
    local included_names
    included_names=$(yq -r '
        .dependency_sources // {} | to_entries[] |
        select((.value.lifecycle // "") != "untracked") |
        .key' "$dep_config" 2>/dev/null) || true

    if [[ -z "$included_names" ]]; then
        echo "[]"
        return 0
    fi

    # For postgres with a known flavor: intersect included names with flavor extensions
    if [[ "$container" == "postgres" && -n "$flavor" && "$flavor" != "null" ]]; then
        local flavor_exts
        flavor_exts=$(get_flavor_extensions_yaml "$flavor")

        # If flavor has no extensions, return empty (base flavor)
        if [[ "$flavor_exts" == "[]" || -z "$flavor_exts" ]]; then
            echo "[]"
            return 0
        fi

        # Intersect: keep only included names that appear in flavor_exts
        echo "$included_names" | \
            jq -Rs 'split("\n") | map(select(length > 0))' | \
            jq --argjson exts "$flavor_exts" \
               '[.[] | select(. as $n | $exts | index($n) != null)]'
        return 0
    fi

    # Non-postgres (or postgres with no flavor): return all lifecycle-included dep names
    echo "$included_names" | \
        jq -Rs 'split("\n") | map(select(length > 0))'
}

# Build a single variant entry as JSON
# Handles sizes, lineage, and build_args in one place (no duplication)
collect_variant_json() {
    local container="$1" container_dir="$2" variant_name="$3"
    local version="$4" current_version="$5" fallback_base_image="$6"
    local is_versioned="${7:-false}"

    local variant_tag variant_desc is_default
    variant_tag=$(variant_image_tag "$version" "$variant_name" "$container_dir")
    if [[ "$is_versioned" == "true" ]]; then
        variant_desc=$(variant_property "$container_dir" "$variant_name" "description" "$version")
        is_default=$(variant_property "$container_dir" "$variant_name" "default" "$version")
    else
        variant_desc=$(variant_property "$container_dir" "$variant_name" "description")
        is_default=$(variant_property "$container_dir" "$variant_name" "default")
    fi
    [[ "$is_default" != "true" ]] && is_default="false"

    # Sizes
    local size_amd64="" size_arm64=""
    if [[ "$current_version" != "no-published-version" ]]; then
        local sizes_raw
        sizes_raw=$(get_ghcr_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
        if [[ -n "$sizes_raw" ]]; then
            size_amd64=$(echo "$sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
            size_arm64=$(echo "$sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
        fi
    fi

    # Lineage (build_digest + base_image with version mismatch check)
    # Use variant_tag for lineage file lookup, version for mismatch check
    # (NOT current_version — that's the container's latest published version,
    # which may differ from this variant's PG major version)
    local flavor
    if [[ "$is_versioned" == "true" ]]; then
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$version")
    else
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor")
    fi
    local lineage_json
    lineage_json=$(resolve_variant_lineage_json "$container" "$variant_tag" "$version" "$fallback_base_image" "$flavor")

    # Build args
    local build_args_json
    if [[ "$is_versioned" == "true" ]]; then
        build_args_json=$(get_variant_build_args_json "$container" "$variant_name" "$version")
    else
        build_args_json=$(get_variant_build_args_json "$container" "$variant_name")
    fi
    [[ -z "$build_args_json" ]] && build_args_json="[]"

    # SBOM data (package summary, packages detail, changelog, build history)
    local sbom_tag="$variant_tag"
    local sbom_summary sbom_packages changelog build_history
    sbom_summary=$(get_sbom_summary "$container" "$sbom_tag")
    sbom_packages=$(get_sbom_packages "$container" "$sbom_tag")
    changelog=$(get_changelog "$container" "$sbom_tag")
    build_history=$(get_build_history "$container" "$sbom_tag")
    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] sbom_summary for $container-$sbom_tag = ${sbom_summary:0:60}…" >&2
    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] changelog for $container-$sbom_tag = ${changelog:0:60}…" >&2
    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] build_history for $container-$sbom_tag = ${build_history:0:60}…" >&2

    # Attestation: look up SBOM attestation ID from GitHub Attestations API.
    # The attestations API is keyed on the OCI subject digest (sha256:…) that
    # `actions/attest-sbom` signs — NOT the internal build-cache digest. Prefer
    # `.oci_subject_digest` when the build pipeline has captured it; fall back
    # to `.build_digest` for older lineage files predating the post-flatten
    # capture step. NB: jq's `//` only treats null/false as missing, so an
    # empty-string `.oci_subject_digest` would short-circuit incorrectly — the
    # explicit shell-level check below handles that case.
    local subject_digest attestation_id="" attestation_url=""
    subject_digest=$(echo "$lineage_json" | jq -r '.oci_subject_digest // empty')
    if [[ -z "$subject_digest" ]]; then
        subject_digest=$(echo "$lineage_json" | jq -r '.build_digest // "unknown"')
        [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
            echo "[debug] using fallback build_digest=$subject_digest (oci_subject_digest empty) for $container-$sbom_tag" >&2
    fi
    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] subject_digest for $container-$sbom_tag = ${subject_digest:0:60}…" >&2
    local _t0_att=${EPOCHREALTIME:-}
    if [[ -n "$subject_digest" && "$subject_digest" != "unknown" ]] \
        && attestation_id=$(get_attestation_id "$subject_digest"); then
        attestation_url=$(get_attestation_url "$attestation_id")
    fi
    log_latency "gh-attestation" "$_t0_att" 20

    # Trivy: collect vulnerability summary for the primary platform (linux/amd64)
    local trivy_category trivy_summary
    trivy_category=$(build_trivy_category "$container" "$variant_tag" "linux/amd64")
    trivy_summary=$(get_trivy_summary "$trivy_category")
    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] trivy_summary for $container-$variant_tag = ${trivy_summary:0:60}…" >&2

    # Multi-arch platform list: derive from GHCR manifest (reuse ghcr_get_manifest_sizes)
    local multi_arch_platforms_json="[]"
    if [[ "$current_version" != "no-published-version" ]]; then
        local raw_sizes arch_list=""
        local _t0_ghcr=${EPOCHREALTIME:-}
        raw_sizes=$(ghcr_get_manifest_sizes "oorabona/$container" "$variant_tag" 2>/dev/null) || true
        log_latency "ghcr-index oorabona/${container}:${variant_tag}" "$_t0_ghcr" 30
        if [[ -n "$raw_sizes" ]]; then
            arch_list=$(echo "$raw_sizes" | awk -F: '{print $1}' | \
                jq -R . | jq -s '.')
        fi
        [[ -n "$arch_list" && "$arch_list" != "[]" ]] && multi_arch_platforms_json="$arch_list"
    fi

    # Multi-arch digests: index digest + per-platform (amd64, arm64) manifest digests.
    # Fetched from the GHCR registry v2 API at dashboard-generation time.
    # Returns all-null JSON on token/API failure — never exits non-zero.
    local multi_arch_digests_json
    multi_arch_digests_json='{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
    if [[ "$current_version" != "no-published-version" ]]; then
        local _t0_ghcr_ma=${EPOCHREALTIME:-}
        multi_arch_digests_json=$(ghcr_get_multi_arch_digests "oorabona/$container" "$variant_tag" 2>/dev/null) || true
        log_latency "ghcr-index oorabona/${container}:${variant_tag} (multi-arch)" "$_t0_ghcr_ma" 30
        [[ -z "$multi_arch_digests_json" ]] && \
            multi_arch_digests_json='{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
    fi
    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] multi_arch_digests for $container-$variant_tag = ${multi_arch_digests_json:0:120}…" >&2

    # Postgres-specific: extensions and when_to_use from flavor file and variants.yaml
    local extensions_json="null" when_to_use=""
    if [[ "$container" == "postgres" && -n "$flavor" && "$flavor" != "null" ]]; then
        extensions_json=$(get_flavor_extensions_yaml "$flavor")
        if [[ "$is_versioned" == "true" ]]; then
            when_to_use=$(variant_property "$container_dir" "$variant_name" "when_to_use" "$version")
        else
            when_to_use=$(variant_property "$container_dir" "$variant_name" "when_to_use")
        fi
    fi

    # Variant-level monitored dependency names.
    # For postgres: intersection of flavor extensions with container-wide monitored deps
    #   (done inside variant_deps_for_flavor).
    # For all others: intersect container-wide monitored dep names with THIS variant's
    #   build_args names so that per-variant build_args_include filters take effect
    #   (e.g. terraform base vs full have different cloud CLI sets).
    # Postgres is excluded from the build_args intersection because its build_args
    #   only carry BASE_IMAGE — not extension names — so the intersection would
    #   zero out the legitimate flavor-based list.
    local variant_deps_json
    variant_deps_json=$(variant_deps_for_flavor "$container" "$flavor")
    [[ -z "$variant_deps_json" ]] && variant_deps_json="[]"
    if [[ "$container" != "postgres" ]]; then
        local _ba_names_json
        _ba_names_json=$(echo "$build_args_json" | jq '[.[] | .name]' 2>/dev/null) || _ba_names_json="[]"
        [[ -z "$_ba_names_json" ]] && _ba_names_json="[]"
        variant_deps_json=$(jq -n \
            --argjson vd "$variant_deps_json" \
            --argjson ba "$_ba_names_json" \
            '$vd | map(select(. as $n | $ba | index($n) != null))')
    fi

    # --- jq -s stream-shift guard (Option A) -------------------------------
    # `jq -s` silently DROPS empty-string stream elements. If ANY of the 9
    # values below is empty, the slurp array collapses and positional
    # indices (.[0]..[8]) shift, corrupting the per-variant record (observed:
    # terraform Provenance digest rows rendered empty — the multi_arch_digests
    # object landed in the multi_arch_platforms slot). Normalize every input
    # to its valid-JSON fallback so the stream always has exactly 9 elements.
    # A fired guard is logged to stderr (rare = upstream producer broke).
    _slurp_guard() {  # $1=slot name  $2=fallback ; operates on named var via $1
        local _name="$1" _fallback="$2"
        local _val="${!_name}"
        if [[ -z "${_val//[[:space:]]/}" ]]; then
            printf 'WARN: collect_variant_json slurp guard fired: empty %s for %s:%s — substituted fallback\n' \
                "$_name" "$container" "$variant_tag" >&2
            printf -v "$_name" '%s' "$_fallback"
        fi
    }
    _slurp_guard lineage_json '{"build_digest":"unknown","base_image":"unknown","oci_subject_digest":""}'
    _slurp_guard build_args_json '[]'
    _slurp_guard sbom_summary '{}'
    _slurp_guard sbom_packages '{}'
    _slurp_guard changelog '{}'
    _slurp_guard build_history '[]'
    _slurp_guard trivy_summary '{}'
    _slurp_guard multi_arch_platforms_json '[]'
    _slurp_guard multi_arch_digests_json '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
    # ----------------------------------------------------------------------

    # Assemble JSON — pipe large data via stdin to avoid ARG_MAX limits
    # (SBOM packages can be very large for containers with many dependencies)
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        "$lineage_json" "$build_args_json" \
        "$sbom_summary" "$sbom_packages" \
        "$changelog" "$build_history" \
        "$trivy_summary" "$multi_arch_platforms_json" \
        "$multi_arch_digests_json" | \
    jq -s \
        --arg name "$variant_name" \
        --arg tag "$variant_tag" \
        --arg desc "$variant_desc" \
        --argjson is_default "$is_default" \
        --arg size_amd64 "$size_amd64" \
        --arg size_arm64 "$size_arm64" \
        --arg attestation_id "$attestation_id" \
        --arg attestation_url "$attestation_url" \
        --argjson extensions "$extensions_json" \
        --arg when_to_use "$when_to_use" \
        --argjson variant_deps "$variant_deps_json" \
        '
        .[0] as $lineage |
        .[1] as $build_args |
        .[2] as $sbom_summary |
        .[3] as $sbom_packages |
        .[4] as $changelog |
        .[5] as $build_history |
        .[6] as $trivy_summary |
        .[7] as $multi_arch_platforms |
        .[8] as $multi_arch_digests |
        {
            name: $name, tag: $tag, description: $desc,
            is_default: $is_default,
            size_amd64: $size_amd64, size_arm64: $size_arm64,
            build_digest: $lineage.build_digest,
            base_image: $lineage.base_image,
            variant_deps: $variant_deps
        }
        + (if ($multi_arch_platforms | length) > 0 then {multi_arch_platforms: $multi_arch_platforms} else {} end)
        + (if $multi_arch_digests.index_digest != null then {multi_arch_index_digest: $multi_arch_digests.index_digest} else {} end)
        + (if $multi_arch_digests.manifest_digest_amd64 != null then {manifest_digest_amd64: $multi_arch_digests.manifest_digest_amd64} else {} end)
        + (if $multi_arch_digests.manifest_digest_arm64 != null then {manifest_digest_arm64: $multi_arch_digests.manifest_digest_arm64} else {} end)
        + (if ($attestation_id | length) > 0 then {attestation_id: $attestation_id, attestation_url: $attestation_url} else {} end)
        + (if ($build_args | length) > 0 then {build_args: $build_args} else {} end)
        + (if ($sbom_summary | keys | length) > 0 then {sbom_summary: $sbom_summary} else {} end)
        + (if ($sbom_packages | keys | length) > 0 then {sbom_packages: $sbom_packages} else {} end)
        + (if ($changelog | keys | length) > 0 then {changelog: $changelog} else {} end)
        + (if ($build_history | length) > 0 then {build_history: $build_history} else {} end)
        + (if ($trivy_summary | type) == "object" and $trivy_summary.last_scan != null then {trivy_summary: $trivy_summary} else {} end)
        + (if ($extensions | type) == "array" and ($extensions | length) > 0 then {extensions: $extensions} else {} end)
        + (if ($when_to_use | length) > 0 then {when_to_use: $when_to_use} else {} end)'
}

# Build the variants structure for a container as JSON
# Handles both multi-version (postgres) and single-version (terraform) layouts
collect_variants_json() {
    local container="$1" container_dir="$2" current_version="$3" base_image="$4"

    local ver_count
    ver_count=$(version_count "$container_dir")

    if [[ "$ver_count" -gt 0 ]]; then
        # Multi-version: {has_variants: true, versions: [{tag, base_tag, variants: [...]}]}
        local versions_json="[]"
        while IFS= read -r ver_tag; do
            [[ -z "$ver_tag" ]] && continue
            local base_tag
            base_tag=$(variant_image_tag "$ver_tag" "base" "$container_dir")

            local variants_arr="[]"
            while IFS= read -r variant_name; do
                [[ -z "$variant_name" ]] && continue
                local var_json
                var_json=$(collect_variant_json "$container" "$container_dir" "$variant_name" \
                    "$ver_tag" "$current_version" "$base_image" "true")
                variants_arr=$(printf '%s\n%s' "$variants_arr" "$var_json" | jq -s '.[0] + [.[1]]')
            done < <(list_variants "$container_dir" "$ver_tag")

            # Versions-only container (no per-version variants array, e.g. sslh,
            # jekyll, openvpn): synthesize a single canonical variant from the
            # version itself so trust-strip plumbing in container-card.html
            # (which dereferences default_variant.trivy_summary etc.) has data
            # to read. Without this, default_variant falls back to `include`
            # and the trust strip silently shows no badges. Affects ~70% of
            # the catalog. The synthetic variant has empty `name`; the Liquid
            # template hides the visible `:name` label when name is empty.
            #
            # Gate strictly on exact-tag lineage existence — `resolve_variant_lineage_file`
            # falls back to the legacy single-file format when per-tag lineage
            # is missing, which would surface a stale digest/attestation from
            # a different version's build (e.g. v2.3.0 fallback bleeding into
            # v2.3.1's trust strip). We'd rather show no badge than the wrong
            # one. Older retained versions without a recent build will have
            # empty trust strips until rebuilt — acceptable degradation.
            if [[ "$variants_arr" == "[]" ]] \
                && [[ -f "$SCRIPT_DIR/.build-lineage/${container}-${ver_tag}.json" ]]; then
                local var_json
                var_json=$(collect_variant_json "$container" "$container_dir" "" \
                    "$ver_tag" "$current_version" "$base_image" "true")
                variants_arr=$(printf '%s\n%s' "[]" "$var_json" | jq -s '.[0] + [.[1]]')
            fi

            local ver_json
            ver_json=$(printf '%s' "$variants_arr" | jq \
                --arg tag "$ver_tag" --arg base_tag "$base_tag" \
                '{tag: $tag, base_tag: $base_tag, variants: .}')
            versions_json=$(printf '%s\n%s' "$versions_json" "$ver_json" | jq -s '.[0] + [.[1]]')
        done < <(list_versions "$container_dir")

        printf '%s' "$versions_json" | jq \
            '{has_variants: true, versions: .}'
    else
        # Single-version: {has_variants: true, variants: [...]}
        local variants_arr="[]"
        while IFS= read -r variant_name; do
            [[ -z "$variant_name" ]] && continue
            local var_json
            var_json=$(collect_variant_json "$container" "$container_dir" "$variant_name" \
                "$current_version" "$current_version" "$base_image" "false")
            variants_arr=$(printf '%s\n%s' "$variants_arr" "$var_json" | jq -s '.[0] + [.[1]]')
        done < <(list_variants "$container_dir")

        printf '%s' "$variants_arr" | jq \
            '{has_variants: true, variants: .}'
    fi
}

# --- Dependency monitoring helpers ---

# Build dependency monitoring JSON for a container's front matter
# Reads dependency_sources from config.yaml and produces a static summary
# (no network calls — just config introspection)
# T16/AC-20: includes lifecycle counts and per-entry badges
build_dependency_monitoring_json() {
    local container="$1"
    local dep_config="$2"

    local deps_json="[]"
    local total=0
    local monitored=0
    local disabled=0
    # Lifecycle counts (AC-20)
    local lc_tracked=0
    local lc_stable_pin=0
    local lc_eol_migrate=0
    local lc_untracked=0

    # Named constant for EOL countdown — matches check-dependency-versions.sh
    local STABLE_PIN_WARN_DAYS="${STABLE_PIN_WARN_DAYS:-90}"

    # Read all dependency_sources keys
    local dep_names
    dep_names=$(yq -r '.dependency_sources // {} | keys | .[]' "$dep_config" 2>/dev/null) || return

    while IFS= read -r dep_name; do
        [[ -z "$dep_name" ]] && continue
        total=$((total + 1))

        # P1-SECURITY: dep_name comes from yq .dependency_sources keys — a PR author
        # controls config.yaml key names. Never interpolate ${dep_name} into the yq
        # query expression. Pass via env-var + strenv() so yq treats it as a literal.
        # Read lifecycle field (required; backward-compat: empty defaults to "tracked")
        local lifecycle
        lifecycle=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].lifecycle // ""' "$dep_config")

        # Increment lifecycle counters
        case "$lifecycle" in
            tracked)      lc_tracked=$((lc_tracked + 1)) ;;
            stable-pin)   lc_stable_pin=$((lc_stable_pin + 1)) ;;
            eol-migrate)  lc_eol_migrate=$((lc_eol_migrate + 1)) ;;
            untracked)    lc_untracked=$((lc_untracked + 1)) ;;
        esac

        # Status assignment is PURELY lifecycle-driven (AC-20).
        # The legacy monitor: boolean is no longer consulted here; lifecycle:
        # is the single source of truth for dashboard classification.
        # Backward-compat: empty lifecycle defaults to "tracked" (transition period).
        local effective_lifecycle="${lifecycle:-tracked}"

        case "$effective_lifecycle" in
            untracked|eol-migrate)
                disabled=$((disabled + 1))
                local reason
                reason=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].reason // ""' "$dep_config")
                local entry_badge=""
                [[ "$effective_lifecycle" == "eol-migrate" ]] && entry_badge="needs-migration"
                deps_json=$(echo "$deps_json" | jq \
                    --arg name "$dep_name" \
                    --arg status "$effective_lifecycle" \
                    --arg lc "$effective_lifecycle" \
                    --arg reason "$reason" \
                    --arg badge "$entry_badge" \
                    '. + [{"name": $name, "status": $status, "lifecycle": $lc, "reason": $reason, "badge": $badge}]')
                ;;
            stable-pin|tracked)
                monitored=$((monitored + 1))
                local dep_type current_version source_ref
                dep_type=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].type // ""' "$dep_config")
                current_version=$(YQ_DEP="$dep_name" yq -r '.build_args[strenv(YQ_DEP)] // ""' "$dep_config")
                # Fallback: check extensions/config.yaml for postgres-style extensions
                if [[ -z "$current_version" ]]; then
                    local ext_config
                    ext_config="$(dirname "$dep_config")/extensions/config.yaml"
                    if [[ -f "$ext_config" ]]; then
                        current_version=$(YQ_DEP="$dep_name" yq -r '.extensions[strenv(YQ_DEP)].version // ""' "$ext_config")
                    fi
                fi

                # Build source reference for display
                case "$dep_type" in
                    github-release|github-tag)
                        source_ref=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].repo // ""' "$dep_config")
                        ;;
                    pypi)
                        source_ref=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].package // ""' "$dep_config")
                        ;;
                    *) source_ref="" ;;
                esac

                # Compute per-entry badge for stable-pin date escalation (AC-20)
                local badge=""
                if [[ "$effective_lifecycle" == "stable-pin" ]]; then
                    local supported_until
                    supported_until=$(YQ_DEP="$dep_name" yq -r '.dependency_sources[strenv(YQ_DEP)].supported_until // ""' "$dep_config")
                    if [[ -n "$supported_until" && "$supported_until" != "null" ]]; then
                        local today_epoch until_epoch days_left
                        today_epoch=$(date +%s)
                        until_epoch=$(date -d "$supported_until" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$supported_until" +%s 2>/dev/null || echo "0")
                        days_left=$(( (until_epoch - today_epoch) / 86400 ))
                        if [[ "$days_left" -le 0 ]]; then
                            badge="eol-passed"
                        elif [[ "$days_left" -le "$STABLE_PIN_WARN_DAYS" ]]; then
                            badge="eol-approaching"
                        fi
                    fi
                fi

                deps_json=$(echo "$deps_json" | jq \
                    --arg name "$dep_name" \
                    --arg status "monitored" \
                    --arg lc "$effective_lifecycle" \
                    --arg type "$dep_type" \
                    --arg current "$current_version" \
                    --arg source "$source_ref" \
                    --arg badge "$badge" \
                    '. + [{"name": $name, "status": "monitored", "lifecycle": $lc, "type": $type, "current": $current, "source": $source, "badge": $badge}]')
                ;;
        esac
    done <<< "$dep_names"

    jq -n \
        --argjson total "$total" \
        --argjson monitored "$monitored" \
        --argjson disabled "$disabled" \
        --argjson lc_tracked "$lc_tracked" \
        --argjson lc_stable_pin "$lc_stable_pin" \
        --argjson lc_eol_migrate "$lc_eol_migrate" \
        --argjson lc_untracked "$lc_untracked" \
        --argjson deps "$deps_json" \
        '{enabled: true, total: $total, monitored: $monitored, disabled: $disabled,
          lifecycle_counts: {tracked: $lc_tracked, "stable-pin": $lc_stable_pin,
            "eol-migrate": $lc_eol_migrate, untracked: $lc_untracked},
          deps: $deps}'
}

# --- Output functions ---

# Generate a Jekyll collection page for a container
# Takes a JSON object and writes YAML front matter via yq
generate_container_page() {
    local container="$1"
    local container_json="$2"
    local page_file="$CONTAINERS_DIR/${container}.md"

    # Add layout field and convert JSON to YAML front matter
    echo "---" > "$page_file"
    echo "$container_json" | jq '{layout: "container-detail"} + .' | yq -P >> "$page_file"
    echo "---" >> "$page_file"

    # Append README content (strip front matter if present)
    if [[ -f "$container/README.md" ]]; then
        awk '
            BEGIN { in_fm = 0; fm_done = 0 }
            NR == 1 && /^---$/ { in_fm = 1; next }
            in_fm && /^---$/ { in_fm = 0; fm_done = 1; next }
            in_fm { next }
            { print }
        ' "$container/README.md" >> "$page_file"
    else
        echo "" >> "$page_file"
        echo "No README available for this container." >> "$page_file"
    fi
}

# --- Registry wrappers ---
# Thin wrappers over helpers/registry-utils.sh
# Preserves dashboard-specific calling conventions and output formats

# Get Docker Hub stats (pulls and stars)
# Usage: get_dockerhub_stats <user> <repo>
# Output: "pulls:N stars:M"
get_dockerhub_stats() {
    dockerhub_get_repo_stats "$@"
}

# Legacy wrapper for backward compatibility
get_dockerhub_pulls() {
    local stats
    stats=$(get_dockerhub_stats "$1" "$2")
    echo "$stats" | grep -oP 'pulls:\K[0-9]+'
}

# Format number with K/M suffix
format_number() {
    local num=$1
    if [[ $num -ge 1000000 ]]; then
        printf "%.1fM" "$(echo "scale=1; $num/1000000" | bc)"
    elif [[ $num -ge 1000 ]]; then
        printf "%.1fK" "$(echo "scale=1; $num/1000" | bc)"
    else
        echo "$num"
    fi
}

# Get GHCR image sizes formatted for dashboard (MB suffix)
# Usage: get_ghcr_sizes <image> [tag]
# Output: "amd64:84.0MB arm64:81.5MB"
get_ghcr_sizes() {
    local image=${1#ghcr.io/}
    local tag=${2:-latest}
    local sizes_output=""

    local _t0_ghcr_sz=${EPOCHREALTIME:-}
    local raw_sizes
    raw_sizes=$(ghcr_get_manifest_sizes "$image" "$tag") || { log_latency "ghcr-index ${image}:${tag}" "$_t0_ghcr_sz" 30; return 1; }
    log_latency "ghcr-index ${image}:${tag}" "$_t0_ghcr_sz" 30

    while IFS=':' read -r arch bytes; do
        [[ -z "$arch" || -z "$bytes" ]] && continue
        if [[ "$bytes" -gt 0 ]] 2>/dev/null; then
            local size_mb
            size_mb=$(echo "scale=1; $bytes/1048576" | bc)
            sizes_output+="${arch}:${size_mb}MB "
        fi
    done <<< "$raw_sizes"

    echo "${sizes_output% }"
}

# --- GitHub API helper ---

# Fetch from GitHub API with gh CLI (authenticated) or curl fallback
# Usage: github_api_get "endpoint" [max_time]
github_api_get() {
    local endpoint="$1"
    local max_time="${2:-15}"

    local _t0=${EPOCHREALTIME:-}
    local _rc=0
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        gh api "$endpoint" 2>/dev/null || _rc=$?
    else
        curl -s --max-time "$max_time" \
            "https://api.github.com/$endpoint" 2>/dev/null || _rc=$?
    fi
    log_latency "gh-api ${endpoint%%\?*}" "$_t0" 30
    return $_rc
}

# --- Stats calculation functions ---

# Calculate build success rate from auto-build workflow jobs (last 30 days)
# Only counts jobs that start with "Build" to exclude detection, manifest, etc.
# Output: "success_count:total_count:rate_percent"
calculate_build_success_rate() {
    local build_success=0 build_total=0 build_success_rate=0
    local thirty_days_ago
    thirty_days_ago=$(date -u -d "30 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-30d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

    local build_runs_json
    build_runs_json=$(github_api_get "repos/oorabona/docker-containers/actions/workflows/auto-build.yaml/runs?per_page=20&created=>$thirty_days_ago" 30 || true)

    if [[ -n "$build_runs_json" ]] && echo "$build_runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        local run_ids
        run_ids=$(echo "$build_runs_json" | jq -r '.workflow_runs[] | select(.status == "completed") | .id' 2>/dev/null)

        for run_id in $run_ids; do
            local jobs_json
            jobs_json=$(github_api_get "repos/oorabona/docker-containers/actions/runs/$run_id/jobs?per_page=50" 10 || true)

            if [[ -n "$jobs_json" ]] && echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
                local run_build_total run_build_success
                run_build_total=$(echo "$jobs_json" | jq '[.jobs[] | select(.name | startswith("Build")) | select(.status == "completed" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
                run_build_success=$(echo "$jobs_json" | jq '[.jobs[] | select(.name | startswith("Build")) | select(.status == "completed" and .conclusion == "success")] | length' 2>/dev/null || echo "0")

                build_total=$((build_total + run_build_total))
                build_success=$((build_success + run_build_success))
            fi
        done

        [[ $build_total -gt 0 ]] && build_success_rate=$(( (build_success * 100) / build_total ))
    fi

    echo "${build_success}:${build_total}:${build_success_rate}"
}

# Global cache for per-container build status (populated once, used by get_container_build_status)
# Format: JSON object {"container_name": "status", ...} where status is success/failure/cancelled/pending
declare -g CONTAINER_BUILD_STATUS_CACHE=""

# Populate per-container build status cache from GitHub API
# Queries the most recent auto-build workflow run to get actual CI status per container
populate_container_build_status_cache() {
    log_info "Fetching per-container build status from GitHub Actions..."

    # Get the most recent completed auto-build run
    # `|| true` shields against transient GitHub API failures (502/rate-limit/network).
    # The defensive `[[ -z "$runs_json" ]] || ...` check below handles empty output gracefully;
    # without `|| true`, `set -e` propagates the non-zero exit and kills the script silently.
    local runs_json
    runs_json=$(github_api_get "repos/oorabona/docker-containers/actions/workflows/auto-build.yaml/runs?per_page=5&status=completed" 15 || true)

    if [[ -z "$runs_json" ]] || ! echo "$runs_json" | jq -e '.workflow_runs[0]' >/dev/null 2>&1; then
        log_warning "Could not fetch workflow runs, using lineage-based status"
        CONTAINER_BUILD_STATUS_CACHE="{}"
        return
    fi

    # Get the most recent run ID
    local run_id
    run_id=$(echo "$runs_json" | jq -r '.workflow_runs[0].id' 2>/dev/null)

    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        CONTAINER_BUILD_STATUS_CACHE="{}"
        return
    fi

    # Get all jobs from this run
    local jobs_json
    jobs_json=$(github_api_get "repos/oorabona/docker-containers/actions/runs/$run_id/jobs?per_page=100" 20 || true)

    if [[ -z "$jobs_json" ]] || ! echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
        CONTAINER_BUILD_STATUS_CACHE="{}"
        return
    fi

    # Build the cache: extract container name from job names
    # Format: "Build <container>:<variant> (<arch>)" or "Build <container> (<arch>)"
    # Group by container, take the worst status if multiple variants
    CONTAINER_BUILD_STATUS_CACHE=$(echo "$jobs_json" | jq '
        [.jobs[] |
            select(.name | test("^Build [a-z]")) |
            {
                container: (.name | sub("^Build "; "") | split(":")[0] | split(" ")[0]),
                conclusion: .conclusion
            }
        ] |
        group_by(.container) |
        map({
            key: .[0].container,
            value: (
                if any(.[]; .conclusion == "failure") then "failure"
                elif any(.[]; .conclusion == "cancelled") then "cancelled"
                elif all(.[]; .conclusion == "success") then "success"
                elif any(.[]; .conclusion == "skipped") then "skipped"
                else "pending"
                end
            )
        }) |
        from_entries
    ' 2>/dev/null || echo "{}")

    local count
    count=$(echo "$CONTAINER_BUILD_STATUS_CACHE" | jq 'length' 2>/dev/null || echo "0")
    log_info "Cached build status for $count containers from run #$run_id"
}

# Get the CI build status for a specific container
# Returns: success/failure/cancelled/pending/unknown
get_container_build_status() {
    local container="$1"

    # Populate cache on first call
    if [[ -z "$CONTAINER_BUILD_STATUS_CACHE" ]]; then
        populate_container_build_status_cache
    fi

    local status
    status=$(echo "$CONTAINER_BUILD_STATUS_CACHE" | jq -r --arg c "$container" '.[$c] // "unknown"' 2>/dev/null)

    echo "${status:-unknown}"
}

# Fetch recent workflow runs for activity display
# Output: YAML fragment for recent_activity
fetch_recent_activity() {
    local runs_json activity_yaml=""
    runs_json=$(github_api_get "repos/oorabona/docker-containers/actions/runs?per_page=5&status=completed" || true)

    if [[ -n "$runs_json" ]] && echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        activity_yaml="recent_activity:"
        while IFS= read -r run_line; do
            [[ -z "$run_line" ]] && continue
            local run_name run_conclusion run_date run_url
            run_name=$(echo "$run_line" | cut -d'|' -f1)
            run_conclusion=$(echo "$run_line" | cut -d'|' -f2)
            run_date=$(echo "$run_line" | cut -d'|' -f3)
            run_url=$(echo "$run_line" | cut -d'|' -f4)

            local formatted_date
            formatted_date=$(date -d "$run_date" +"%b %d, %H:%M" 2>/dev/null || echo "$run_date")

            activity_yaml+="
  - name: \"$(yaml_escape "$run_name")\"
    conclusion: \"$run_conclusion\"
    date: \"$formatted_date\"
    url: \"$run_url\""
        done < <(echo "$runs_json" | jq -r '.workflow_runs[] | "\(.display_title)|\(.conclusion)|\(.created_at)|\(.html_url)"' 2>/dev/null)
    else
        activity_yaml="recent_activity: []"
    fi

    echo "$activity_yaml"
}

# Write dashboard stats YAML file
# Args: total up_to_date updates_available build_success build_total build_success_rate activity_yaml
write_stats_file() {
    local total="$1" up_to_date="$2" updates_available="$3"
    local build_success="$4" build_total="$5" build_success_rate="$6"
    local activity_yaml="$7"

    cat > "$STATS_FILE" << EOF
# Auto-generated dashboard statistics
# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

total_containers: $total
up_to_date: $up_to_date
updates_available: $updates_available
build_success_rate: $build_success_rate
build_success_count: $build_success
build_total_count: $build_total
last_updated: "$(date -u +"%Y-%m-%d %H:%M UTC")"

$activity_yaml
EOF
}

# --- Main function ---

generate_data() {
    log_info "Generating Jekyll data files..."

    # --- Profiling instrumentation (DASHBOARD_PROFILE gate) ---
    # Default OFF — zero behavior change when unset/empty.
    # All telemetry goes to $PROF temp dir + stderr.  Stdout fidelity is
    # preserved: shims pass through exit-code and stdout unchanged.
    # Shims use `command curl/jq/yq` to avoid infinite recursion.
    local _PROF_ENABLED=0
    local PROF=""
    if [[ -n "${DASHBOARD_PROFILE:-}" ]]; then
        _PROF_ENABLED=1
        PROF="${TMPDIR:-/tmp}/dash-prof-$$"
        ( umask 077; mkdir -p "$PROF" ) 2>/dev/null || true

        # --- curl shim ---
        # Classifies by URL, records elapsed + class to $PROF/curl.log.
        # Stdout/stderr/exit-code of the real curl are passed through unchanged.
        # set -e safety: `command curl "$@" || _rc=$?` — the left side of ||
        # is exempt from set -e abort; rc is captured regardless of success/failure.
        # A stalled curl (exit 28, --max-time hit) records a ge9-bucket entry —
        # that is the H2 (latency-bound) discriminator and MUST be recorded.
        # Telemetry write guarded by [ -n "${PROF:-}" ] so an unset/empty PROF
        # is a clean no-op rather than a set -u fatal expansion.
        curl() {
            local _t0 _t1 _rc _elapsed _class _url _arg
            _rc=0
            _t0=$(date +%s.%N 2>/dev/null || date +%s)
            command curl "$@" || _rc=$?
            _t1=$(date +%s.%N 2>/dev/null || date +%s)
            # Classify by scanning args for the last https: URL
            _url=""
            for _arg in "$@"; do
                case "$_arg" in https://*) _url="$_arg" ;; esac
            done
            case "$_url" in
                */manifests/sha256:*) _class="perarch"  ;;
                */manifests/*)        _class="indextag" ;;
                */token*)             _class="token"    ;;
                */blobs/*)            _class="blob"     ;;
                *)                    _class="other"    ;;
            esac
            # Compute elapsed with awk (handles both fractional and integer timestamps)
            _elapsed=$(awk "BEGIN{printf \"%.3f\", ${_t1} - ${_t0}}" 2>/dev/null || echo "0")
            [ -n "${PROF:-}" ] && { printf '%s %s\n' "$_class" "$_elapsed" >> "$PROF/curl.log"; } 2>/dev/null || true
            return $_rc
        }

        # --- jq shim (count only — no per-call date; thousands of calls) ---
        # set -e safety: `command jq "$@" || _rc=$?` — non-zero exit (e.g. from
        # `jq -e` boolean tests that return 1) is captured, not aborted.
        # This ensures jq -e "false-path" calls are counted — critical for H3.
        jq() {
            local _rc=0
            command jq "$@" || _rc=$?
            [ -n "${PROF:-}" ] && { printf 'x' >> "$PROF/jq.count"; } 2>/dev/null || true
            return $_rc
        }

        # --- yq shim (count only) ---
        # set -e safety: same || _rc=$? idiom.
        yq() {
            local _rc=0
            command yq "$@" || _rc=$?
            [ -n "${PROF:-}" ] && { printf 'x' >> "$PROF/yq.count"; } 2>/dev/null || true
            return $_rc
        }

        # NO export -f: registry-utils.sh is sourced into this same shell —
        # function shadowing works without export.  NOT exporting intentionally
        # prevents shim leakage into child version.sh processes: those run under
        # their own set -euo pipefail and do not have $PROF exported, so a leaked
        # shim would hit an unbound-variable abort on "$PROF/..." expansion.
        # Child version.sh cost (~1 upstream curl/container) is captured by the
        # per-container phase timer, not the curl/jq shims (which target the ~150
        # manifest fetches inside registry-utils, all in-process).
    else
        # Disabled path: actively remove any shims left from a prior enabled call
        # in the same shell, restoring the real binaries.  This makes the invariant
        # literally true: disabled ⇒ no curl/jq/yq shell functions, zero overhead.
        unset -f curl jq yq 2>/dev/null || true
    fi

    local _ts_start _ts_loop_start _ts_loop_end _ts_finalize_end
    [[ "$_PROF_ENABLED" -eq 1 ]] && _ts_start=$(date +%s)

    cd "$SCRIPT_DIR"

    # Pre-populate build status cache (once, before the loop)
    populate_container_build_status_cache

    local total=0 up_to_date=0 updates_available=0
    local all_containers_json="[]"

    # Prepare containers collection directory
    mkdir -p "$CONTAINERS_DIR"
    rm -f "$CONTAINERS_DIR"/*.md

    [[ "$_PROF_ENABLED" -eq 1 ]] && _ts_loop_start=$(date +%s)

    for container in */; do
        local _ts_iter_start=0
        [[ "$_PROF_ENABLED" -eq 1 ]] && _ts_iter_start=$(date +%s)

        container=${container%/}

        is_skip_directory "$container" && continue
        [[ -f "$container/version.sh" ]] || continue
        has_dockerfile "$container" || continue

        log_info "Processing $container..."

        local version_info
        version_info=$(get_container_versions "$container")

        IFS='|' read -r current_version latest_version status_color status_text <<< "$version_info"

        local description
        description=$(get_container_description "$container")

        # Get CI build status from GitHub API (cached)
        local build_status
        build_status=$(get_container_build_status "$container")

        # Fallback logic if CI status is unknown
        if [[ "$build_status" == "unknown" ]]; then
            if [[ "$current_version" == "no-published-version" ]]; then
                build_status="pending"
            else
                build_status="success"  # Assume success if published but no recent CI data
            fi
        fi

        total=$((total + 1))
        case "$status_color" in
            "green") up_to_date=$((up_to_date + 1)) ;;
            "warning") updates_available=$((updates_available + 1)) ;;
        esac

        # Get Docker Hub stats (pulls and stars)
        local dockerhub_stats pull_count pull_count_formatted star_count
        dockerhub_stats=$(get_dockerhub_stats "oorabona" "$container")
        pull_count=$(echo "$dockerhub_stats" | grep -oP 'pulls:\K[0-9]+')
        star_count=$(echo "$dockerhub_stats" | grep -oP 'stars:\K[0-9]+')
        pull_count_formatted=$(format_number "$pull_count")

        # Get image sizes (only if published)
        local sizes_amd64="" sizes_arm64=""
        if [[ "$current_version" != "no-published-version" ]]; then
            local sizes_raw
            sizes_raw=$(get_ghcr_sizes "oorabona/$container" 2>/dev/null) || true
            if [[ -n "$sizes_raw" ]]; then
                sizes_amd64=$(echo "$sizes_raw" | grep -oP 'amd64:\K[0-9.]+MB' || echo "")
                sizes_arm64=$(echo "$sizes_raw" | grep -oP 'arm64:\K[0-9.]+MB' || echo "")
            fi
        fi

        # Build container JSON with all metadata
        local build_digest base_image
        build_digest=$(get_build_lineage_field "$container" "build_digest")
        base_image=$(get_build_lineage_field "$container" "base_image_ref")

        local container_json
        container_json=$(
            NAME="$container" \
            CV="$current_version" LV="$latest_version" \
            SC="$status_color" ST="$status_text" BS="$build_status" \
            DESC="$description" \
            GHCR="ghcr.io/oorabona/$container:$current_version" \
            DH="docker.io/oorabona/$container:$current_version" \
            BD="$build_digest" BI="$base_image" \
            PC="$pull_count" PCF="$pull_count_formatted" SC2="$star_count" \
            SA="$sizes_amd64" SR="$sizes_arm64" \
            yq -n -o json '
                .name = strenv(NAME) |
                .current_version = strenv(CV) | .latest_version = strenv(LV) |
                .status_color = strenv(SC) | .status_text = strenv(ST) | .build_status = strenv(BS) |
                .description = strenv(DESC) |
                .ghcr_image = strenv(GHCR) | .dockerhub_image = strenv(DH) |
                .build_digest = strenv(BD) | .base_image = strenv(BI) |
                .github_username = "oorabona" | .dockerhub_username = "oorabona" |
                .pull_count = strenv(PC) | .pull_count_formatted = strenv(PCF) | .star_count = strenv(SC2) |
                .size_amd64 = strenv(SA) | .size_arm64 = strenv(SR)
            ')

        # Add container-level build args from lineage
        local lineage_args_json
        lineage_args_json=$(get_build_lineage_args_json "$container")
        if [[ "$lineage_args_json" != "[]" && -n "$lineage_args_json" ]]; then
            container_json=$(echo "$container_json" | jq --argjson ba "$lineage_args_json" '. + {build_args: $ba}')
        fi

        # Add builtin_extensions from config.yaml (if present)
        local ext_config="./$container/extensions/config.yaml"
        if [[ -f "$ext_config" ]]; then
            local builtin_json
            builtin_json=$(yq -o json '.builtin_extensions // []' "$ext_config" 2>/dev/null)
            if [[ "$builtin_json" != "[]" && -n "$builtin_json" ]]; then
                container_json=$(echo "$container_json" | jq --argjson be "$builtin_json" '. + {builtin_extensions: $be}')
            fi
        fi

        # Add dependency monitoring info from config.yaml (if present)
        local dep_config="./$container/config.yaml"
        if [[ -f "$dep_config" ]] && yq -e '.dependency_sources' "$dep_config" &>/dev/null; then
            local dep_monitoring_json
            dep_monitoring_json=$(build_dependency_monitoring_json "$container" "$dep_config")
            if [[ -n "$dep_monitoring_json" && "$dep_monitoring_json" != "null" ]]; then
                container_json=$(echo "$container_json" | jq --argjson dm "$dep_monitoring_json" '. + {dependency_monitoring: $dm}')
            fi
        fi

        # Add value_proposition from config.yaml (if present)
        if [[ -f "./$container/config.yaml" ]]; then
            local value_proposition
            value_proposition=$(yq -r '.value_proposition // ""' "./$container/config.yaml" 2>/dev/null || echo "")
            if [[ -n "$value_proposition" ]]; then
                container_json=$(VP="$value_proposition" \
                    jq -n --argjson base "$container_json" \
                    '$base + {value_proposition: env.VP}')
            fi
        fi

        # Add upstream_monitor_url (constant — links to the upstream-monitor workflow)
        container_json=$(echo "$container_json" | jq \
            '. + {upstream_monitor_url: "https://github.com/oorabona/docker-containers/actions/workflows/upstream-monitor.yaml"}')

        # Add variants (collected once, used for both page and containers.yml)
        local container_dir="./$container"
        if has_variants "$container_dir"; then
            local variants_data
            variants_data=$(collect_variants_json "$container" "$container_dir" "$current_version" "$base_image")
            # Multi-variant: per-variant digests are in variants_data, clear container-level digest
            container_json=$(printf '%s\n%s' "$container_json" "$variants_data" | jq -s '.[0] + .[1] | .build_digest = "per-variant"')

            # Check for variants with missing lineage (build_digest == "unknown")
            # If any variant is missing, downgrade container build_status to "warning"
            local unknown_count
            unknown_count=$(echo "$variants_data" | jq '[
                .. | objects | select(.build_digest? == "unknown")
            ] | length')
            if [[ "$unknown_count" -gt 0 && "$build_status" == "success" ]]; then
                build_status="warning"
                container_json=$(echo "$container_json" | jq --arg bs "$build_status" '.build_status = $bs')
            fi
        else
            container_json=$(echo "$container_json" | jq '. + {has_variants: false}')

            # Collect SBOM data for non-variant containers (stored at container level)
            local sbom_summary sbom_packages changelog build_history
            sbom_summary=$(get_sbom_summary "$container" "$current_version")
            sbom_packages=$(get_sbom_packages "$container" "$current_version")
            changelog=$(get_changelog "$container" "$current_version")
            build_history=$(get_build_history "$container" "$current_version")

            # Trust-strip data for non-variant containers (mirror variant emission).
            # Without these fields, the dashboard renders no SBOM badge / Trivy state /
            # attestation link for vector, web-shell, wordpress, and any future
            # non-variant container. The variant code path (collect_variant_json)
            # already emits these via get_attestation_id / get_trivy_summary — mirror
            # that logic here using current_version as the tag.
            local subject_digest="" attestation_id="" attestation_url=""
            local trivy_category trivy_summary
            local lineage_file
            lineage_file=$(resolve_variant_lineage_file "$container" "$current_version" 2>/dev/null || echo "")
            if [[ -n "$lineage_file" && -f "$lineage_file" ]]; then
                subject_digest=$(jq -r '.oci_subject_digest // empty' "$lineage_file" 2>/dev/null || true)
                if [[ -z "$subject_digest" ]]; then
                    subject_digest=$(jq -r '.build_digest // ""' "$lineage_file" 2>/dev/null || true)
                    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                        echo "[debug] non-variant: using fallback build_digest=$subject_digest for $container-$current_version" >&2
                fi
            fi
            local _t0_att=${EPOCHREALTIME:-}
            if [[ -n "$subject_digest" && "$subject_digest" != "unknown" ]] \
                && attestation_id=$(get_attestation_id "$subject_digest"); then
                attestation_url=$(get_attestation_url "$attestation_id")
            fi
            log_latency "gh-attestation" "$_t0_att" 20
            trivy_category=$(build_trivy_category "$container" "$current_version" "linux/amd64")
            trivy_summary=$(get_trivy_summary "$trivy_category" || echo "{}")
            [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                echo "[debug] non-variant: trivy_summary for $container-$current_version = ${trivy_summary:0:60}…" >&2

            # Pipe large SBOM + trust-strip data via stdin to avoid ARG_MAX limits
            container_json=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
                "$container_json" "$sbom_summary" "$sbom_packages" "$changelog" "$build_history" \
                "$trivy_summary" | \
                jq -s --arg attestation_id "$attestation_id" \
                       --arg attestation_url "$attestation_url" '
                .[0] as $base |
                .[1] as $sbom_summary |
                .[2] as $sbom_packages |
                .[3] as $changelog |
                .[4] as $build_history |
                .[5] as $trivy_summary |
                $base
                + (if ($sbom_summary | keys | length) > 0 then {sbom_summary: $sbom_summary} else {} end)
                + (if ($sbom_packages | keys | length) > 0 then {sbom_packages: $sbom_packages} else {} end)
                + (if ($changelog | keys | length) > 0 then {changelog: $changelog} else {} end)
                + (if ($build_history | length) > 0 then {build_history: $build_history} else {} end)
                + (if ($attestation_id | length) > 0 then {attestation_id: $attestation_id, attestation_url: $attestation_url} else {} end)
                + (if ($trivy_summary | type) == "object" and $trivy_summary.last_scan != null then {trivy_summary: $trivy_summary} else {} end)
                ')
        fi

        # Container-level multi_arch_platforms: derived from GHCR manifest for the
        # container's current published tag. Used by non-variant containers and
        # versions-only containers where per-variant platforms are not emitted.
        if [[ "$current_version" != "no-published-version" ]]; then
            local container_arch_list=""
            local container_raw_sizes _t0_ghcr_cv=${EPOCHREALTIME:-}
            container_raw_sizes=$(ghcr_get_manifest_sizes "oorabona/$container" "$current_version" 2>/dev/null) || true
            log_latency "ghcr-index oorabona/${container}:${current_version}" "$_t0_ghcr_cv" 30
            if [[ -n "$container_raw_sizes" ]]; then
                container_arch_list=$(echo "$container_raw_sizes" | awk -F: '{print $1}' | \
                    jq -R . | jq -s '.')
            fi
            if [[ -n "$container_arch_list" && "$container_arch_list" != "[]" ]]; then
                container_json=$(echo "$container_json" | \
                    jq --argjson pl "$container_arch_list" '. + {multi_arch_platforms: $pl}')
            fi
        fi

        # Generate per-container Jekyll page (uses same JSON — no duplication)
        generate_container_page "$container" "$container_json"

        # Accumulate for containers.yml
        all_containers_json=$(printf '%s\n%s' "$all_containers_json" "$container_json" | jq -s '.[0] + [.[1]]')

        # Per-container timing (profiling gate)
        if [[ "$_PROF_ENABLED" -eq 1 ]]; then
            local _ts_iter_end
            _ts_iter_end=$(date +%s)
            local _iter_elapsed=$(( _ts_iter_end - _ts_iter_start ))
            { printf '%s %s\n' "$container" "$_iter_elapsed" >> "$PROF/containers.log"; } 2>/dev/null || true
        fi
    done

    [[ "$_PROF_ENABLED" -eq 1 ]] && _ts_loop_end=$(date +%s)

    # Write containers.yml from accumulated JSON
    {
        echo "# Auto-generated container data"
        echo "# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")"
        echo ""
        echo "$all_containers_json" | yq -P
    } > "$DATA_FILE"

    # Calculate build success rate from auto-build workflow jobs (last 30 days)
    log_info "Calculating build success rate from GitHub Actions build jobs..."
    local build_stats build_success build_total build_success_rate
    build_stats=$(calculate_build_success_rate)
    IFS=':' read -r build_success build_total build_success_rate <<< "$build_stats"
    log_info "Build jobs stats (30 days): $build_success/$build_total successful (${build_success_rate}%)"

    # Fetch recent workflow runs from GitHub API
    log_info "Fetching recent workflow runs..."
    local activity_yaml
    activity_yaml=$(fetch_recent_activity)

    # Write stats file
    write_stats_file "$total" "$up_to_date" "$updates_available" \
        "$build_success" "$build_total" "$build_success_rate" "$activity_yaml"

    log_info "Generated $DATA_FILE with $total containers"
    log_info "Stats: $up_to_date/$total up-to-date, $updates_available updates, build jobs success ${build_success_rate}% ($build_success/$build_total)"

    # --- Profiling summary (emitted to stderr AFTER data file is written) ---
    if [[ "$_PROF_ENABLED" -eq 1 ]]; then
        _ts_finalize_end=$(date +%s)

        # step_wall_s
        local _step_wall=$(( _ts_finalize_end - _ts_start ))

        # phase timings (integer seconds)
        local _setup_s=$(( _ts_loop_start - _ts_start ))
        local _loop_s=$(( _ts_loop_end - _ts_loop_start ))
        local _finalize_s=$(( _ts_finalize_end - _ts_loop_end ))

        # curl stats — parse $PROF/curl.log with awk (avoid jq/yq — they are shimmed)
        local _curl_total_s=0 _curl_n=0
        local _curl_perarch=0 _curl_indextag=0 _curl_token=0 _curl_blob=0 _curl_other=0
        local _curl_lt1=0 _curl_b1_5=0 _curl_b5_9=0 _curl_ge9=0
        if [[ -f "$PROF/curl.log" ]]; then
            eval "$(awk '
                BEGIN { n=0; tot=0; pa=0; it=0; tk=0; bl=0; ot=0; lt1=0; b15=0; b59=0; ge9=0 }
                NF==2 {
                    n++
                    tot += $2
                    if      ($1=="perarch")  pa++
                    else if ($1=="indextag") it++
                    else if ($1=="token")    tk++
                    else if ($1=="blob")     bl++
                    else                     ot++
                    e=$2+0
                    if      (e <  1) lt1++
                    else if (e <  5) b15++
                    else if (e <  9) b59++
                    else             ge9++
                }
                END {
                    printf "_curl_n=%d; _curl_total_s=%.3f; _curl_perarch=%d; _curl_indextag=%d; _curl_token=%d; _curl_blob=%d; _curl_other=%d; _curl_lt1=%d; _curl_b1_5=%d; _curl_b5_9=%d; _curl_ge9=%d\n",
                        n, tot, pa, it, tk, bl, ot, lt1, b15, b59, ge9
                }
            ' "$PROF/curl.log" 2>/dev/null || echo ':')"
        fi

        # fork counts (wc -c on accumulation files)
        local _jq_n=0 _yq_n=0
        if [[ -f "$PROF/jq.count" ]]; then
            _jq_n=$(wc -c < "$PROF/jq.count" 2>/dev/null || echo 0)
        fi
        if [[ -f "$PROF/yq.count" ]]; then
            _yq_n=$(wc -c < "$PROF/yq.count" 2>/dev/null || echo 0)
        fi

        # top-5 slowest containers (awk sort by elapsed desc)
        local _top_containers=""
        if [[ -f "$PROF/containers.log" ]]; then
            _top_containers=$(awk '{print $2, $1}' "$PROF/containers.log" 2>/dev/null | \
                sort -rn | head -5 | awk '{printf "%s=%s ", $2, $1}' 2>/dev/null || echo "")
            _top_containers="${_top_containers% }"
        fi

        # Emit PROFILE block to stderr (stable PROFILE prefix, greppable from gh run view --log)
        {
            printf 'PROFILE step_wall_s=%d\n'       "$_step_wall"
            printf 'PROFILE curl calls=%d total_s=%.3f perarch=%d indextag=%d token=%d blob=%d other=%d\n' \
                "$_curl_n" "$_curl_total_s" "$_curl_perarch" "$_curl_indextag" \
                "$_curl_token" "$_curl_blob" "$_curl_other"
            printf 'PROFILE curl_lat lt1=%d b1_5=%d b5_9=%d ge9=%d\n' \
                "$_curl_lt1" "$_curl_b1_5" "$_curl_b5_9" "$_curl_ge9"
            printf 'PROFILE forks jq_calls=%d yq_calls=%d\n' "$_jq_n" "$_yq_n"
            printf 'PROFILE phase setup_s=%d loop_s=%d finalize_s=%d\n' \
                "$_setup_s" "$_loop_s" "$_finalize_s"
            printf 'PROFILE top_containers %s\n' "${_top_containers:-none}"
            printf 'PROFILE END\n'
        } >&2

        # Clean up temp profiling dir
        rm -rf "$PROF" 2>/dev/null || true
    fi
}

# Only run when executed directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_data
fi
