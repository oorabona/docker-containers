#!/usr/bin/env bash
# Daily snapshot of pull/star counts per container from Docker Hub.
# Appends to .build-lineage/stats-history.jsonl (idempotent per day).
#
# Usage: ./scripts/snapshot-stats.sh [namespace]
#   namespace defaults to "oorabona"
#
# JSONL line shape:
#   {"ts":"<ISO8601>","date":"YYYY-MM-DD","container":"<name>","pull_count":<n>,"star_count":<n>,"source":"dockerhub"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../helpers/logging.sh
source "$ROOT_DIR/helpers/logging.sh"

# list_containers uses relative paths; run from repo root.
cd "$ROOT_DIR"

NAMESPACE="${1:-oorabona}"
STATS_FILE=".build-lineage/stats-history.jsonl"
mkdir -p .build-lineage

today=$(date -u +%Y-%m-%d)
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

snapshotted=0
skipped=0
failed=0

while IFS= read -r container; do
  [[ -z "$container" ]] && continue

  # Idempotent: skip if today's snapshot already exists for this container.
  # Field order in JSONL is not guaranteed, so check both substrings on the same line.
  if [[ -f "$STATS_FILE" ]] && \
     grep -F "\"container\":\"$container\"" "$STATS_FILE" 2>/dev/null | \
     grep -qF "\"date\":\"$today\""; then
    skipped=$((skipped + 1))
    continue
  fi

  response=$(curl -sf --max-time 10 "https://hub.docker.com/v2/repositories/$NAMESPACE/$container/" 2>/dev/null || echo '')
  if [[ -z "$response" ]]; then
    log_warning "Failed to fetch Docker Hub stats for $container"
    failed=$((failed + 1))
    continue
  fi

  pull_count=$(echo "$response" | jq -r '.pull_count // 0')
  star_count=$(echo "$response" | jq -r '.star_count // 0')

  jq -nc \
    --arg ts "$ts" \
    --arg date "$today" \
    --arg container "$container" \
    --argjson pull_count "$pull_count" \
    --argjson star_count "$star_count" \
    '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
    >> "$STATS_FILE"

  snapshotted=$((snapshotted + 1))
done < <(list_containers)

total=0
[[ -f "$STATS_FILE" ]] && total=$(wc -l < "$STATS_FILE")

log_info "Stats snapshot: $snapshotted new, $skipped already-today, $failed failed (total entries: $total)"
