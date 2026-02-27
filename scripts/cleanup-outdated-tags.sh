#!/bin/bash
# Purge container images whose tags are not in the current valid build set.
#
# Uses ./make list-builds to determine valid tags, then:
#   Phase 1: Classify GHCR versions as kept/obsolete by tag matching
#   Phase 2: Resolve manifest list children to build protected digest set
#   Phase 3: Delete obsolete tagged versions + untagged orphans from GHCR
#   Phase 4: Delete obsolete tags from Docker Hub (if credentials provided)
#
# Required env vars: GH_TOKEN, OWNER
# Optional env vars:
#   DRY_RUN (default: false)
#   DOCKERHUB_USERNAME, DOCKERHUB_TOKEN — if set, also cleans Docker Hub
#
# Usage: cleanup-outdated-tags.sh [container...]
#   If no containers specified, processes all containers from ./make list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${DRY_RUN:=false}"
: "${DOCKERHUB_USERNAME:=}"
: "${DOCKERHUB_TOKEN:=}"

# Get containers to process
if [[ $# -gt 0 ]]; then
  CONTAINERS="$*"
else
  CONTAINERS=$("$ROOT_DIR/make" list)
fi

TOTAL_KEPT=0
TOTAL_OBSOLETE=0
TOTAL_ORPHANS=0
TOTAL_DH_DELETED=0

# ── Helper: build valid tag set for a container ──
build_valid_tags() {
  local container="$1"
  local builds_json

  builds_json=$("$ROOT_DIR/make" list-builds "$container" 2>/dev/null) || return 1

  if [[ -z "$builds_json" || "$builds_json" == "[]" ]]; then
    return 1
  fi

  # Tags from builds + latest + buildcache + latest-{variant}
  local tags
  tags=$(echo "$builds_json" | jq -r '.[].tag')
  tags+=$'\n'"latest"
  tags+=$'\n'"buildcache"

  local variant_tags
  variant_tags=$(echo "$builds_json" | jq -r '
    .[] | select(.variant != "" and .is_latest_version == true) |
    "latest-" + .variant
  ' | sort -u)
  if [[ -n "$variant_tags" ]]; then
    tags+=$'\n'"$variant_tags"
  fi

  # Deduplicate
  echo "$tags" | sort -u
}

# ── Helper: check if a tag is valid (exact match or arch-specific of a valid tag) ──
is_valid_tag() {
  local tag="$1"
  local valid_tags="$2"

  # Direct match
  if echo "$valid_tags" | grep -qxF "$tag"; then
    return 0
  fi

  # Arch-specific suffix of a valid tag (e.g., 1.7.7-amd64, 1.7.7-alpine-arm64)
  local base_tag
  base_tag="${tag%-amd64}"
  base_tag="${base_tag%-arm64}"
  if [[ "$base_tag" != "$tag" ]] && echo "$valid_tags" | grep -qxF "$base_tag"; then
    return 0
  fi

  return 1
}

# ── Helper: purge GHCR obsolete images for one container ──
purge_ghcr() {
  local container="$1"
  local valid_tags="$2"
  local kept=0 obsolete=0 orphans=0

  # Fetch all GHCR versions
  local versions
  versions=$(gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/users/${OWNER}/packages/container/${container}/versions" \
    --paginate 2>/dev/null || echo "[]")

  if [[ "$versions" == "[]" || -z "$versions" ]]; then
    echo "  No GHCR versions found"
    echo "0|0|0"
    return
  fi

  local version_count
  version_count=$(echo "$versions" | jq 'length')
  echo "  Found $version_count GHCR versions" >&2

  # Save to temp file: id|digest|tags
  local versions_file
  versions_file=$(mktemp)
  echo "$versions" | jq -r '.[] | "\(.id)|\(.name)|\(.metadata.container.tags // [] | join(","))"' > "$versions_file"

  # ── Phase 1: Classify tagged versions ──
  local kept_digests=()
  local obsolete_file
  obsolete_file=$(mktemp)

  while IFS='|' read -r version_id digest tags; do
    [[ -z "$version_id" ]] && continue
    [[ -z "$tags" ]] && continue

    local has_valid=false
    for tag in $(echo "$tags" | tr ',' ' '); do
      if is_valid_tag "$tag" "$valid_tags"; then
        has_valid=true
        break
      fi
    done

    if [[ "$has_valid" == "true" ]]; then
      echo "  ✓ Keep (tags: $tags)" >&2
      kept=$((kept + 1))
      kept_digests+=("$digest")
    else
      echo "  ? Obsolete candidate (tags: $tags)" >&2
      echo "$version_id|$digest|$tags" >> "$obsolete_file"
    fi
  done < "$versions_file"

  # ── Phase 2: Resolve manifest list children ──
  local protected_digests=""
  local resolve_ok=false

  if [[ ${#kept_digests[@]} -gt 0 ]]; then
    echo "" >&2
    echo "  Resolving manifest references for ${#kept_digests[@]} kept images..." >&2

    local ghcr_token
    ghcr_token=$(curl -sf \
      -u "_:${GH_TOKEN}" \
      "https://ghcr.io/token?service=ghcr.io&scope=repository:${OWNER}/${container}:pull" \
      | jq -r '.token' 2>/dev/null || echo "")

    if [[ -z "$ghcr_token" ]]; then
      echo "  ⚠ Failed to get GHCR token, skipping all deletions for safety" >&2
    else
      local protected_file
      protected_file=$(mktemp)
      printf '%s\n' "${kept_digests[@]}" > "$protected_file"

      local fetch_failures=0
      for digest in "${kept_digests[@]}"; do
        local manifest
        manifest=$(curl -sf \
          -H "Authorization: Bearer $ghcr_token" \
          -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json" \
          "https://ghcr.io/v2/${OWNER}/${container}/manifests/${digest}" 2>/dev/null || echo "")

        if [[ -z "$manifest" ]]; then
          fetch_failures=$((fetch_failures + 1))
          echo "  ⚠ Failed to fetch manifest for ${digest:0:19}..." >&2
          continue
        fi

        local children
        children=$(echo "$manifest" | jq -r '.manifests[]?.digest // empty' 2>/dev/null || true)
        if [[ -n "$children" ]]; then
          echo "$children" >> "$protected_file"
        fi
      done

      if [[ "$fetch_failures" -gt 0 ]]; then
        echo "  ⚠ $fetch_failures manifest fetch(es) failed, skipping all deletions for safety" >&2
      else
        protected_digests=$(sort -u "$protected_file")
        local protected_count
        protected_count=$(echo "$protected_digests" | wc -l)
        echo "  Protected digests: $protected_count (${#kept_digests[@]} manifests + children)" >&2
        resolve_ok=true
      fi

      rm -f "$protected_file"
    fi
  else
    resolve_ok=true
  fi

  # ── Phase 3: Delete obsolete tagged + untagged orphans ──
  if [[ "$resolve_ok" == "true" ]]; then
    # Delete obsolete tagged versions
    while IFS='|' read -r version_id digest tags; do
      [[ -z "$version_id" ]] && continue

      if [[ -n "$protected_digests" ]] && echo "$protected_digests" | grep -qxF "$digest"; then
        echo "  ✓ Keep (tags: $tags) — digest is manifest child" >&2
        kept=$((kept + 1))
      else
        echo "  ✗ Obsolete (tags: $tags)" >&2
        if [[ "$DRY_RUN" == "true" ]]; then
          echo "    [DRY RUN] Would delete version $version_id" >&2
        else
          if gh api \
            --method DELETE \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "/users/${OWNER}/packages/container/${container}/versions/${version_id}" 2>/dev/null; then
            echo "    ✓ Deleted" >&2
          else
            echo "    ✗ Failed to delete" >&2
          fi
        fi
        obsolete=$((obsolete + 1))
      fi
    done < "$obsolete_file"

    # Delete untagged orphans
    while IFS='|' read -r version_id digest tags; do
      [[ -z "$version_id" ]] && continue
      [[ -n "$tags" ]] && continue

      if [[ -n "$protected_digests" ]] && echo "$protected_digests" | grep -qxF "$digest"; then
        kept=$((kept + 1))
      else
        echo "  ✗ Orphan (digest: ${digest:0:19}...)" >&2
        if [[ "$DRY_RUN" == "true" ]]; then
          echo "    [DRY RUN] Would delete version $version_id" >&2
        else
          if gh api \
            --method DELETE \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "/users/${OWNER}/packages/container/${container}/versions/${version_id}" 2>/dev/null; then
            echo "    ✓ Deleted" >&2
          else
            echo "    ✗ Failed to delete" >&2
          fi
        fi
        orphans=$((orphans + 1))
      fi
    done < "$versions_file"
  fi

  rm -f "$obsolete_file" "$versions_file"
  echo "$kept|$obsolete|$orphans"
}

# ── Helper: purge Docker Hub obsolete tags for one container ──
purge_dockerhub() {
  local container="$1"
  local valid_tags="$2"
  local dh_deleted=0 dh_kept=0

  if [[ -z "$DOCKERHUB_USERNAME" || -z "$DOCKERHUB_TOKEN" ]]; then
    echo "0"
    return
  fi

  echo "" >&2
  echo "  Docker Hub cleanup for $container..." >&2

  # Authenticate
  local dh_jwt
  dh_jwt=$(curl -sf -X POST "https://hub.docker.com/v2/users/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$DOCKERHUB_USERNAME\",\"password\":\"$DOCKERHUB_TOKEN\"}" \
    | jq -r '.token // empty' 2>/dev/null || echo "")

  if [[ -z "$dh_jwt" ]]; then
    echo "  ⚠ Failed to authenticate to Docker Hub, skipping" >&2
    echo "0"
    return
  fi

  # List all tags
  local dh_tags
  dh_tags=$(curl -sf \
    -H "Authorization: Bearer $dh_jwt" \
    "https://hub.docker.com/v2/repositories/$DOCKERHUB_USERNAME/$container/tags?page_size=100" \
    | jq -r '.results[].name // empty' 2>/dev/null || echo "")

  if [[ -z "$dh_tags" ]]; then
    echo "  No Docker Hub tags found (repo may not exist)" >&2
    echo "0"
    return
  fi

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue

    if is_valid_tag "$tag" "$valid_tags"; then
      dh_kept=$((dh_kept + 1))
    else
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY RUN] Would delete Docker Hub tag: $tag" >&2
      else
        if curl -sf -X DELETE \
          -H "Authorization: Bearer $dh_jwt" \
          "https://hub.docker.com/v2/repositories/$DOCKERHUB_USERNAME/$container/tags/$tag/" >/dev/null 2>&1; then
          echo "    ✓ Deleted Docker Hub tag: $tag" >&2
        else
          echo "    ✗ Failed to delete Docker Hub tag: $tag" >&2
        fi
      fi
      dh_deleted=$((dh_deleted + 1))
    fi
  done <<< "$dh_tags"

  echo "  Docker Hub: kept=$dh_kept, deleted=$dh_deleted" >&2
  echo "$dh_deleted"
}

# ── Main loop ──
for CONTAINER in $CONTAINERS; do
  echo ""
  echo "========================================"
  echo "Purging obsolete images: $CONTAINER"
  echo "========================================"

  VALID_TAGS=$(build_valid_tags "$CONTAINER") || {
    echo "  Failed to get builds for $CONTAINER, skipping"
    continue
  }

  VALID_COUNT=$(echo "$VALID_TAGS" | wc -l)
  echo "  Valid tags ($VALID_COUNT total):"
  echo "$VALID_TAGS" | sed 's/^/    /'

  # GHCR cleanup
  GHCR_RESULT=$(purge_ghcr "$CONTAINER" "$VALID_TAGS")
  IFS='|' read -r KEPT OBSOLETE ORPHANS <<< "$GHCR_RESULT"
  TOTAL_KEPT=$((TOTAL_KEPT + KEPT))
  TOTAL_OBSOLETE=$((TOTAL_OBSOLETE + OBSOLETE))
  TOTAL_ORPHANS=$((TOTAL_ORPHANS + ORPHANS))
  echo "  GHCR summary: kept=$KEPT, obsolete=$OBSOLETE, orphans=$ORPHANS"

  # Docker Hub cleanup
  DH_DELETED=$(purge_dockerhub "$CONTAINER" "$VALID_TAGS")
  TOTAL_DH_DELETED=$((TOTAL_DH_DELETED + DH_DELETED))
done

echo ""
echo "========================================"
echo "Purge Summary"
echo "========================================"
echo "GHCR — kept: $TOTAL_KEPT, obsolete: $TOTAL_OBSOLETE, orphans: $TOTAL_ORPHANS"
if [[ -n "$DOCKERHUB_USERNAME" ]]; then
  echo "Docker Hub — deleted: $TOTAL_DH_DELETED"
fi
echo "========================================"
