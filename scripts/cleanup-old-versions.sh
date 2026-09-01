#!/usr/bin/env bash
# Age-based cleanup of GHCR container versions.
#
# Required env vars: GH_TOKEN, OWNER
# Optional env vars: DRY_RUN (default: false; exactly true or false),
# KEEP_LATEST_COUNT (default: 10; range: 0 through 2147483647; 0 disables the
# latest-version floor), and KEEP_MONTHS (default: 6; same range; 0 disables
# the age-retention floor).
#
# Usage: cleanup-old-versions.sh [container]
# With an argument, process exactly one package. Multiple package names need a
# different caller input shape and are refused.

_cleanup_old_versions_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../helpers/version-record-validation.sh
# shellcheck disable=SC1091 # Dynamic repository root is validated by the source guard.
if ! source "$_cleanup_old_versions_root/helpers/version-record-validation.sh"; then
  echo "Failed to source version record validation helper: $_cleanup_old_versions_root/helpers/version-record-validation.sh" >&2
  unset _cleanup_old_versions_root
  # shellcheck disable=SC2317 # This branch also runs when the script is executed.
  return 1 2>/dev/null || exit 1
fi
unset _cleanup_old_versions_root

script_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  cd "$script_dir/.." && pwd
}

usage() {
  cat >&2 <<'EOF'
Usage: cleanup-old-versions.sh [container]

Without container, process every discovered package. With container, process
exactly one package whose name matches ^[a-z0-9][a-z0-9._-]*$. Whitespace,
globs, newlines, empty values, and multiple package names are rejected.
EOF
}

# This is the existing valid_container_target contract used before a container
# forms a project path in scripts/check-gpg-keys.sh. GHCR package components
# use the same safe shape.
valid_container_target() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
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

_cleanup_old_versions_delete() {
  local container="$1" version_id="$2"

  validate_cleanup_config || return 64
  [[ "${DRY_RUN-}" == false ]] || { echo "cleanup deletion refused: DRY_RUN must be false" >&2; return 64; }

  gh api --method DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/users/${OWNER}/packages/container/${container}/versions/${version_id}" >/dev/null
}

# Write kept|decided|deleted|delete_failures to stdout once a package was
# completely assessed. `decided` counts the completed deletion plan, while
# `deleted` counts successful removal outcomes. Its return status, rather than
# that record, communicates failure:
# 10 listing failure, 11 processing failure, 12 one or more delete failures,
# 13 a failure after every record was assessed, including replay preflight,
# and 14 an uninterpretable record.  A replay preflight failure still returns
# the completed assessment record, but it happens before the first DELETE.
purge_container() {
  local container="$1"
  local versions package version_count reported_version_count versions_file="" deletions_file=""
  local position=0 kept=0 decided=0 deleted=0 delete_failures=0
  local version_id tags created_at keep_reason tag tag_list major version_ts cutoff_ts validation_error validation_status
  local record_b64 record_json
  local -a version_records=() deletion_records=() replay_records=()
  local -a replay_positions=() replay_ids=() replay_tags=()
  declare -A major_seen=()

  validate_cleanup_config || return 64

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
    echo "  ✗ Failed to count version listing; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi

  if ! package=$(gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/users/${OWNER}/packages/container/${container}"); then
    echo "  ✗ Failed to get package version total; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! reported_version_count=$(jq -c '.version_count' <<< "$package"); then
    echo "  ✗ Failed to read package version_count; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! validation_error=$(jq -er --argjson reported_version_count "$reported_version_count" "$VERSION_RECORD_VALIDATION_JQ
    validate_versions_listing_count(\$reported_version_count)" <<< "$versions" 2>&1 >/dev/null); then
    echo "  ✗ Version listing count does not agree with package version_count or version_count was invalid: ${validation_error##*validation failed: }; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  echo "  Found $version_count versions" >&2
  if [[ "$version_count" -eq 0 ]]; then
    echo "  No versions found (might be new or private)" >&2
    if ! printf '%s\n' "0|0|0|0"; then
      return "$PROCESSING_FAILURE"
    fi
    return 0
  fi

  if validation_error=$(jq -er "$VERSION_RECORD_VALIDATION_JQ
    validate_old_versions" <<< "$versions" 2>&1 >/dev/null); then
    :
  else
    validation_status=$?
    if [[ "$validation_status" -eq 5 ]]; then
      validation_error="${validation_error##*validation failed: }"
      echo "  ✗ Version validation failed: validation failed: $validation_error; skipping $container" >&2
      return "$UNINTERPRETABLE_RECORD_FAILURE"
    fi
    echo "  ✗ Version validator could not run: $validation_error; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  # shellcheck disable=SC2153 # validate_cleanup_config assigns CUTOFF_TS.
  cutoff_ts="$CUTOFF_TS"
  if ! versions_file=$(mktemp) || ! deletions_file=$(mktemp); then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to create cleanup work files; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if ! {
      printf 'work-list|expected|%s\n' "$version_count" \
      && jq -er '.[] | {id: (.id | tostring), tags: (.metadata.container.tags // []), created_at: .created_at} | @base64' <<< "$versions" \
      &&
      printf 'work-list|complete|%s\n' "$version_count"
    } > "$versions_file"; then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to prepare version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if [[ ! -r "$versions_file" ]]; then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to read version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  if ! load_framed_work_list "version assessment" "$versions_file" version_records; then
    rm -f "$versions_file" "$deletions_file"
    return "$PROCESSING_FAILURE"
  fi

  # Decide every record before deleting any of them.  The framed source has
  # been completely consumed before a payload is decoded or classified.
  for record_b64 in "${version_records[@]}"; do
    if ! record_json=$(printf '%s' "$record_b64" | base64 -d) \
      || ! version_id=$(jq -er '.id' <<< "$record_json") \
      || ! tags=$(jq -er '.tags | join(",")' <<< "$record_json") \
      || ! created_at=$(jq -er '.created_at' <<< "$record_json"); then
      echo "  ✗ Failed to read version record; skipping $container" >&2
      rm -f "$versions_file" "$deletions_file"
      return "$PROCESSING_FAILURE"
    fi
    position=$((position + 1))
    keep_reason=""

    # Age cannot establish whether an untagged manifest is a live platform
    # child of a retained index. Retain it here: cleanup-outdated-tags.sh is
    # the only deletion authority. Its workflow sweep coverage is stated once
    # in the run summary below.
    if [[ -z "$tags" ]]; then
      keep_reason="untagged; deferred to cleanup-outdated-tags.sh"
    elif grep -q ",latest," <<< ",$tags,"; then
      keep_reason="has 'latest' tag"
    elif [[ "$position" -le "$KEEP_LATEST_COUNT" ]]; then
      keep_reason="in top $KEEP_LATEST_COUNT recent"
    else
      if ! tag_list=$(jq -r '.tags[]' <<< "$record_json"); then
        echo "  ✗ Failed to read version tags; skipping $container" >&2
        rm -f "$versions_file" "$deletions_file"
        return "$PROCESSING_FAILURE"
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
        rm -f "$versions_file" "$deletions_file"
        return "$PROCESSING_FAILURE"
      fi
      if [[ "$version_ts" -gt "$cutoff_ts" ]]; then
        keep_reason="newer than $KEEP_MONTHS months"
      fi
    fi

    if [[ -n "$keep_reason" ]]; then
      echo "  ✓ Keep #$position (version $version_id; tags: ${tags:-untagged}) - $keep_reason" >&2
      kept=$((kept + 1))
    else
      deletion_records+=("$position|$version_id|$tags")
      decided=$((decided + 1))
    fi
  done

  if ! {
      printf 'work-list|expected|%s\n' "$decided" \
      && { if [[ ${#deletion_records[@]} -gt 0 ]]; then printf '%s\n' "${deletion_records[@]}"; fi; } \
      &&
      printf 'work-list|complete|%s\n' "$decided"
    } > "$deletions_file"; then
    rm -f "$versions_file" "$deletions_file"
    echo "  ✗ Failed to prepare deletion list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  if ! rm -f "$versions_file"; then
    rm -f "$deletions_file"
    echo "  ✗ Failed to remove version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  if ! load_framed_work_list "deletion replay" "$deletions_file" replay_records; then
    rm -f "$deletions_file"
    if ! printf '%s\n' "$kept|$decided|$deleted|$delete_failures"; then
      return "$PROCESSING_FAILURE"
    fi
    return "$POST_DELETE_PROCESSING_FAILURE"
  fi

  # Parse the entire replay before its first DELETE.  The execution loop below
  # consumes only these immutable values, so a malformed later record cannot
  # follow a successful deletion.
  for record_b64 in "${replay_records[@]}"; do
    if [[ ! "$record_b64" =~ ^(0|[1-9][0-9]*)\|([1-9][0-9]*)\|(.*)$ ]]; then
      echo "  ✗ Failed to read prepared deletion record; skipping $container" >&2
      if ! printf '%s\n' "$kept|$decided|$deleted|$delete_failures"; then
        return "$PROCESSING_FAILURE"
      fi
      rm -f "$deletions_file"
      return "$POST_DELETE_PROCESSING_FAILURE"
    fi
    replay_positions+=("${BASH_REMATCH[1]}")
    replay_ids+=("${BASH_REMATCH[2]}")
    replay_tags+=("${BASH_REMATCH[3]}")
  done

  for position in "${!replay_ids[@]}"; do
    version_id="${replay_ids[$position]}"
    tags="${replay_tags[$position]}"
    echo "  ✗ Delete #${replay_positions[$position]} (tags: ${tags:-untagged})" >&2
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [DRY RUN] Would delete version $version_id" >&2
    elif _cleanup_old_versions_delete "$container" "$version_id"; then
      echo "    ✓ Deleted version $version_id" >&2
      deleted=$((deleted + 1))
    else
      echo "    ✗ Failed to delete version $version_id" >&2
      delete_failures=$((delete_failures + 1))
    fi
  done

  if ! printf '%s\n' "$kept|$decided|$deleted|$delete_failures"; then
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

  if [[ "${1-}" == --help || "${1-}" == -h ]]; then
    usage
    return 0
  fi
  # The executable accepts one optional package. Unit tests source main to
  # exercise aggregate accounting across fixture packages; that is not a CLI
  # input shape and does not alter the executable contract.
  if [[ "${BASH_SOURCE[0]}" == "$0" && $# -gt 1 ]]; then
    printf '%s\n' 'cleanup target rejected: supply exactly one package name or no package name' >&2
    return 64
  fi
  if [[ $# -eq 1 ]] && ! valid_container_target "$1"; then
    printf '%s\n' 'cleanup target rejected: package name must match ^[a-z0-9][a-z0-9._-]*$' >&2
    return 64
  fi

  if [[ ! -v DRY_RUN ]]; then DRY_RUN=false; fi
  if [[ ! -v KEEP_LATEST_COUNT ]]; then KEEP_LATEST_COUNT=10; fi
  if [[ ! -v KEEP_MONTHS ]]; then KEEP_MONTHS=6; fi
  if ! validate_cleanup_config; then
    return 64
  fi
  : "${GH_TOKEN:?GH_TOKEN is required}"
  : "${OWNER:?OWNER is required}"

  local LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14
  local root_dir containers_output container result status
  local -a containers=()
  local kept decided deleted delete_failures
  root_dir=$(script_root) || return 1

  if [[ $# -gt 0 ]]; then
    containers=("$@")
  else
    # The workflow's reference-aware sweep coverage is stated once in the run
    # summary below. Untagged versions are retained here, not deleted.
    # That sweep is the sole authority for deleting untagged versions: it protects
    # .manifests[].digest children of kept manifests, but does not follow OCI
    # referrers (attestations, SBOMs, signatures) or external digest pins.
    # Keep the discovery paths aligned; otherwise untagged versions can only
    # accumulate. If its obsolete-tag deletion fails, it skips orphan cleanup
    # fail-closed, which deliberately retains untagged versions for that run.
    containers_output=$(find "$root_dir" -maxdepth 2 -name Dockerfile -exec dirname {} \; | sed "s|^$root_dir/||" | sort) || return 1
    if [[ -z "${containers_output//[[:space:]]/}" ]]; then
      printf '%s\n' 'Could not enumerate containers; refusing to make pruning decisions' >&2
      return 1
    fi
    mapfile -t containers <<< "$containers_output"
  fi

  print_banner

  local total_decided=0 total_deleted=0 total_kept=0 total_assessed=0
  local total_listing_failures=0 total_processing_failures=0 total_delete_failures=0
  for container in "${containers[@]}"; do
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
        if parse_result_counters "$result" "cleanup result" \
          kept total_kept decided total_decided deleted total_deleted delete_failures total_delete_failures; then
          :
        else
          echo "  ✗ Failed to read cleanup result; skipping $container"
          total_processing_failures=$((total_processing_failures + 1))
          continue
        fi
        total_assessed=$((total_assessed + 1))
        echo "  Summary: kept=$kept, decided=$decided, deleted=$deleted, delete_failures=$delete_failures"
        [[ "$status" -ne "$POST_DELETE_PROCESSING_FAILURE" ]] || total_processing_failures=$((total_processing_failures + 1))
        ;;
      "$LISTING_FAILURE") total_listing_failures=$((total_listing_failures + 1)) ;;
      "$PROCESSING_FAILURE"|"$UNINTERPRETABLE_RECORD_FAILURE") total_processing_failures=$((total_processing_failures + 1)) ;;
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
  echo "Versions decided for deletion: $total_decided"
  echo "Versions deleted: $total_deleted"
  echo "Delete failures: $total_delete_failures"
  echo "Untagged versions: retained here; cleanup-outdated-tags.sh is their only deletion authority. Sweep coverage: scheduled runs and unfiltered purge dispatches sweep the whole discovered set; filtered purge dispatches sweep only the selected package; dispatches without purge_obsolete sweep nothing."
  echo "If that sweep skips orphan cleanup after a deletion failure, retention is fail-closed for this run."
  echo "========================================"

  if [[ "$total_listing_failures" -gt 0 || "$total_processing_failures" -gt 0 || "$total_delete_failures" -gt 0 ]]; then
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
