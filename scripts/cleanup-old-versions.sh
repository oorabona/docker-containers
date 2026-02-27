#!/bin/bash
# Age-based cleanup of GHCR container versions
#
# Applies retention rules in priority order:
#   1. Keep versions with "latest" tag
#   2. Keep top N most recent versions
#   3. Keep latest of each major version
#   4. Keep versions newer than cutoff date
#
# Required env vars: GH_TOKEN, OWNER
# Optional env vars: DRY_RUN (default: false), KEEP_LATEST_COUNT (default: 10), KEEP_MONTHS (default: 6)
#
# Usage: cleanup-old-versions.sh [container...]
#   If no containers specified, auto-discovers from Dockerfile directories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${DRY_RUN:=false}"
: "${KEEP_LATEST_COUNT:=10}"
: "${KEEP_MONTHS:=6}"

CUTOFF_DATE=$(date -d "-${KEEP_MONTHS} months" +%Y-%m-%dT%H:%M:%SZ)

echo "========================================"
echo "GHCR Age-Based Cleanup"
echo "========================================"
echo "Owner: $OWNER"
echo "Keep latest count: $KEEP_LATEST_COUNT"
echo "Keep versions newer than: $CUTOFF_DATE"
echo "Dry run: $DRY_RUN"
echo "========================================"

# Get containers to process
if [[ $# -gt 0 ]]; then
  CONTAINERS="$*"
else
  CONTAINERS=$(find "$ROOT_DIR" -maxdepth 2 -name "Dockerfile" -exec dirname {} \; | sed "s|^$ROOT_DIR/||" | sort)
fi

TOTAL_DELETED=0
TOTAL_KEPT=0

for CONTAINER in $CONTAINERS; do
  echo ""
  echo "========================================"
  echo "Processing: $CONTAINER"
  echo "========================================"

  # Get all versions for this package
  VERSIONS=$(gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/users/${OWNER}/packages/container/${CONTAINER}/versions" \
    --paginate 2>/dev/null || echo "[]")

  if [ "$VERSIONS" = "[]" ] || [ -z "$VERSIONS" ]; then
    echo "  No versions found (might be new or private)"
    continue
  fi

  VERSION_COUNT=$(echo "$VERSIONS" | jq 'length')
  echo "  Found $VERSION_COUNT versions"

  VERSIONS_FILE=$(mktemp)
  echo "$VERSIONS" | jq -r '.[] | "\(.id)|\(.metadata.container.tags // [] | join(","))|\(.created_at)"' > "$VERSIONS_FILE"

  declare -A MAJOR_SEEN=()
  POSITION=0
  KEPT=0
  DELETED=0

  while IFS='|' read -r VERSION_ID TAGS CREATED_AT; do
    POSITION=$((POSITION + 1))
    [ -z "$VERSION_ID" ] && continue

    KEEP_REASON=""

    # Rule 1: Keep "latest" tag
    if echo ",$TAGS," | grep -q ",latest,"; then
      KEEP_REASON="has 'latest' tag"
    fi

    # Rule 2: Keep top N most recent
    if [ -z "$KEEP_REASON" ] && [ "$POSITION" -le "$KEEP_LATEST_COUNT" ]; then
      KEEP_REASON="in top $KEEP_LATEST_COUNT recent"
    fi

    # Rule 3: Keep latest of each major version
    if [ -z "$KEEP_REASON" ]; then
      for TAG in $(echo "$TAGS" | tr ',' ' '); do
        if [[ "$TAG" =~ ^v?([0-9]+)\.[0-9] ]]; then
          MAJOR="${BASH_REMATCH[1]}"
          if [ -z "${MAJOR_SEEN[$MAJOR]:-}" ]; then
            MAJOR_SEEN[$MAJOR]=1
            KEEP_REASON="latest of major v$MAJOR"
          fi
          break
        fi
      done
    fi

    # Rule 4: Keep if newer than cutoff
    if [ -z "$KEEP_REASON" ]; then
      VERSION_TS=$(date -d "$CREATED_AT" +%s 2>/dev/null || echo "0")
      CUTOFF_TS=$(date -d "$CUTOFF_DATE" +%s)
      if [ "$VERSION_TS" -gt "$CUTOFF_TS" ]; then
        KEEP_REASON="newer than $KEEP_MONTHS months"
      fi
    fi

    if [ -n "$KEEP_REASON" ]; then
      echo "  ✓ Keep #$POSITION (tags: ${TAGS:-untagged}) - $KEEP_REASON"
      KEPT=$((KEPT + 1))
    else
      echo "  ✗ Delete #$POSITION (tags: ${TAGS:-untagged}, created: $CREATED_AT)"
      if [ "$DRY_RUN" = "true" ]; then
        echo "    [DRY RUN] Would delete version $VERSION_ID"
      else
        if gh api \
          --method DELETE \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "/users/${OWNER}/packages/container/${CONTAINER}/versions/${VERSION_ID}" 2>/dev/null; then
          echo "    ✓ Deleted"
          DELETED=$((DELETED + 1))
        else
          echo "    ✗ Failed to delete"
        fi
      fi
    fi
  done < "$VERSIONS_FILE"

  rm -f "$VERSIONS_FILE"
  TOTAL_KEPT=$((TOTAL_KEPT + KEPT))
  TOTAL_DELETED=$((TOTAL_DELETED + DELETED))
  echo "  Summary: kept=$KEPT, deleted=$DELETED"
done

echo ""
echo "========================================"
echo "Cleanup Summary"
echo "========================================"
echo "Versions kept: $TOTAL_KEPT"
echo "Versions deleted: $TOTAL_DELETED"
echo "========================================"
