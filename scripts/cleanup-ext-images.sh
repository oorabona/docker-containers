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
#   - Deletion is authorised by the most recent successful re-read of that exact
#     record. Nothing prevents a writer outside this workflow from changing it
#     between that re-read and DELETE.
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

# shellcheck source=../helpers/collect-lines.sh
source "${ROOT_DIR}/helpers/collect-lines.sh"

# shellcheck source=../helpers/ghcr-package-utils.sh
source "${ROOT_DIR}/helpers/ghcr-package-utils.sh"

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

Deletion guarantee:
  Deletion is authorised by the most recent successful re-read of that exact
  record. Nothing prevents a writer outside this workflow from changing it
  between that re-read and DELETE.

Exit status:
  Returns non-zero if the invocation fails or if any record or coverage could
  not be assessed completely, in both dry-run and execute modes. A non-zero
  dry-run may therefore have made no deletions but is an incomplete audit.
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

# Re-read one GHCR package version record by the same id used by DELETE.  A
# listing is only a snapshot: a publisher may attach a retained tag after the
# listing and before a destructive request is made.
_get_ghcr_ext_version_record() {
    local package_name="$1"   # e.g. ext-timescaledb
    local version_id="$2"
    local owner="${OWNER:?OWNER is required}"

    gh api \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${owner}/packages/container/${package_name}/versions/${version_id}" 2>/dev/null \
        | jq -ce --arg expected_version_id "$version_id" '
          def record_tags:
            (.metadata.container.tags // [])
            | if type == "array" and all(.[]; type == "string") then .
              else error("GHCR version record tags must be an array of strings")
              end;
          {
            version_id: (if .id == null then error("GHCR version record has no id")
                         elif (.id | tostring) != $expected_version_id then error("GHCR version record id does not match requested version id")
                         else (.id | tostring)
                         end),
            tags: record_tags
          }
        '
}

# Check whether a version string is present in a JSON array of versions.
# Returns 0 if in window, 1 if definitely not, and 2 if membership could not
# be computed.  Only the definite-not result may contribute to a deletion.
_version_in_window() {
    local version="$1"
    local window_json="$2"
    local jq_status

    if jq -e --arg v "$version" 'any(. == $v)' <<< "$window_json" >/dev/null 2>&1; then
        return 0
    else
        jq_status=$?
    fi
    [[ "$jq_status" -eq 1 ]] && return 1
    return 2
}

# Validate and normalize a resolver retention window.  The output variables are
# set in the caller's dynamic scope.  Return 0 for valid, 1 for structurally
# invalid, and 2 when validation itself could not be computed.
_retention_window_is_valid() {
    local window_json="$1"
    local validation_result

    validated_window_json=""
    validated_window_count=""
    validated_window_display=""

    if ! validation_result=$(jq -cr '
      if type == "array" and length > 0
         and all(.[]; type == "string" and test("^[0-9]+([.][0-9]+)*$"))
      then { valid: true, window: ., count: length, display: join(", ") }
      else { valid: false }
      end
    ' <<< "$window_json"); then
        return 2
    fi

    local window_is_valid
    if ! window_is_valid=$(jq -r '.valid' <<< "$validation_result"); then
        return 2
    fi
    [[ "$window_is_valid" == "true" ]] || return 1
    if ! validated_window_json=$(jq -ce '.window' <<< "$validation_result"); then
        return 2
    fi
    if ! validated_window_count=$(jq -er '.count' <<< "$validation_result"); then
        return 2
    fi
    if ! validated_window_display=$(jq -er '.display' <<< "$validation_result"); then
        return 2
    fi
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

# Emit all tags from one GHCR version record. The caller collects the complete
# output before making a delete/keep decision: a malformed tag is rejected
# before any tag is emitted, and a successful empty list emits nothing so the
# caller's zero-tag decision remains in effect. This is intentionally a
# newline-delimited transport, so registry tags containing LF or NUL cannot
# round-trip and make the whole record malformed; the caller keeps it
# fail-closed.
_list_version_record_tags() {
    local record_json="$1"

    jq -r '
      (.tags // []) as $tags
      | if ($tags | type) == "array" then
          $tags
          | if all(.[]; type == "string" and (contains("\n") | not) and (contains("\u0000") | not)) then .[] else error("tag cannot be transported safely") end
        else
          error("tag cannot be transported safely")
        end
    ' <<< "$record_json"
}

# Return 0 only when every tag on a record is managed and outside its known
# retention window; return 1 for a definite keep, and 2 when classification
# could not be computed. The two output variables are intentionally set in the
# caller's dynamic scope so the log always names the exact tags assessed.
_record_is_prunable() {
    local record_json="$1"
    local tag_count
    local tags_file
    local tag
    local membership_status

    record_tags_csv="(tag enumeration unavailable)"
    record_keep_reason=""
    if ! tag_count=$(jq -er '(.tags // []) | if type == "array" then length else error("record tags must be an array") end' <<< "$record_json"); then
        record_keep_reason="tag count unknown; keeping record fail-closed"
        return 2
    fi
    if [[ ! "$tag_count" =~ ^[0-9]+$ ]]; then
        record_keep_reason="tag count unknown; keeping record fail-closed"
        return 2
    fi

    if [[ "$tag_count" -eq 0 ]]; then
        if ! record_tags_csv=$(_version_record_tags_csv "$record_json"); then
            record_keep_reason="tag enumeration unknown; keeping record fail-closed"
            return 2
        fi
        record_keep_reason="no tags on version record; fail-closed"
        return 1
    fi

    if ! tags_file=$(mktemp "${TMPDIR:-/tmp}/cleanup-ext-images-record-tags.XXXXXX"); then
        record_keep_reason="tag enumeration unavailable; keeping record fail-closed"
        return 2
    fi
    if ! collect_lines "$tags_file" -- _list_version_record_tags "$record_json"; then
        rm -f "$tags_file" || true
        record_keep_reason="tag enumeration unknown; keeping record fail-closed"
        return 2
    fi

    if ! record_tags_csv=$(_version_record_tags_csv "$record_json"); then
        rm -f "$tags_file" || true
        record_keep_reason="tag enumeration unknown; keeping record fail-closed"
        return 2
    fi
    while IFS= read -r tag; do
        local parsed
        local tag_major
        local tag_version
        if ! parsed=$(_parse_ext_managed_tag "$tag"); then
            rm -f "$tags_file" || true
            printf -v record_keep_reason 'contains unmanaged/unparseable tag: %q' "$tag"
            return 1
        fi

        IFS='|' read -r tag_major tag_version <<< "$parsed"
        if [[ "${window_known_by_major[$tag_major]:-false}" != "true" ]]; then
            rm -f "$tags_file" || true
            record_keep_reason="window unknown for pg${tag_major}: ${tag}"
            return 1
        fi

        if _version_in_window "$tag_version" "${window_by_major[$tag_major]}"; then
            rm -f "$tags_file" || true
            record_keep_reason="contains retained tag: ${tag}"
            return 1
        else
            membership_status=$?
        fi
        if [[ "$membership_status" -eq 2 ]]; then
            rm -f "$tags_file" || true
            record_keep_reason="retention membership unknown for ${tag}; keeping record fail-closed"
            return 2
        fi
    done < "$tags_file"
    if ! rm -f "$tags_file"; then
        record_keep_reason="tag enumeration cleanup failed; keeping record fail-closed"
        return 2
    fi
    return 0
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
        local extensions_file
        extensions_file=$(mktemp "${TMPDIR:-/tmp}/cleanup-ext-images-extensions.XXXXXX") || return 1
        if ! collect_lines "$extensions_file" -- _discover_resolver_extensions "$ext_config"; then
            rm -f "$extensions_file"
            log_error "Could not enumerate resolver extensions; refusing to make pruning decisions"
            return 1
        fi
        mapfile -t extensions < "$extensions_file"
        rm -f "$extensions_file"
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
        local configured_pg_majors_file
        configured_pg_majors_file=$(mktemp "${TMPDIR:-/tmp}/cleanup-ext-images-configured-pg-majors.XXXXXX") || return 1
        if ! collect_lines "$configured_pg_majors_file" -- _discover_pg_versions "$ext_config"; then
            rm -f "$configured_pg_majors_file"
            log_error "Could not enumerate configured PostgreSQL majors; refusing to make pruning decisions"
            return 1
        fi
        mapfile -t configured_pg_majors < "$configured_pg_majors_file"
        rm -f "$configured_pg_majors_file"
    fi

    local total_kept=0
    local total_pruned=0
    local total_delete_failures=0
    local total_skipped_pairs=0
    local total_listing_failures=0
    local total_reread_failures=0
    local total_analysis_failures=0

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
        local registry_pg_majors_file
        registry_pg_majors_file=$(mktemp "${TMPDIR:-/tmp}/cleanup-ext-images-registry-pg-majors.XXXXXX") || return 1
        if ! collect_lines "$registry_pg_majors_file" -- _discover_registry_pg_majors "$version_records_json"; then
            rm -f "$registry_pg_majors_file"
            log_error "Could not enumerate registry PostgreSQL majors; refusing to make pruning decisions"
            return 1
        fi
        mapfile -t registry_pg_majors < "$registry_pg_majors_file"
        rm -f "$registry_pg_majors_file"

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

            local window_validation_status
            if _retention_window_is_valid "$window_json"; then
                window_json="$validated_window_json"
                window_by_major[$pg_major]="$window_json"
                window_known_by_major[$pg_major]="true"
                log_info "    Retention window (${validated_window_count} versions): ${validated_window_display}"
            else
                window_validation_status=$?
                if [[ "$window_validation_status" -eq 1 ]]; then
                    log_warning "  Resolver returned invalid window for ${ext_name}/pg${pg_major} — SKIPPING (fail-closed)"
                else
                    log_warning "  Resolver window validation failed for ${ext_name}/pg${pg_major} — SKIPPING (fail-closed)"
                fi
                total_skipped_pairs=$((total_skipped_pairs + 1))
                continue
            fi
        done

        local kept_count=0
        local pruned_count=0
        local delete_failures=0
        local reread_failures=0
        local analysis_failures=0
        local record_json
        local records_file

        # The record enumeration authorises every deletion below, exactly as the
        # per-record tag enumeration does. Reading it through a process
        # substitution would let a `jq` that emits some records and then fails
        # end the loop successfully — the records it did emit already deleted,
        # the ones it did not never examined, and the summary reporting success.
        # Produce the whole list first, or delete nothing.
        records_file=$(mktemp "${TMPDIR:-/tmp}/cleanup-ext-records.XXXXXX") || return 1
        if ! collect_lines "$records_file" -- jq -c '.[]' <<< "$version_records_json"; then
            rm -f "$records_file"
            log_error "    Version-record enumeration unknown for ${ext_name}; deleting nothing for this extension"
            return 1
        fi

        while IFS= read -r record_json; do
            [[ -n "$record_json" ]] || continue

            local version_id
            version_id=$(jq -r '.version_id' <<< "$record_json")
            local record_tags_csv
            local record_keep_reason

            local record_classification_status
            if _record_is_prunable "$record_json"; then
                if [[ "$dry_run" == "true" ]]; then
                    log_warning "    ✗ PRUNE version_id=${version_id} (tags: ${record_tags_csv}) — all managed tags outside window"
                    log_info "      [DRY-RUN] Would delete ${package_name} version_id=${version_id} (tags: ${record_tags_csv})"
                    pruned_count=$((pruned_count + 1))
                else
                    local current_record_json
                    log_info "    Candidate version_id=${version_id} (tags: ${record_tags_csv}) — re-reading before delete"
                    if ! current_record_json=$(_get_ghcr_ext_version_record "$package_name" "$version_id"); then
                        log_warning "    ✓ KEEP  version_id=${version_id} (tags: ${record_tags_csv}) — re-read before deletion failed; keeping record fail-closed"
                        kept_count=$((kept_count + 1))
                        reread_failures=$((reread_failures + 1))
                    elif _record_is_prunable "$current_record_json"; then
                        log_warning "    ✗ PRUNE version_id=${version_id} (tags: ${record_tags_csv}) — all managed tags outside window"
                        if _delete_ghcr_ext_version "$package_name" "$version_id" "$record_tags_csv"; then
                            pruned_count=$((pruned_count + 1))
                        else
                            delete_failures=$((delete_failures + 1))
                        fi
                    else
                        record_classification_status=$?
                        if [[ "$record_classification_status" -eq 2 ]]; then
                            log_warning "    ✓ KEEP  version_id=${version_id} (tags: ${record_tags_csv}) — re-read before deletion inconclusive: ${record_keep_reason}"
                            analysis_failures=$((analysis_failures + 1))
                        else
                            log_info "    ✓ KEEP  version_id=${version_id} (tags: ${record_tags_csv}) — re-read before deletion: ${record_keep_reason}"
                        fi
                        kept_count=$((kept_count + 1))
                    fi
                fi
            else
                record_classification_status=$?
                if [[ "$record_classification_status" -eq 2 ]]; then
                    log_warning "    ✓ KEEP  version_id=${version_id} (tags: ${record_tags_csv}) — analysis inconclusive: ${record_keep_reason}"
                    analysis_failures=$((analysis_failures + 1))
                else
                    log_info "    ✓ KEEP  version_id=${version_id} (tags: ${record_tags_csv}) — ${record_keep_reason}"
                fi
                kept_count=$((kept_count + 1))
            fi
        done < "$records_file"
        rm -f "$records_file"

        log_info "    Summary: kept=${kept_count}, pruned=${pruned_count}, failed=${delete_failures}"
        total_kept=$((total_kept + kept_count))
        total_pruned=$((total_pruned + pruned_count))
        total_delete_failures=$((total_delete_failures + delete_failures))
        total_reread_failures=$((total_reread_failures + reread_failures))
        total_analysis_failures=$((total_analysis_failures + analysis_failures))
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
    echo "  Candidate records kept (re-read failed): ${total_reread_failures}"
    echo "  Candidate records kept (analysis inconclusive): ${total_analysis_failures}"
    if [[ "$dry_run" == "true" ]]; then
        echo "  Mode: DRY-RUN (no deletions performed)"
    else
        echo "  Mode: EXECUTE"
    fi
    echo "========================================"

    if [[ "$total_delete_failures" -gt 0 || "$total_skipped_pairs" -gt 0 || "$total_listing_failures" -gt 0 || "$total_reread_failures" -gt 0 || "$total_analysis_failures" -gt 0 ]]; then
        return 1
    fi
}

# ── Entry point guard (allows sourcing for tests) ────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
