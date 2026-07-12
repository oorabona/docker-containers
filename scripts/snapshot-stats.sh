#!/usr/bin/env bash
# Daily snapshot of pull/star counts per container from Docker Hub.
# Appends to stats/dockerhub-pull-history.jsonl (idempotent per day).
#
# Usage: ./scripts/snapshot-stats.sh [namespace]
#   namespace defaults to "oorabona"
#
# SNAPSHOT_DATE_OVERRIDE (env, optional): pins the "today" bucket instead of
# recomputing it from the current UTC clock. commit-stats-snapshot.sh's retry
# loop sets this once before its first attempt — without it, a run whose
# retries straddle UTC midnight would silently switch from filling day D to
# day D+1 partway through, permanently abandoning day D's still-missing rows
# while reporting success for D+1.
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
STATS_FILE="stats/dockerhub-pull-history.jsonl"
LEGACY_STATS_FILE=".build-lineage/stats-history.jsonl"
mkdir -p "$(dirname "$STATS_FILE")"

reconcile_legacy_stats_history() {
  local today_utc="$1"

  [[ -f "$LEGACY_STATS_FILE" ]] || return 0

  local reconciliation_tmp
  reconciliation_tmp=$(mktemp)

  local -a jq_files=()
  [[ -f "$STATS_FILE" ]] && jq_files+=("$STATS_FILE")
  jq_files+=("$LEGACY_STATS_FILE")

  # Excludes today's date from the migrated set (see call site below) —
  # this is a one-time HISTORICAL backfill, never a substitute for today's
  # live fetch. Without the exclusion, a same-day row already present in the
  # legacy cache (plausible at cutover, since the old mechanism that wrote it
  # was active up until this migration) gets copied in and then read by
  # snapshot_exists_for_today as "already done", silently skipping a live
  # re-fetch and persisting a possibly hours-stale pull_count as if fresh.
  if ! jq -Rrn --arg stats_file "$STATS_FILE" --arg legacy_file "$LEGACY_STATS_FILE" --arg today "$today_utc" '
    def parsed_stats_row:
      (try fromjson catch null) as $obj
      | if ($obj | type) == "object"
          and (($obj.date? | type) == "string")
          and (($obj.container? | type) == "string")
        then
          (try ($obj.pull_count | tonumber) catch null) as $pull_count
          | (try ($obj.star_count | tonumber) catch null) as $star_count
          | if $pull_count != null and $star_count != null then
              $obj + {pull_count: $pull_count, star_count: $star_count}
            else
              null
            end
        else
          null
        end;

    reduce inputs as $line (
      {existing: {}, legacy: {}, malformed: 0};
      input_filename as $file
      | if $line == "" then
          .
        else
          ($line | parsed_stats_row) as $row
          | if $file == $stats_file then
              if $row != null then
                .existing[$row.date + "\u0000" + $row.container] = true
              else
                .
              end
            elif $file == $legacy_file then
              if $row != null then
                .legacy[$row.date + "\u0000" + $row.container] = $row
              else
                .malformed += 1
              end
            else
              .
            end
        end
    )
    | "__MALFORMED__\t\(.malformed)",
      (
        . as $state
        | [
            $state.legacy
            | to_entries[]
            | select(.key as $key | (($state.existing[$key] // false) | not))
            | select(.value.date != $today)
            | .value
          ]
        | sort_by(.date, .container)
        | .[]
        | @json
      )
  ' "${jq_files[@]}" > "$reconciliation_tmp"; then
    rm -f "$reconciliation_tmp"
    log_warning "Could not reconcile legacy Docker Hub stats entries from $LEGACY_STATS_FILE"
    return 0
  fi

  local malformed
  malformed=$(sed -n $'1s/^__MALFORMED__\t//p' "$reconciliation_tmp")
  malformed="${malformed:-0}"

  local reconciled
  reconciled=$(awk 'NR > 1 && length($0) > 0 { count++ } END { print count + 0 }' "$reconciliation_tmp")
  if [[ "$reconciled" -gt 0 ]]; then
    awk 'NR > 1 && length($0) > 0 { print }' "$reconciliation_tmp" >> "$STATS_FILE"
  fi

  rm -f "$reconciliation_tmp"

  if [[ "$reconciled" -gt 0 ]]; then
    log_info "Reconciled $reconciled legacy Docker Hub stats entries into $STATS_FILE"
  fi
  if [[ "$malformed" -gt 0 ]]; then
    log_warning "Skipped $malformed malformed legacy Docker Hub stats entries during migration"
  fi
}

today="${SNAPSHOT_DATE_OVERRIDE:-$(date -u +%Y-%m-%d)}"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

reconcile_legacy_stats_history "$today"

declare -A SNAPSHOTS_TODAY=()

load_today_snapshot_keys() {
  [[ -f "$STATS_FILE" ]] || return 0

  local container
  while IFS= read -r container; do
    [[ -n "$container" ]] && SNAPSHOTS_TODAY["$container"]=1
  done < <(
    jq -Rrn --arg date "$today" '
      def parsed_stats_row:
        (try fromjson catch null) as $obj
        | if ($obj | type) == "object"
            and (($obj.date? | type) == "string")
            and (($obj.container? | type) == "string")
          then
            (try ($obj.pull_count | tonumber) catch null) as $pull_count
            | (try ($obj.star_count | tonumber) catch null) as $star_count
            | if $pull_count != null and $star_count != null then
                $obj + {pull_count: $pull_count, star_count: $star_count}
              else
                null
              end
          else
            null
          end;

      inputs
      | select(length > 0)
      | parsed_stats_row
      | select(. != null and .date == $date)
      | .container
    ' "$STATS_FILE" 2>/dev/null || true
  )
}

snapshot_exists_for_today() {
  local container="$1"
  [[ -n "${SNAPSHOTS_TODAY[$container]:-}" ]]
}

load_today_snapshot_keys

snapshotted=0
skipped=0
failed=0

while IFS= read -r container; do
  [[ -z "$container" ]] && continue

  # Idempotent: skip if today's snapshot already exists for this container.
  if snapshot_exists_for_today "$container"; then
    skipped=$((skipped + 1))
    continue
  fi

  response=$(curl -sf --max-time 10 "https://hub.docker.com/v2/repositories/$NAMESPACE/$container/" 2>/dev/null || echo '')
  if [[ -z "$response" ]]; then
    log_warning "Failed to fetch Docker Hub stats for $container"
    failed=$((failed + 1))
    continue
  fi

  if ! counts_tsv=$(printf '%s' "$response" | jq -er '
    if type == "object"
      and (.pull_count? | type) == "number"
      and (.star_count? | type) == "number"
    then
      [.pull_count, .star_count] | @tsv
    else
      empty
    end
  ' 2>/dev/null); then
    response_snippet=$(printf '%s' "$response" | tr '\r\n\t' '   ' | cut -c1-240)
    log_warning "Unexpected Docker Hub stats response for $container; expected numeric pull_count and star_count, got: $response_snippet"
    failed=$((failed + 1))
    continue
  fi

  IFS=$'\t' read -r pull_count star_count <<< "$counts_tsv"

  jq -nc \
    --arg ts "$ts" \
    --arg date "$today" \
    --arg container "$container" \
    --argjson pull_count "$pull_count" \
    --argjson star_count "$star_count" \
    '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
    >> "$STATS_FILE"

  SNAPSHOTS_TODAY["$container"]=1
  snapshotted=$((snapshotted + 1))
done < <(list_containers)

total=0
[[ -f "$STATS_FILE" ]] && total=$(wc -l < "$STATS_FILE")

log_info "Stats snapshot: $snapshotted new, $skipped already-today, $failed failed (total entries: $total)"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
