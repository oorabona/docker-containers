#!/usr/bin/env bash
# Prune GHCR extension image versions that fall OUTSIDE the current resolver window.
#
# Extension images are published as:
#   ghcr.io/<OWNER>/ext-<ext>:pg<major>-<version>
#   ghcr.io/<OWNER>/ext-<ext>:pg<major>-<version>-<arch>
#   e.g.  ghcr.io/oorabona/ext-timescaledb:pg17-2.27.1-amd64
#
# When the retention window advances (floor rises or a PG major reaches EOL),
# tags from previous versions accumulate forever.  This script prunes them.
#
# GHCR deletes package version records, not individual tags.  A single record can
# carry multiple tags, so deletion is decided for the whole record:
#   - delete only when every tag is a managed pg<major>-<version>[-arch] tag
#     and every managed tag is outside that major's resolver window.
#   - keep the record if any tag is retained, unparseable/foreign, or belongs
#     to a major whose resolver window could not be computed.
#
# FAIL-CLOSED by design (deletes registry version records):
#   - DRY-RUN is the DEFAULT.  Pass --execute (or --no-dry-run) to actually delete.
#   - If the window computation is empty/uncertain/errors for (ext, pg_major),
#     tags for that major are treated as KEEP — never delete when the keep-set is unknown.
#   - Every decision (keep / prune / skip) is logged.
#
# Required env vars: GH_TOKEN, OWNER
# Optional env vars:
#   EXT_CONFIG  — path to postgres/extensions/config.yaml (default: auto-detected)
#   PG_VERSIONS — space-separated additional PG major versions (registry majors are always included)
#
# Usage:
#   cleanup-ext-images.sh [--execute | --no-dry-run] [ext_name...]
#   cleanup-ext-images.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Source shared helpers ────────────────────────────────────────────────────
# shellcheck source=helpers/logging.sh
source "${ROOT_DIR}/helpers/logging.sh"

# shellcheck source=helpers/version-set-resolver.sh
source "${ROOT_DIR}/helpers/version-set-resolver.sh"

# ── Internal helpers (testable functions) ────────────────────────────────────

_usage() {
    cat >&2 <<'EOF'
Usage: cleanup-ext-images.sh [OPTIONS] [ext_name...]

Prune GHCR extension image version records whose full tag set falls OUTSIDE the
current resolver retention window.

Options:
  --execute / --no-dry-run   Actually delete version records (default: dry-run)
  --dry-run                  Dry-run mode (default, no deletions)
  --help / -h                Show this help

Arguments:
  ext_name...   Optional: restrict processing to these extensions only.
                Defaults to all extensions with a version_set.resolver.

Environment:
  GH_TOKEN  (required)  GitHub token with packages:write
  OWNER     (required)  GitHub owner/org (e.g. oorabona)
  EXT_CONFIG            Path to postgres/extensions/config.yaml
  PG_VERSIONS           Space-separated additional PG major versions
EOF
}

# All extension names from config that have a version_set.resolver configured.
# Extensions without a resolver only have a single version — their tags are
# managed by the standard cleanup-outdated-tags.sh flow.
_discover_resolver_extensions() {
    local config_file="$1"
    yq -r '
      .extensions
      | to_entries[]
      | select(.value.version_set.resolver != null)
      | .key
    ' "$config_file" 2>/dev/null
}

# Supported PG major versions from config
_discover_pg_versions() {
    local config_file="$1"
    yq -r '.pg_versions[]' "$config_file" 2>/dev/null
}

# List GHCR package version records for an extension package.
# Output: compact JSON array of {version_id,name,tags[]} records.
# Returns 1 on API error so callers can skip fail-closed.
_list_ghcr_ext_version_records() {
    local package_name="$1"   # e.g. ext-timescaledb
    local owner="${OWNER:?OWNER is required}"

    local raw_versions
    raw_versions=$(gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${owner}/packages/container/${package_name}/versions" \
        --paginate 2>/dev/null) || return 1

    if [[ -z "$raw_versions" ]]; then
        printf '[]\n'
        return 0
    fi

    jq -c -s '
      [.[][] | {
        version_id: (.id | tostring),
        name: (.name // ""),
        tags: (.metadata.container.tags // [])
      }]
    ' <<< "$raw_versions"
}

# Discover every pg<major>- prefix present in GHCR version record tags.
_discover_registry_pg_majors() {
    local version_records_json="$1"

    jq -r '
      .[]
      | .tags[]?
      | select(test("^pg[0-9]+-"))
      | capture("^pg(?<major>[0-9]+)-").major
    ' <<< "$version_records_json" | sort -n -u
}

# Delete a GHCR package version record by version id.
_delete_ghcr_ext_version() {
    local package_name="$1"   # e.g. ext-timescaledb
    local version_id="$2"
    local tags_csv="$3"
    local owner="${OWNER:?OWNER is required}"

    if gh api \
        --method DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${owner}/packages/container/${package_name}/versions/${version_id}" 2>/dev/null; then
        log_success "  Deleted ${package_name} version_id=${version_id} (tags: ${tags_csv})"
    else
        log_error "  Failed to delete ${package_name} version_id=${version_id} (tags: ${tags_csv})"
        return 1
    fi
}

# Check whether a version string is present in a JSON array of versions.
# Returns 0 if in window, 1 if not.
_version_in_window() {
    local version="$1"
    local window_json="$2"

    jq -e --arg v "$version" 'any(. == $v)' <<< "$window_json" >/dev/null 2>&1
}

# Parse a managed extension tag.
# Accepts:
#   pg<major>-<numeric.dotted.version>
#   pg<major>-<numeric.dotted.version>-amd64
#   pg<major>-<numeric.dotted.version>-arm64
# Prints: <pg_major>|<version>
# Unknown shapes/suffixes return 1 so callers keep the whole record fail-closed.
_parse_ext_managed_tag() {
    local tag="$1"
    local managed_re='^pg([0-9]+)-([0-9]+([.][0-9]+)*)(-(amd64|arm64))?$'

    [[ "$tag" =~ $managed_re ]] || return 1
    printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Extract the resolver version from a managed extension tag for a specific major.
_derive_ext_tag_window_version() {
    local tag="$1"
    local pg_major="$2"
    local parsed
    local parsed_major
    local version

    parsed=$(_parse_ext_managed_tag "$tag") || return 1
    IFS='|' read -r parsed_major version <<< "$parsed"
    [[ "$parsed_major" == "$pg_major" ]] || return 1
    printf '%s\n' "$version"
}

_version_record_tags_csv() {
    local record_json="$1"

    jq -r '
      (.tags // []) as $tags
      | if ($tags | length) > 0 then ($tags | join(",")) else "(none)" end
    ' <<< "$record_json"
}

# ── Main entry point ─────────────────────────────────────────────────────────

main() {
    : "${GH_TOKEN:?GH_TOKEN is required}"
    : "${OWNER:?OWNER is required}"

    local ext_config="${EXT_CONFIG:-${ROOT_DIR}/postgres/extensions/config.yaml}"
    local dry_run="true"
    local -a ext_filter=()

    # Argument parsing
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --execute|--no-dry-run)
                dry_run="false"
                shift
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --help|-h)
                _usage
                return 0
                ;;
            --)
                shift
                ext_filter+=("$@")
                break
                ;;
            -*)
                log_error "Unknown flag: $1"
                _usage
                return 1
                ;;
            *)
                ext_filter+=("$1")
                shift
                ;;
        esac
    done

    if [[ ! -f "$ext_config" ]]; then
        log_error "Extension config not found: $ext_config"
        return 1
    fi

    # Discover extensions to process
    local -a extensions=()
    if [[ ${#ext_filter[@]} -gt 0 ]]; then
        extensions=("${ext_filter[@]}")
    else
        mapfile -t extensions < <(_discover_resolver_extensions "$ext_config")
    fi

    if [[ ${#extensions[@]} -eq 0 ]]; then
        log_info "No extensions with version_set.resolver found in $ext_config — nothing to do."
        return 0
    fi

    # Configured PG majors are retained for compatibility, but registry-derived
    # majors are authoritative for cleanup coverage.  Retired majors that still
    # have published tags must be considered.
    local -a configured_pg_majors=()
    if [[ -n "${PG_VERSIONS:-}" ]]; then
        # shellcheck disable=SC2206
        configured_pg_majors=($PG_VERSIONS)
    else
        mapfile -t configured_pg_majors < <(_discover_pg_versions "$ext_config")
    fi

    local total_kept=0
    local total_pruned=0
    local total_delete_failures=0
    local total_skipped_pairs=0
    local total_listing_failures=0

    if [[ "$dry_run" == "true" ]]; then
        log_warning "DRY-RUN MODE — no version records will be deleted (pass --execute to delete)"
    else
        log_warning "EXECUTE MODE — version records outside the retention window WILL be deleted"
    fi

    for ext_name in "${extensions[@]}"; do
        local package_name="ext-${ext_name}"
        local version_records_json=""

        echo ""
        echo "========================================"
        log_info "Extension: ${ext_name}  (package: ${package_name})"
        echo "========================================"

        if ! version_records_json=$(_list_ghcr_ext_version_records "$package_name"); then
            log_warning "  GHCR version listing failed for ${package_name} — SKIPPING extension (fail-closed)"
            total_listing_failures=$((total_listing_failures + 1))
            continue
        fi

        local version_record_count
        version_record_count=$(jq 'length' <<< "$version_records_json")
        log_info "  Found ${version_record_count} GHCR version records"

        if [[ "$version_record_count" -eq 0 ]]; then
            log_info "  No GHCR version records found — nothing to prune"
            continue
        fi

        local -a registry_pg_majors=()
        mapfile -t registry_pg_majors < <(_discover_registry_pg_majors "$version_records_json")

        local -A pg_major_seen=()
        local -a pg_majors=()
        local pg_major
        for pg_major in "${configured_pg_majors[@]}" "${registry_pg_majors[@]}"; do
            [[ -n "$pg_major" ]] || continue
            if [[ ! "$pg_major" =~ ^[0-9]+$ ]]; then
                log_warning "  Ignoring invalid PG major: ${pg_major}"
                continue
            fi
            if [[ -z "${pg_major_seen[$pg_major]:-}" ]]; then
                pg_major_seen[$pg_major]=1
                pg_majors+=("$pg_major")
            fi
        done

        if [[ ${#registry_pg_majors[@]} -gt 0 ]]; then
            log_info "  Registry PG majors: ${registry_pg_majors[*]}"
        else
            log_info "  No pg<major>- tags found in registry records"
        fi

        if [[ ${#pg_majors[@]} -eq 0 ]]; then
            log_info "  No PG majors to resolve — nothing to prune"
            continue
        fi

        local -A window_by_major=()
        local -A window_known_by_major=()
        for pg_major in "${pg_majors[@]}"; do
            echo ""
            log_step "  PG major: ${pg_major}"

            # Compute retention window — fail-closed on any error
            local window_json=""
            if ! window_json=$(resolve_version_set "$ext_name" "$pg_major" "$ext_config" 2>/dev/null); then
                log_warning "  Resolver failed for ${ext_name}/pg${pg_major} — SKIPPING (fail-closed)"
                total_skipped_pairs=$((total_skipped_pairs + 1))
                continue
            fi

            if [[ -z "$window_json" ]]; then
                log_warning "  Empty window for ${ext_name}/pg${pg_major} — SKIPPING (fail-closed)"
                total_skipped_pairs=$((total_skipped_pairs + 1))
                continue
            fi

            local window_count
            window_count=$(jq 'if type=="array" and length>0 then length else 0 end' <<< "$window_json" 2>/dev/null || echo "0")
            if [[ "${window_count}" -le 0 ]]; then
                log_warning "  Resolver returned empty/non-array for ${ext_name}/pg${pg_major} — SKIPPING (fail-closed)"
                total_skipped_pairs=$((total_skipped_pairs + 1))
                continue
            fi

            window_json=$(jq -c '.' <<< "$window_json")
            window_by_major[$pg_major]="$window_json"
            window_known_by_major[$pg_major]="true"
            log_info "    Retention window (${window_count} versions): $(jq -r 'join(", ")' <<< "$window_json")"
        done

        local kept_count=0
        local pruned_count=0
        local delete_failures=0
        local record_json

        while IFS= read -r record_json; do
            [[ -n "$record_json" ]] || continue

            local version_id
            local tags_csv
            local tag_count
            version_id=$(jq -r '.version_id' <<< "$record_json")
            tags_csv=$(_version_record_tags_csv "$record_json")
            tag_count=$(jq '(.tags // []) | length' <<< "$record_json")

            local should_delete="true"
            local keep_reason=""

            if [[ "$tag_count" -eq 0 ]]; then
                should_delete="false"
                keep_reason="no tags on version record; fail-closed"
            fi

            local tag
            while [[ "$should_delete" == "true" ]] && IFS= read -r tag; do
                [[ -n "$tag" ]] || continue

                local parsed
                local tag_major
                local tag_version
                if ! parsed=$(_parse_ext_managed_tag "$tag"); then
                    should_delete="false"
                    keep_reason="contains unmanaged/unparseable tag: ${tag}"
                    break
                fi

                IFS='|' read -r tag_major tag_version <<< "$parsed"
                if [[ "${window_known_by_major[$tag_major]:-false}" != "true" ]]; then
                    should_delete="false"
                    keep_reason="window unknown for pg${tag_major}: ${tag}"
                    break
                fi

                if _version_in_window "$tag_version" "${window_by_major[$tag_major]}"; then
                    should_delete="false"
                    keep_reason="contains retained tag: ${tag}"
                    break
                fi
            done < <(jq -r '.tags[]?' <<< "$record_json")

            if [[ "$should_delete" == "true" ]]; then
                log_warning "    ✗ PRUNE version_id=${version_id} (tags: ${tags_csv}) — all managed tags outside window"
                if [[ "$dry_run" == "true" ]]; then
                    log_info "      [DRY-RUN] Would delete ${package_name} version_id=${version_id} (tags: ${tags_csv})"
                    pruned_count=$((pruned_count + 1))
                else
                    if _delete_ghcr_ext_version "$package_name" "$version_id" "$tags_csv"; then
                        pruned_count=$((pruned_count + 1))
                    else
                        delete_failures=$((delete_failures + 1))
                    fi
                fi
            else
                log_info "    ✓ KEEP  version_id=${version_id} (tags: ${tags_csv}) — ${keep_reason}"
                kept_count=$((kept_count + 1))
            fi
        done < <(jq -c '.[]' <<< "$version_records_json")

        log_info "    Summary: kept=${kept_count}, pruned=${pruned_count}, failed=${delete_failures}"
        total_kept=$((total_kept + kept_count))
        total_pruned=$((total_pruned + pruned_count))
        total_delete_failures=$((total_delete_failures + delete_failures))
    done

    echo ""
    echo "========================================"
    echo "Extension image cleanup summary"
    echo "========================================"
    echo "  Version records kept  : ${total_kept}"
    echo "  Version records pruned: ${total_pruned}"
    echo "  Delete failures: ${total_delete_failures}"
    echo "  (ext,major) pairs skipped (uncertain window): ${total_skipped_pairs}"
    echo "  Extensions skipped (listing failed): ${total_listing_failures}"
    if [[ "$dry_run" == "true" ]]; then
        echo "  Mode: DRY-RUN (no deletions performed)"
    else
        echo "  Mode: EXECUTE"
    fi
    echo "========================================"

    if [[ "$dry_run" != "true" && "$total_delete_failures" -gt 0 ]]; then
        return 1
    fi
}

# ── Entry point guard (allows sourcing for tests) ────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
