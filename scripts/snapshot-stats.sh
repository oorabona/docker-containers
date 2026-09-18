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
# shellcheck disable=SC1091
source "$ROOT_DIR/helpers/logging.sh"
# shellcheck source=../helpers/collect-lines.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/helpers/collect-lines.sh"

# Anchor relative snapshot paths and no-argument container enumeration at the repository root.
cd "$ROOT_DIR"

NAMESPACE="${1:-oorabona}"
STATS_FILE="stats/dockerhub-pull-history.jsonl"
LEGACY_STATS_FILE=".build-lineage/stats-history.jsonl"
mkdir -p "$(dirname "$STATS_FILE")"

reconcile_legacy_stats_history() {
  local today_utc="$1"
  local append_status

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
    # These checks improve diagnostics; they do not make either append atomic.
    if awk 'NR > 1 && length($0) > 0 { print }' "$reconciliation_tmp" >> "$STATS_FILE"; then
      :
    else
      append_status=$?
      log_error "Could not append reconciled Docker Hub stats entries to $STATS_FILE"
      if ! rm -f "$reconciliation_tmp"; then
        log_warning "Could not remove legacy reconciliation file $reconciliation_tmp"
      fi
      return "$append_status"
    fi
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

  local snapshot_keys_file read_status
  snapshot_keys_file=$(mktemp "${TMPDIR:-/tmp}/snapshot-stats-keys.XXXXXX") || {
    log_error "Could not create existing snapshot state file in ${TMPDIR:-/tmp}"
    return 1
  }

  if jq -Rrn --arg date "$today" '
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
    ' "$STATS_FILE" > "$snapshot_keys_file"; then
    :
  else
    read_status=$?
    if ! rm -f "$snapshot_keys_file"; then
      log_warning "Could not remove existing snapshot state file $snapshot_keys_file"
    fi
    return "$read_status"
  fi

  local -a snapshot_keys
  if mapfile -t snapshot_keys < "$snapshot_keys_file"; then
    :
  else
    read_status=$?
    if ! rm -f "$snapshot_keys_file"; then
      log_warning "Could not remove existing snapshot state file $snapshot_keys_file"
    fi
    return "$read_status"
  fi
  if ! rm -f "$snapshot_keys_file"; then
    log_warning "Could not remove existing snapshot state file $snapshot_keys_file"
  fi

  local container
  for container in "${snapshot_keys[@]}"; do
    [[ -n "$container" ]] && SNAPSHOTS_TODAY["$container"]=1
  done
}

snapshot_exists_for_today() {
  local container="$1"
  [[ -n "${SNAPSHOTS_TODAY[$container]:-}" ]]
}

if ! load_today_snapshot_keys; then
  log_error "Cannot read existing snapshot state; refusing duplicate collection"
  exit 1
fi

snapshotted=0
skipped=0
failed=0

container_list_file=$(mktemp "${TMPDIR:-/tmp}/snapshot-stats-containers.XXXXXX") || {
  echo "::error::Could not create container enumeration file in ${TMPDIR:-/tmp}" >&2
  exit 1
}
if collect_lines "$container_list_file" -- list_containers; then
  :
else
  enumeration_status=$?
  if ! rm -f "$container_list_file"; then
    echo "::warning::Could not remove container enumeration file $container_list_file" >&2
  fi
  echo "::error::Failed to enumerate containers" >&2
  exit "$enumeration_status"
fi

declare -a containers
if mapfile -t containers < "$container_list_file"; then
  :
else
  read_status=$?
  if ! rm -f "$container_list_file"; then
    echo "::warning::Could not remove container enumeration file $container_list_file" >&2
  fi
  echo "::error::Failed to open container enumeration file $container_list_file" >&2
  exit "$read_status"
fi
if ! rm -f "$container_list_file"; then
  echo "::warning::Could not remove container enumeration file $container_list_file" >&2
fi

if [[ "${#containers[@]}" -gt 0 ]]; then
  has_container=0
  for container in "${containers[@]}"; do
    if [[ "$container" =~ [^[:space:]] ]]; then
      has_container=1
      break
    fi
  done
  if [[ "$has_container" -eq 0 ]]; then
    echo "::error::Container enumeration contains only whitespace" >&2
    exit 1
  fi
fi

for container in "${containers[@]}"; do
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

  if jq -nc \
      --arg ts "$ts" \
      --arg date "$today" \
      --arg container "$container" \
      --argjson pull_count "$pull_count" \
      --argjson star_count "$star_count" \
      '{ts: $ts, date: $date, container: $container, pull_count: $pull_count, star_count: $star_count, source: "dockerhub"}' \
      >> "$STATS_FILE"; then
    :
  else
    append_status=$?
    log_error "Could not append Docker Hub stats entry to $STATS_FILE"
    exit "$append_status"
  fi

  SNAPSHOTS_TODAY["$container"]=1
  snapshotted=$((snapshotted + 1))
done

total=0
[[ -f "$STATS_FILE" ]] && total=$(wc -l < "$STATS_FILE")

log_info "Stats snapshot: $snapshotted new, $skipped already-today, $failed failed (total entries: $total)"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
