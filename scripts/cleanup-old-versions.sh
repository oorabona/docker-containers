#!/bin/bash
# Age-based cleanup of GHCR container versions.
#
# Required env vars: GH_TOKEN, OWNER
# Optional env vars: DRY_RUN (default: false), KEEP_LATEST_COUNT (default: 10), KEEP_MONTHS (default: 6)

script_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  cd "$script_dir/.." && pwd
}

print_banner() {
  echo "========================================"
  echo "GHCR Age-Based Cleanup"
  echo "========================================"
  echo "Owner: $OWNER"
  echo "Keep latest count: $KEEP_LATEST_COUNT"
  echo "Keep versions newer than: $CUTOFF_DATE"
  echo "Dry run: $DRY_RUN"
  echo "========================================"
}

# Write kept|deleted|delete_failures to stdout once a package was completely
# assessed.  Its return status, rather than that record, communicates failure:
# 10 listing failure, 11 processing failure, 12 one or more delete failures,
# and 13 a failure after every record was assessed.  Deletion-plan replay is
# execution, not assessment, so a replay failure also returns 13.
purge_container() {
  local container="$1"
  local versions version_count versions_file="" deletions_file=""
  local position=0 kept=0 deleted=0 delete_failures=0
  local version_id tags created_at keep_reason tag tag_list major version_ts cutoff_ts processing_error=0 deletion_read_error=0
  local record_b64 record_json
  declare -A major_seen=()

  if ! versions=$(gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/users/${OWNER}/packages/container/${container}/versions" \
    --paginate); then
    echo "  ✗ Failed to list versions; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi

  if ! versions=$(jq -ce -s '
    select(length > 0)
    | if all(.[]; type == "array") then [.[][]]
      else error("GHCR package-versions response must contain JSON arrays")
      end
  ' <<< "$versions"); then
    echo "  ✗ Version listing was not a JSON array; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi

  if ! version_count=$(jq -er 'length' <<< "$versions"); then
    echo "  ✗ Failed to count versions; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  echo "  Found $version_count versions" >&2
  if [[ "$version_count" -eq 0 ]]; then
    echo "  No versions found (might be new or private)" >&2
    if ! printf '%s\n' "0|0|0"; then
      return "$PROCESSING_FAILURE"
    fi
    return 0
  fi

  if ! cutoff_ts=$(date -d "$CUTOFF_DATE" +%s); then
    echo "  ✗ Failed to parse cutoff date; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if ! versions_file=$(mktemp) || ! deletions_file=$(mktemp); then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to create cleanup work files; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if ! jq -er '.[] | {id: (.id | tostring), tags: (.metadata.container.tags // []), created_at: .created_at} | @base64' \
      <<< "$versions" > "$versions_file"; then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to prepare version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if [[ ! -r "$versions_file" ]]; then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to read version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  # Decide every record before deleting any of them.  A malformed date in a
  # later record must leave earlier obsolete records untouched.
  while IFS= read -r record_b64; do
    [[ -z "$record_b64" ]] && continue
    if ! record_json=$(printf '%s' "$record_b64" | base64 -d) \
      || ! version_id=$(jq -er '.id' <<< "$record_json") \
      || ! tags=$(jq -er '.tags | join(",")' <<< "$record_json") \
      || ! created_at=$(jq -er '.created_at' <<< "$record_json"); then
      echo "  ✗ Failed to read version record; skipping $container" >&2
      processing_error=1
      break
    fi
    position=$((position + 1))
    keep_reason=""

    if grep -q ",latest," <<< ",$tags,"; then
      keep_reason="has 'latest' tag"
    elif [[ "$position" -le "$KEEP_LATEST_COUNT" ]]; then
      keep_reason="in top $KEEP_LATEST_COUNT recent"
    else
      if ! tag_list=$(jq -r '.tags[]' <<< "$record_json"); then
        echo "  ✗ Failed to read version tags; skipping $container" >&2
        processing_error=1
        break
      fi
      while IFS= read -r tag; do
        if [[ "$tag" =~ ^v?([0-9]+)\.[0-9] ]]; then
          major="${BASH_REMATCH[1]}"
          if [[ -z "${major_seen[$major]:-}" ]]; then
            major_seen[$major]=1
            keep_reason="latest of major v$major"
          fi
          break
        fi
      done <<< "$tag_list"
    fi

    if [[ -z "$keep_reason" ]]; then
      if ! version_ts=$(date -d "$created_at" +%s 2>/dev/null); then
        echo "  ✗ Failed to parse version date; skipping $container" >&2
        processing_error=1
        break
      fi
      if [[ "$version_ts" -gt "$cutoff_ts" ]]; then
        keep_reason="newer than $KEEP_MONTHS months"
      fi
    fi

    if [[ -n "$keep_reason" ]]; then
      echo "  ✓ Keep #$position (tags: ${tags:-untagged}) - $keep_reason" >&2
      kept=$((kept + 1))
    elif ! printf '%s|%s\n' "$position" "$record_b64" >> "$deletions_file"; then
      echo "  ✗ Failed to prepare deletion list; skipping $container" >&2
      processing_error=1
      break
    fi
  done < "$versions_file"

  if [[ "$processing_error" -ne 0 ]]; then
    rm -f "$versions_file" "$deletions_file"
    return "$PROCESSING_FAILURE"
  fi

  if ! rm -f "$versions_file"; then
    rm -f "$deletions_file"
    echo "  ✗ Failed to remove version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  while IFS='|' read -r position record_b64; do
    [[ -z "$record_b64" ]] && continue
    if ! record_json=$(printf '%s' "$record_b64" | base64 -d) \
      || ! version_id=$(jq -er '.id' <<< "$record_json") \
      || ! tags=$(jq -er '.tags | join(",")' <<< "$record_json"); then
      echo "  ✗ Failed to read prepared deletion record; skipping $container" >&2
      deletion_read_error=1
      break
    fi
    echo "  ✗ Delete #$position (tags: ${tags:-untagged})" >&2
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [DRY RUN] Would delete version $version_id" >&2
    elif gh api --method DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "/users/${OWNER}/packages/container/${container}/versions/${version_id}"; then
      echo "    ✓ Deleted" >&2
      deleted=$((deleted + 1))
    else
      echo "    ✗ Failed to delete" >&2
      delete_failures=$((delete_failures + 1))
    fi
  done < "$deletions_file"

  if [[ "$deletion_read_error" -ne 0 ]]; then
    if ! printf '%s\n' "$kept|$deleted|$delete_failures"; then
      rm -f "$deletions_file"
      return "$PROCESSING_FAILURE"
    fi
    rm -f "$deletions_file"
    return "$POST_DELETE_PROCESSING_FAILURE"
  fi

  if ! printf '%s\n' "$kept|$deleted|$delete_failures"; then
    return "$PROCESSING_FAILURE"
  fi
  if ! rm -f "$deletions_file"; then
    echo "  ✗ Failed to remove deletion list after cleanup" >&2
    return "$POST_DELETE_PROCESSING_FAILURE"
  fi
  if [[ "$delete_failures" -gt 0 ]]; then
    return "$DELETE_FAILURE"
  fi
}

main() {
  set -euo pipefail

  : "${GH_TOKEN:?GH_TOKEN is required}"
  : "${OWNER:?OWNER is required}"
  : "${DRY_RUN:=false}"
  : "${KEEP_LATEST_COUNT:=10}"
  : "${KEEP_MONTHS:=6}"

  local LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 INCOMPLETE_DELETION_FAILURE=16
  local root_dir containers container result status
  local kept deleted delete_failures
  root_dir=$(script_root) || return 1
  CUTOFF_DATE=$(date -d "-${KEEP_MONTHS} months" +%Y-%m-%dT%H:%M:%SZ) || return 1
  print_banner

  if [[ $# -gt 0 ]]; then
    containers="$*"
  else
    containers=$(find "$root_dir" -maxdepth 2 -name Dockerfile -exec dirname {} \; | sed "s|^$root_dir/||" | sort) || return 1
  fi

  local total_deleted=0 total_kept=0 total_assessed=0
  local total_listing_failures=0 total_processing_failures=0 total_delete_failures=0
  for container in $containers; do
    echo ""
    echo "========================================"
    echo "Processing: $container"
    echo "========================================"

    if result=$(purge_container "$container"); then
      status=0
    else
      status=$?
    fi

    case "$status" in
      0|"$DELETE_FAILURE"|"$POST_DELETE_PROCESSING_FAILURE")
        if ! IFS='|' read -r kept deleted delete_failures <<< "$result"; then
          echo "  ✗ Failed to read cleanup result; skipping $container"
          total_processing_failures=$((total_processing_failures + 1))
          continue
        fi
        total_assessed=$((total_assessed + 1))
        total_kept=$((total_kept + kept))
        total_deleted=$((total_deleted + deleted))
        total_delete_failures=$((total_delete_failures + delete_failures))
        echo "  Summary: kept=$kept, deleted=$deleted, delete_failures=$delete_failures"
        [[ "$status" -ne "$POST_DELETE_PROCESSING_FAILURE" ]] || total_processing_failures=$((total_processing_failures + 1))
        ;;
      "$LISTING_FAILURE") total_listing_failures=$((total_listing_failures + 1)) ;;
      "$PROCESSING_FAILURE") total_processing_failures=$((total_processing_failures + 1)) ;;
      # Reserved: planning is complete before deletion begins, so this script
      # does not produce 16.  Keep it fail-closed for an explicit future
      # partial-assessment producer rather than treating it as execution.
      "$INCOMPLETE_DELETION_FAILURE")
        if ! IFS='|' read -r kept deleted delete_failures <<< "$result"; then
          echo "  ✗ Failed to read incomplete cleanup result; skipping $container"
        else
          total_kept=$((total_kept + kept))
          total_deleted=$((total_deleted + deleted))
          total_delete_failures=$((total_delete_failures + delete_failures))
          echo "  Summary: kept=$kept, deleted=$deleted, delete_failures=$delete_failures"
        fi
        total_processing_failures=$((total_processing_failures + 1))
        ;;
      *)
        echo "  ✗ Unexpected cleanup status $status; skipping $container"
        total_processing_failures=$((total_processing_failures + 1))
        ;;
    esac
  done

  echo ""
  echo "========================================"
  echo "Cleanup Summary"
  echo "========================================"
  echo "Packages assessed: $total_assessed"
  echo "Packages skipped (listing failed): $total_listing_failures"
  echo "Packages skipped (processing failed): $total_processing_failures"
  echo "Versions kept: $total_kept"
  echo "Versions deleted: $total_deleted"
  echo "Delete failures: $total_delete_failures"
  echo "========================================"

  if [[ "$total_listing_failures" -gt 0 || "$total_processing_failures" -gt 0 || "$total_delete_failures" -gt 0 ]]; then
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
