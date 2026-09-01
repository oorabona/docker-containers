#!/usr/bin/env bash
# Purge container images whose tags are not in the current valid build set.
# Required env vars: GH_TOKEN, OWNER
# Optional env vars: DRY_RUN (default: false; exactly true or false),
# KEEP_LATEST_COUNT (default: 10; 0 disables the latest-version floor), and
# KEEP_MONTHS (default: 6; 0 disables the age-retention floor).
#
# Usage: cleanup-outdated-tags.sh [container]
# With an argument, process exactly one package. Multiple package names need a
# different caller input shape and are refused.

_cleanup_outdated_tags_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../helpers/version-record-validation.sh
# shellcheck disable=SC1091 # Dynamic repository root is validated by the source guard.
if ! source "$_cleanup_outdated_tags_root/helpers/version-record-validation.sh"; then
  echo "Failed to source version record validation helper: $_cleanup_outdated_tags_root/helpers/version-record-validation.sh" >&2
  unset _cleanup_outdated_tags_root
  # shellcheck disable=SC2317 # This branch also runs when the script is executed.
  return 1 2>/dev/null || exit 1
fi
unset _cleanup_outdated_tags_root

script_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  cd "$script_dir/.." && pwd
}

usage() {
  cat >&2 <<'EOF'
Usage: cleanup-outdated-tags.sh [container]

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

_cleanup_outdated_tags_delete() {
  local deletion_target="$1"

  validate_cleanup_config || return 64
  [[ "${DRY_RUN-}" == false ]] || { echo "cleanup deletion refused: DRY_RUN must be false" >&2; return 64; }

  case "$deletion_target" in
    ghcr-version)
      local container="$2" version_id="$3"
      gh api --method DELETE -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
        "/users/${OWNER}/packages/container/${container}/versions/${version_id}" >/dev/null
      ;;
    dockerhub-tag)
      local dh_jwt="$2" container="$3" tag="$4"
      curl -sf -X DELETE -H "Authorization: Bearer $dh_jwt" \
        "https://hub.docker.com/v2/repositories/$DOCKERHUB_USERNAME/$container/tags/$tag/" >/dev/null
      ;;
    *)
      echo "cleanup deletion refused: unknown deletion target" >&2
      return 64
      ;;
  esac
}

build_valid_tags() {
  local container="$1" builds_json tags variant_tags flavor_tags
  if ! builds_json=$("$ROOT_DIR/make" list-builds "$container" 2>/dev/null); then
    return 1
  fi
  if ! jq -e '
    def valid_tag:
      # jq ^ is a true start anchor; \z, rather than $, rejects a final newline.
      if type == "string" then test("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\\z") else false end;
    type == "array" and length > 0
    and all(.[];
      type == "object"
      and (.tag | valid_tag)
      and (.variant | type == "string" and (. == "" or valid_tag))
      and (.flavor | type == "string" and (. == "" or valid_tag))
      and (.os == "linux" or .os == "windows")
      and (.is_default | type == "boolean")
      and (.is_latest_version | type == "boolean")
      and (if .variant != "" and .is_latest_version == true
           then ("latest-" + .variant | valid_tag)
           else true
           end)
      and (if .os == "windows" and .is_default != true and .flavor != "" and .is_latest_version == true
           then ("latest-" + .flavor | valid_tag)
           else true
           end))
  ' >/dev/null <<< "$builds_json"; then
    return 1
  fi
  if ! tags=$(jq -r '.[].tag' <<< "$builds_json"); then
    return 1
  fi
  tags+=$'\nlatest\nbuildcache'
  if ! variant_tags=$(set -o pipefail; jq -r '.[] | select(.variant != "" and .is_latest_version == true) | "latest-" + .variant' <<< "$builds_json" | sort -u); then
    return 1
  fi
  if [[ -n "$variant_tags" ]]; then
    tags+=$'\n'"$variant_tags"
  fi
  # Cleanup deliberately retains the broader historical Windows flavor set.
  if ! flavor_tags=$(set -o pipefail; jq -r '.[] | select(.os == "windows" and .is_default != true and .flavor != "" and .is_latest_version == true) | "latest-" + .flavor' <<< "$builds_json" | sort -u); then
    return 1
  fi
  if [[ -n "$flavor_tags" ]]; then
    tags+=$'\n'"$flavor_tags"
  fi
  printf '%s\n' "$tags" | sort -u
}

is_valid_tag() {
  local tag="$1" valid_tags="$2" base_tag remainder cache_base_tag
  if grep -qxF "$tag" <<< "$valid_tags"; then return 0; fi
  base_tag="${tag%-amd64}"
  base_tag="${base_tag%-arm64}"
  if [[ "$base_tag" != "$tag" ]] && grep -qxF "$base_tag" <<< "$valid_tags"; then return 0; fi
  if [[ "$tag" == buildcache-* ]]; then
    remainder="${tag#buildcache-}"
    [[ "$remainder" == buildcache-* || -z "$remainder" ]] && return 1
    cache_base_tag="$remainder"
    if [[ "$cache_base_tag" == *-amd64 ]]; then
      cache_base_tag="${cache_base_tag%-amd64}"
    elif [[ "$cache_base_tag" == *-arm64 ]]; then
      cache_base_tag="${cache_base_tag%-arm64}"
    else
      return 1
    fi
    [[ -n "$cache_base_tag" ]] || return 1
    is_valid_tag "$cache_base_tag" "$valid_tags"
    return $?
  fi
  return 1
}

purge_ghcr() {
  # 10 listing failure, 11 processing failure, 12 delete failure, 13 failure
  # after complete assessment, 14 uninterpretable record, and 15 protection
  # failure. 16 means an orphan candidate could not be assessed because its
  # obsolete parent survived or replay preflight stopped parent deletion.
  # Replaying a completed deletion list is execution only after every replay
  # payload has passed preflight; preflight failure returns the completed
  # tagged-plan record, but only returns 13 when no orphan remains unresolved.
  local container="$1" valid_tags="$2"
  local versions package_metadata version_count reported_version_count versions_file="" obsolete_file="" protected_file=""
  local version_id digest tags tag tag_list has_valid kept=0 obsolete=0 orphans=0 delete_failures=0 validation_error validation_status index
  local record_b64 record_json
  local protected_digests="" ghcr_token manifest children protection_result
  local -a kept_digests=() version_records=() obsolete_source_ids=() obsolete_source_digests=() obsolete_source_tags=()
  local -a untagged_ids=() untagged_digests=() orphan_ids=() orphan_digests=() obsolete_replay=()
  local -a parent_ids=() parent_digests=() parent_tags=() obsolete_ids=() obsolete_digests=() obsolete_tags=()

  validate_cleanup_config || return 64

  cleanup_files() { rm -f "$versions_file" "$obsolete_file" "$protected_file"; }

  if ! versions=$(gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "/users/${OWNER}/packages/container/${container}/versions" --paginate); then
    echo "  ✗ Failed to list GHCR versions; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! versions=$(jq -ce -s '
    select(length > 0)
    | if all(.[]; type == "array") then [.[][]]
      else error("GHCR package-versions response must contain JSON arrays")
      end
  ' <<< "$versions"); then
    echo "  ✗ GHCR version listing was not a JSON array; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! version_count=$(jq -er 'length' <<< "$versions"); then
    echo "  ✗ Failed to count GHCR versions; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! package_metadata=$(gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "/users/${OWNER}/packages/container/${container}"); then
    echo "  ✗ Failed to get GHCR version count; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! reported_version_count=$(jq -c '.version_count' <<< "$package_metadata"); then
    echo "  ✗ Failed to read GHCR package version_count; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  if ! validation_error=$(jq -er --argjson reported_version_count "$reported_version_count" "$VERSION_RECORD_VALIDATION_JQ
    validate_versions_listing_count(\$reported_version_count)" <<< "$versions" 2>&1 >/dev/null); then
    echo "  ✗ GHCR version listing count does not agree with package version_count or version_count was invalid: ${validation_error##*validation failed: }; skipping $container" >&2
    return "$LISTING_FAILURE"
  fi
  echo "  Found $version_count GHCR versions" >&2
  if [[ "$version_count" -eq 0 ]]; then
    echo "  No GHCR versions found" >&2
    if ! printf '%s\n' "0|0|0|0"; then
      return "$PROCESSING_FAILURE"
    fi
    return 0
  fi
  if validation_error=$(jq -er "$VERSION_RECORD_VALIDATION_JQ
    validate_outdated_tags_versions" <<< "$versions" 2>&1 >/dev/null); then
    :
  else
    validation_status=$?
    if [[ "$validation_status" -eq 5 ]]; then
      validation_error="${validation_error##*validation failed: }"
      echo "  ✗ GHCR version validation failed: validation failed: $validation_error; skipping $container" >&2
      return "$UNINTERPRETABLE_RECORD_FAILURE"
    fi
    echo "  ✗ GHCR version validator could not run: $validation_error; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if ! versions_file=$(mktemp) || ! obsolete_file=$(mktemp); then
    cleanup_files
    echo "  ✗ Failed to create GHCR work files; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if ! {
      printf 'work-list|expected|%s\n' "$version_count" \
      && jq -er '.[] | {id: (.id | tostring), digest: .name, tags: (.metadata.container.tags // [])} | @base64' <<< "$versions" \
      &&
      printf 'work-list|complete|%s\n' "$version_count"
    } > "$versions_file"; then
    cleanup_files
    echo "  ✗ Failed to prepare GHCR version list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi
  if [[ ! -r "$versions_file" || ! -r "$obsolete_file" || ! -w "$obsolete_file" ]]; then
    cleanup_files
    echo "  ✗ Failed to access GHCR work files; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  if ! load_framed_work_list "tagged assessment" "$versions_file" version_records; then
    cleanup_files
    return "$PROCESSING_FAILURE"
  fi

  # This phase consumes the complete framed source before classifying a single
  # payload.  Untagged entries are deliberately deferred to the orphan phase.
  for record_b64 in "${version_records[@]}"; do
    if ! record_json=$(printf '%s' "$record_b64" | base64 -d) \
      || ! version_id=$(jq -er '.id' <<< "$record_json") \
      || ! digest=$(jq -er '.digest' <<< "$record_json") \
      || ! tags=$(jq -er '.tags | join(",")' <<< "$record_json"); then
      cleanup_files
      echo "  ✗ Failed to read GHCR version record; skipping $container" >&2
      return "$PROCESSING_FAILURE"
    fi
    if [[ -z "$tags" ]]; then
      untagged_ids+=("$version_id")
      untagged_digests+=("$digest")
      continue
    fi
    has_valid=false
    if ! tag_list=$(jq -r '.tags[]' <<< "$record_json"); then
      cleanup_files
      echo "  ✗ Failed to read GHCR version tags; skipping $container" >&2
      return "$PROCESSING_FAILURE"
    fi
    while IFS= read -r tag; do
      if is_valid_tag "$tag" "$valid_tags"; then has_valid=true; break; fi
    done <<< "$tag_list"
    if [[ "$has_valid" == true ]]; then
      echo "  ✓ Keep (tags: $tags)" >&2
      kept=$((kept + 1)); kept_digests+=("$digest")
    else
      obsolete_source_ids+=("$version_id")
      obsolete_source_digests+=("$digest")
      obsolete_source_tags+=("$tags")
      echo "  ? Obsolete candidate (tags: $tags)" >&2
    fi
  done

  if [[ ${#kept_digests[@]} -gt 0 ]]; then
    echo "  Resolving manifest references for ${#kept_digests[@]} kept images..." >&2
    if ! ghcr_token=$(curl -sf -u "_:${GH_TOKEN}" \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:${OWNER}/${container}:pull" | jq -er '.token'); then
      cleanup_files
      echo "  ✗ Failed to get GHCR token; skipping $container" >&2
      return "$PROTECTION_FAILURE"
    fi
    if ! protected_file=$(mktemp) || ! printf '%s\n' "${kept_digests[@]}" > "$protected_file"; then
      cleanup_files
      echo "  ✗ Failed to prepare protected-digest list; skipping $container" >&2
      return "$PROTECTION_FAILURE"
    fi
    for digest in "${kept_digests[@]}"; do
      if ! manifest=$(curl -sf -H "Authorization: Bearer $ghcr_token" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json" \
        "https://ghcr.io/v2/${OWNER}/${container}/manifests/${digest}"); then
        cleanup_files
        echo "  ✗ Failed to fetch manifest for ${digest:0:19}; skipping $container" >&2
        return "$PROTECTION_FAILURE"
      fi
      if ! protection_result=$(jq -ce -s "$VERSION_RECORD_VALIDATION_JQ
        if length == 1 then .[0] | manifest_protection_contract
        else error(\"GHCR manifest response must contain exactly one JSON value\")
        end" <<< "$manifest" 2>&1); then
        cleanup_files
        echo "  ✗ Refused manifest protection for ${digest:0:19}: $protection_result; skipping $container" >&2
        return "$PROTECTION_FAILURE"
      fi
      if ! children=$(jq -r '.children[]' <<< "$protection_result"); then
        cleanup_files
        echo "  ✗ Failed to read protected manifest children for ${digest:0:19}; skipping $container" >&2
        return "$PROTECTION_FAILURE"
      fi
      if [[ -n "$children" ]] && ! printf '%s\n' "$children" >> "$protected_file"; then
        cleanup_files
        echo "  ✗ Failed to write protected-digest list; skipping $container" >&2
        return "$PROTECTION_FAILURE"
      fi
    done
    if ! protected_digests=$(sort -u "$protected_file"); then
      cleanup_files
      echo "  ✗ Failed to read protected-digest list; skipping $container" >&2
      return "$PROTECTION_FAILURE"
    fi
  fi

  # The source frame and every payload were parsed above.  An untagged child
  # of a kept manifest is known protected now; every other untagged version is
  # only a candidate until obsolete parent deletion has succeeded.
  for index in "${!untagged_ids[@]}"; do
    digest="${untagged_digests[$index]}"
    if [[ -n "$protected_digests" ]] && grep -qxF "$digest" <<< "$protected_digests"; then
      kept=$((kept + 1))
    else
      orphan_ids+=("${untagged_ids[$index]}")
      orphan_digests+=("$digest")
    fi
  done

  # Finalize the parent deletion plan while all source payloads are still
  # available.  The counts in a later preflight result therefore describe the
  # completed assessment, even if the replay frame itself is malformed.
  for index in "${!obsolete_source_ids[@]}"; do
    digest="${obsolete_source_digests[$index]}"
    if [[ -n "$protected_digests" ]] && grep -qxF "$digest" <<< "$protected_digests"; then
      kept=$((kept + 1))
    else
      parent_ids+=("${obsolete_source_ids[$index]}")
      parent_digests+=("$digest")
      parent_tags+=("${obsolete_source_tags[$index]}")
      obsolete=$((obsolete + 1))
    fi
  done

  if ! {
      printf 'work-list|expected|%s\n' "${#parent_ids[@]}" \
      && for index in "${!parent_ids[@]}"; do
        printf '%s|%s|%s\n' "${parent_ids[$index]}" "${parent_digests[$index]}" "${parent_tags[$index]}"
      done \
      &&
      printf 'work-list|complete|%s\n' "${#parent_ids[@]}"
    } > "$obsolete_file"; then
    cleanup_files
    echo "  ✗ Failed to write GHCR obsolete list; skipping $container" >&2
    return "$PROCESSING_FAILURE"
  fi

  # Preflight the complete parent replay before the first DELETE.  Execution
  # below reads only these immutable id/digest/tag arrays.
  if ! load_framed_work_list "deletion replay" "$obsolete_file" obsolete_replay; then
    cleanup_files
    if ! printf '%s\n' "$kept|$obsolete|$orphans|$delete_failures"; then
      return "$PROCESSING_FAILURE"
    fi
    if [[ ${#orphan_ids[@]} -gt 0 ]]; then
      return "$INCOMPLETE_DELETION_FAILURE"
    fi
    return "$POST_DELETE_PROCESSING_FAILURE"
  fi
  for record_b64 in "${obsolete_replay[@]}"; do
    if [[ ! "$record_b64" =~ ^([1-9][0-9]*)\|(sha256:[0-9a-f]{64})\|(.*)$ ]]; then
      echo "  ✗ Failed to read prepared GHCR deletion record; skipping $container" >&2
      if ! printf '%s\n' "$kept|$obsolete|$orphans|$delete_failures"; then
        return "$PROCESSING_FAILURE"
      fi
      cleanup_files
      if [[ ${#orphan_ids[@]} -gt 0 ]]; then
        return "$INCOMPLETE_DELETION_FAILURE"
      fi
      return "$POST_DELETE_PROCESSING_FAILURE"
    fi
    obsolete_ids+=("${BASH_REMATCH[1]}")
    obsolete_digests+=("${BASH_REMATCH[2]}")
    obsolete_tags+=("${BASH_REMATCH[3]}")
  done

  for index in "${!obsolete_ids[@]}"; do
    version_id="${obsolete_ids[$index]}"
    digest="${obsolete_digests[$index]}"
    tags="${obsolete_tags[$index]}"
    echo "  ✗ Obsolete (tags: $tags)" >&2
    if [[ "$DRY_RUN" == true ]]; then
      echo "    [DRY RUN] Would delete version $version_id" >&2
    elif _cleanup_outdated_tags_delete ghcr-version "$container" "$version_id"; then
      echo "    ✓ Deleted" >&2
    else
      echo "    ✗ Failed to delete" >&2
      delete_failures=$((delete_failures + 1))
    fi
  done

  if [[ "$delete_failures" -gt 0 && ${#orphan_ids[@]} -gt 0 ]]; then
    # A surviving obsolete parent may still reference every candidate.  They
    # are not orphans, and this package has no completed orphan assessment.
    echo "  ✗ Orphan assessment incomplete: an obsolete parent DELETE failed" >&2
    if ! printf '%s\n' "$kept|$obsolete|$orphans|$delete_failures"; then
      return "$PROCESSING_FAILURE"
    fi
    cleanup_files || echo "  ✗ Failed to remove GHCR work files after incomplete orphan assessment" >&2
    return "$INCOMPLETE_DELETION_FAILURE"
  fi

  if [[ "$delete_failures" -eq 0 ]]; then
    for index in "${!orphan_ids[@]}"; do
      version_id="${orphan_ids[$index]}"
      digest="${orphan_digests[$index]}"
      # The candidate becomes an orphan only after every parent DELETE has
      # succeeded.  Count and execute from the pre-parsed values.
      orphans=$((orphans + 1))
      echo "  ✗ Orphan (digest: ${digest:0:19}...)" >&2
      if [[ "$DRY_RUN" == true ]]; then
        echo "    [DRY RUN] Would delete version $version_id" >&2
      elif _cleanup_outdated_tags_delete ghcr-version "$container" "$version_id"; then
        echo "    ✓ Deleted" >&2
      else
        echo "    ✗ Failed to delete" >&2
        delete_failures=$((delete_failures + 1))
      fi
    done
  fi
  if ! printf '%s\n' "$kept|$obsolete|$orphans|$delete_failures"; then
    return "$PROCESSING_FAILURE"
  fi
  if ! cleanup_files; then
    echo "  ✗ Failed to remove GHCR work files after cleanup" >&2
    return "$POST_DELETE_PROCESSING_FAILURE"
  fi
  [[ "$delete_failures" -eq 0 ]] || return "$DELETE_FAILURE"
}

# stdout is assessed|deleted.  No configured Docker Hub credentials means it
# was not attempted (0|0); a returned non-zero status is always a real failure.
purge_dockerhub() {
  local container="$1" valid_tags="$2" dh_jwt response dh_tags tag dh_kept=0 dh_deleted=0 delete_failures=0
  validate_cleanup_config || return 64
  if [[ -z "$DOCKERHUB_USERNAME" || -z "$DOCKERHUB_TOKEN" ]]; then
    printf '%s\n' "0|0" || return "$PROCESSING_FAILURE"
    return 0
  fi
  echo "  Docker Hub cleanup for $container..." >&2
  if ! dh_jwt=$(curl -sf -X POST "https://hub.docker.com/v2/users/login" -H "Content-Type: application/json" \
      -d "{\"username\":\"$DOCKERHUB_USERNAME\",\"password\":\"$DOCKERHUB_TOKEN\"}" | jq -er '.token'); then
    echo "  ✗ Failed to authenticate to Docker Hub; skipping $container" >&2; return "$PROCESSING_FAILURE"
  fi
  if ! response=$(curl -sf -H "Authorization: Bearer $dh_jwt" \
      "https://hub.docker.com/v2/repositories/$DOCKERHUB_USERNAME/$container/tags?page_size=100"); then
    echo "  ✗ Failed to list Docker Hub tags; skipping $container" >&2; return "$LISTING_FAILURE"
  fi
  if ! jq -e '.results | type == "array"' >/dev/null <<< "$response"; then
    echo "  ✗ Docker Hub tag listing was not a JSON array; skipping $container" >&2; return "$LISTING_FAILURE"
  fi
  if ! dh_tags=$(jq -r '.results[].name // empty' <<< "$response"); then
    echo "  ✗ Failed to read Docker Hub tag listing; skipping $container" >&2; return "$PROCESSING_FAILURE"
  fi
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if is_valid_tag "$tag" "$valid_tags"; then dh_kept=$((dh_kept + 1)); continue; fi
    if [[ "$DRY_RUN" == true ]]; then
      echo "    [DRY RUN] Would delete Docker Hub tag: $tag" >&2
    elif _cleanup_outdated_tags_delete dockerhub-tag "$dh_jwt" "$container" "$tag"; then
      echo "    ✓ Deleted Docker Hub tag: $tag" >&2
    else
      echo "    ✗ Failed to delete Docker Hub tag: $tag" >&2; delete_failures=$((delete_failures + 1))
    fi
    dh_deleted=$((dh_deleted + 1))
  done <<< "$dh_tags"
  echo "  Docker Hub: kept=$dh_kept, deleted=$dh_deleted" >&2
  if ! printf '%s\n' "1|$dh_deleted"; then
    return "$PROCESSING_FAILURE"
  fi
  [[ "$delete_failures" -eq 0 ]] || return "$DELETE_FAILURE"
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
  : "${DOCKERHUB_USERNAME:=}"
  : "${DOCKERHUB_TOKEN:=}"
  ROOT_DIR=$(script_root) || return 1
  export ROOT_DIR

  # 16 is fail-closed when the listing required an orphan assessment but a
  # prior deletion failure or replay abort prevented that phase from running.
  local LISTING_FAILURE=10 PROCESSING_FAILURE=11 DELETE_FAILURE=12 POST_DELETE_PROCESSING_FAILURE=13 UNINTERPRETABLE_RECORD_FAILURE=14 PROTECTION_FAILURE=15 INCOMPLETE_DELETION_FAILURE=16
  local containers_output container valid_tags valid_count result ghcr_status dh_result dh_status containers_discovered=true
  local -a containers=()
  local kept obsolete orphans delete_failures dh_assessed dh_deleted package_assessed skip_dockerhub
  local total_assessed=0 total_build_failures=0 total_listing_failures=0 total_processing_failures=0 total_ghcr_delete_failures=0 total_dh_delete_failures=0
  local total_kept=0 total_obsolete=0 total_orphans=0 total_dh_deleted=0
  if [[ $# -gt 0 ]]; then
    containers=("$@")
  elif ! containers_output=$("$ROOT_DIR/make" list); then
    containers_discovered=false
  fi
  if [[ $# -eq 0 ]] && [[ "$containers_discovered" != true || -z "${containers_output//[[:space:]]/}" ]]; then
    printf '%s\n' "Could not enumerate containers; refusing to make pruning decisions" >&2
    return 1
  fi
  if [[ $# -eq 0 ]]; then
    mapfile -t containers <<< "$containers_output"
  fi

  for container in "${containers[@]}"; do
    echo ""; echo "========================================"; echo "Purging obsolete images: $container"; echo "========================================"
    if ! valid_tags=$(build_valid_tags "$container"); then
      echo "  Failed to get builds for $container, skipping"; total_build_failures=$((total_build_failures + 1)); continue
    fi
    valid_count=$(wc -l <<< "$valid_tags")
    echo "  Valid tags ($valid_count total):"; printf '    %s\n' "${valid_tags//$'\n'/$'\n    '}"
    package_assessed=false
    skip_dockerhub=false

    if result=$(purge_ghcr "$container" "$valid_tags"); then ghcr_status=0; else ghcr_status=$?; fi
    case "$ghcr_status" in
      0|"$DELETE_FAILURE"|"$POST_DELETE_PROCESSING_FAILURE")
        if parse_result_counters "$result" "GHCR cleanup result" \
          kept total_kept obsolete total_obsolete orphans total_orphans delete_failures total_ghcr_delete_failures; then
          package_assessed=true
          echo "  GHCR summary: kept=$kept, obsolete=$obsolete, orphans=$orphans, delete_failures=$delete_failures"
          [[ "$ghcr_status" -ne "$POST_DELETE_PROCESSING_FAILURE" ]] || total_processing_failures=$((total_processing_failures + 1))
        else
          echo "  ✗ Failed to read GHCR cleanup result; skipping $container"; total_processing_failures=$((total_processing_failures + 1)); skip_dockerhub=true
        fi ;;
      "$LISTING_FAILURE") total_listing_failures=$((total_listing_failures + 1)); skip_dockerhub=true ;;
      "$PROCESSING_FAILURE"|"$UNINTERPRETABLE_RECORD_FAILURE"|"$PROTECTION_FAILURE") total_processing_failures=$((total_processing_failures + 1)); skip_dockerhub=true ;;
      # A status 16 caller has not supplied a completed assessment, so Docker
      # Hub stays off.
      "$INCOMPLETE_DELETION_FAILURE")
        if parse_result_counters "$result" "incomplete GHCR cleanup result" \
          kept total_kept obsolete total_obsolete orphans - delete_failures total_ghcr_delete_failures; then
          echo "  GHCR summary: kept=$kept, obsolete=$obsolete, orphan phase not assessed, delete_failures=$delete_failures"
        else
          echo "  ✗ Failed to read incomplete GHCR cleanup result; skipping $container"
        fi
        total_processing_failures=$((total_processing_failures + 1)); skip_dockerhub=true
        ;;
      *) echo "  ✗ Unexpected GHCR cleanup status $ghcr_status; skipping $container"; total_processing_failures=$((total_processing_failures + 1)); skip_dockerhub=true ;;
    esac

    if [[ "$skip_dockerhub" == true ]]; then
      echo "  Docker Hub cleanup skipped: GHCR safety assessment was incomplete"
      continue
    fi

    if dh_result=$(purge_dockerhub "$container" "$valid_tags"); then dh_status=0; else dh_status=$?; fi
    case "$dh_status" in
      0|"$DELETE_FAILURE")
        if parse_result_counters "$dh_result" "Docker Hub cleanup result" \
          dh_assessed - dh_deleted total_dh_deleted; then
          [[ "$package_assessed" == true || "$dh_assessed" -eq 0 ]] || package_assessed=true
          [[ "$dh_status" -eq 0 ]] || total_dh_delete_failures=$((total_dh_delete_failures + 1))
        else
          echo "  ✗ Failed to read Docker Hub cleanup result; skipping $container"; total_processing_failures=$((total_processing_failures + 1))
        fi ;;
      "$LISTING_FAILURE") total_listing_failures=$((total_listing_failures + 1)) ;;
      "$PROCESSING_FAILURE") total_processing_failures=$((total_processing_failures + 1)) ;;
      *) total_processing_failures=$((total_processing_failures + 1)) ;;
    esac
    [[ "$package_assessed" == true ]] && total_assessed=$((total_assessed + 1))
  done

  echo ""; echo "========================================"; echo "Purge Summary"; echo "========================================"
  echo "Packages assessed: $total_assessed"
  echo "Packages skipped (build listing failed): $total_build_failures"
  echo "Registry listing failures: $total_listing_failures"
  echo "Packages skipped (processing failed): $total_processing_failures"
  echo "GHCR — kept: $total_kept, obsolete: $total_obsolete, orphans: $total_orphans"
  echo "GHCR — delete failures: $total_ghcr_delete_failures"
  [[ -n "$DOCKERHUB_USERNAME" ]] && echo "Docker Hub — delete failures: $total_dh_delete_failures"
  [[ -n "$DOCKERHUB_USERNAME" ]] && echo "Docker Hub — deleted: $total_dh_deleted"
  echo "========================================"
  [[ "$total_build_failures" -eq 0 && "$total_listing_failures" -eq 0 && "$total_processing_failures" -eq 0 && "$total_ghcr_delete_failures" -eq 0 && "$total_dh_delete_failures" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
