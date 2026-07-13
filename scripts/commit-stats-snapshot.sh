#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "::error::scripts/commit-stats-snapshot.sh is CI-only; refusing to run outside GitHub Actions because it resets the worktree and rewrites origin" >&2
  exit 2
fi

# Persist-only: scripts/collect-stats-snapshot.sh already ran in a separate
# workflow job and handed this job only stats/dockerhub-pull-history.jsonl via
# an artifact. This script never re-fetches Docker Hub — it only commits and
# pushes that inert candidate data, so it never needs the collection script's
# network access at all, and the reverse holds too: collection never has these
# push credentials in scope.
#
# Hardcoded origin/master targets are safe because update-dashboard.yaml
# pins this job's checkout to refs/heads/master.
#
# On a lost push race, retry_cleanup resets the worktree to origin/master.
# The initial persist-job checkout can also be newer than the collect-job
# checkout that produced the downloaded artifact. In both cases, a candidate
# copy of what collection produced is merged into the current worktree instead
# of overwriting it, preserving whatever a concurrent run's own successful
# push may have already added.
#
# The run FAILS (exit 1) whenever it ends without a successful push. This
# job has no downstream dependents (deploy only needs build), so failing it
# is isolated and visible rather than a silent, permanently-green job that
# would otherwise mask a real regression (revoked token scope, branch
# protection change) behind routine warning text.
#
# No explicit follow-up dispatch: the calling workflow authenticates this
# push with a GitHub App installation token (required to satisfy master's
# branch protection — PR-only changes, verified signatures, status checks —
# which GITHUB_TOKEN categorically cannot). Unlike GITHUB_TOKEN, an
# App-token-authored push DOES trigger downstream workflow events, and
# `stats/**` is already in update-dashboard.yaml's own push path filter —
# so a successful push here naturally retriggers the dashboard build.

STATS_FILE="stats/dockerhub-pull-history.jsonl"
# Floor predates this JSONL dashboard history and rejects absurdly old
# candidate rows. Already-committed rows before this floor are still preserved
# verbatim by merge_candidate_into_worktree's raw-line path.
STATS_DATE_FLOOR="2020-01-01"

push_token="${STATS_PUSH_TOKEN:-}"
github_repository="${GITHUB_REPOSITORY:-}"
safe_origin_url=""
origin_restore_needed=false

if [[ -n "$github_repository" ]]; then
  safe_origin_url="https://github.com/${github_repository}.git"
fi

CANDIDATE_SOURCE_FILE="${CANDIDATE_SOURCE_FILE:-}"
CANDIDATE_FILE=$(mktemp)
STATS_DATE_CEILING=""
CONTAINER_ALLOWLIST=""

load_stats_validation_context() {
  local -a container_allowlist=()

  # Mirrors helpers/logging.sh:list_containers exactly: top-level directories
  # containing Dockerfile or Dockerfile.* are the only valid stats containers.
  mapfile -t container_allowlist < <(
    find . -maxdepth 2 \( -name "Dockerfile" -o -name "Dockerfile.*" \) | sed 's|^\./||' | cut -d'/' -f1 | sort -u
  )

  if ((${#container_allowlist[@]} > 0)); then
    CONTAINER_ALLOWLIST=$(printf '%s\n' "${container_allowlist[@]}")
  else
    CONTAINER_ALLOWLIST=""
  fi

  if ! STATS_DATE_CEILING=$(date -u -d '+1 day' +%Y-%m-%d); then
    echo "::error::Could not compute Docker stats date validation ceiling" >&2
    return 1
  fi
}

# shellcheck disable=SC2016  # jq program text; $names below are jq variables.
JQ_STATS_HELPERS='
    def parsed_json_line:
      try {ok: true, value: fromjson} catch {ok: false, value: null};

    def sortable_snapshot_ts:
      if (.ts? | type) == "string"
          and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      then
        .ts
      else
        null
      end;

    def known_stats_container:
      (. as $container | ($container_allowlist | split("\n") | index($container)) != null);

    def valid_stats_date:
      . as $date
      | ($date | type) == "string"
        and ($date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        and (try (($date | strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) == $date) catch false)
        and $date >= $stats_date_floor
        and $date <= $stats_date_ceiling;

    def nonnegative_integer:
      type == "number" and . >= 0 and . == floor;

    def parsed_stats_row:
      parsed_json_line as $parsed
      | ($parsed.value) as $obj
      | if $parsed.ok
          and ($obj | type) == "object"
          and (($obj | sortable_snapshot_ts) != null)
          and ($obj.date? | valid_stats_date)
          and ($obj.container? | known_stats_container)
          and $obj.source? == "dockerhub"
          and ($obj.pull_count? | nonnegative_integer)
          and ($obj.star_count? | nonnegative_integer)
        then
          $obj
        else
          null
        end;
'

emit_persisted_output() {
  local persisted_value="$1"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "persisted=$persisted_value" >> "$GITHUB_OUTPUT"
  fi
}

emit_still_missing_after_reconcile_output() {
  local still_missing_value="$1"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "still_missing_after_reconcile=$still_missing_value" >> "$GITHUB_OUTPUT"
  fi
}

# shellcheck disable=SC2329  # Invoked by the EXIT trap below.
cleanup() {
  if [[ "$origin_restore_needed" == "true" && -n "$safe_origin_url" ]]; then
    if ! git remote set-url origin "$safe_origin_url" >/dev/null 2>&1; then
      echo "::warning::Could not restore unauthenticated origin remote after stats snapshot"
    fi
  fi
  rm -f "$CANDIDATE_FILE"
  return 0
}
trap cleanup EXIT

if ! load_stats_validation_context; then
  emit_persisted_output false
  exit 1
fi

if [[ -n "$CANDIDATE_SOURCE_FILE" ]]; then
  if [[ ! -f "$CANDIDATE_SOURCE_FILE" ]]; then
    echo "::error::CANDIDATE_SOURCE_FILE is set but does not exist: $CANDIDATE_SOURCE_FILE"
    emit_persisted_output false
    exit 1
  fi
  cp "$CANDIDATE_SOURCE_FILE" "$CANDIDATE_FILE"
elif [[ -f "$STATS_FILE" ]]; then
  cp "$STATS_FILE" "$CANDIDATE_FILE"
else
  : > "$CANDIDATE_FILE"
fi

merge_candidate_into_worktree() {
  # Same key (date, container): later snapshot ts wins when both rows have the
  # fixed UTC format written by snapshot-stats.sh. Rows without that safely
  # string-comparable ts are no longer conforming, but if a future bug reaches
  # this tie-break without comparable timestamps, keep the already-processed
  # row instead of letting an untrusted candidate win by default. Malformed or
  # otherwise unrecognized nonblank lines already in committed stats history
  # are preserved verbatim, but candidate-only raw lines are dropped before
  # this privileged signed push path can trust them.
  #
  # Known accepted limitation: this union merge cannot represent an intentional
  # manual deletion/correction of a row racing a stale collect artifact with the
  # same (date, container) key. Tombstones or base-SHA deltas would be a larger
  # design for a narrow, non-security edge case in an append-only dashboard log.
  local merged_tmp merge_stderr_tmp

  if ! mkdir -p "$(dirname "$STATS_FILE")"; then
    echo "::warning::Could not prepare stats directory before stats candidate merge"
    return 1
  fi
  if [[ ! -f "$STATS_FILE" ]]; then
    : > "$STATS_FILE" || {
      echo "::warning::Could not create missing stats file before stats candidate merge"
      return 1
    }
  fi

  if ! merged_tmp=$(mktemp); then
    echo "::warning::Could not create temporary file for stats candidate merge"
    return 1
  fi
  if ! merge_stderr_tmp=$(mktemp); then
    echo "::warning::Could not create temporary stderr file for stats candidate merge"
    rm -f "$merged_tmp"
    return 1
  fi

  if jq -Rrn \
    --arg stats_file "$STATS_FILE" \
    --arg candidate_file "$CANDIDATE_FILE" \
    --arg container_allowlist "$CONTAINER_ALLOWLIST" \
    --arg stats_date_floor "$STATS_DATE_FLOOR" \
    --arg stats_date_ceiling "$STATS_DATE_CEILING" \
    "${JQ_STATS_HELPERS}"'
    def winning_keyed_row($current; $incoming):
      if $current == null then
        $incoming
      elif $current.source != $incoming.source then
        ($current.row | sortable_snapshot_ts) as $current_ts
        | ($incoming.row | sortable_snapshot_ts) as $incoming_ts
        | if $current_ts != null and $incoming_ts != null then
            if $incoming_ts >= $current_ts then
              $incoming
            else
              $current
            end
          else
            $current
          end
      else
        $incoming
      end;

    (reduce inputs as $line (
      {
        candidate_raw_counts: {},
        entries: [],
        keyed: {},
        next_id: 0,
        stats_raw_counts: {}
      };
      input_filename as $file
      | if $line == "" then
          .
        else
          ($line | parsed_stats_row) as $row
          | if $row != null then
              ($row.date + "\u0000" + $row.container) as $key
              | {
                  id: .next_id,
                  raw: $line,
                  row: $row,
                  source: $file
                } as $incoming
              | .keyed[$key] = winning_keyed_row((.keyed[$key] // null); $incoming)
              | .entries += [{id: .next_id, key: $key, kind: "keyed"}]
              | .next_id += 1
            elif $file == $stats_file then
              .stats_raw_counts[$line] = ((.stats_raw_counts[$line] // 0) + 1)
              | .entries += [{kind: "raw", raw: $line}]
            else
              .candidate_raw_counts[$line] = ((.candidate_raw_counts[$line] // 0) + 1)
              | if .candidate_raw_counts[$line] > (.stats_raw_counts[$line] // 0) then
                  . as $state
                  | (
                      "::warning::Dropping nonconforming candidate-only stats line before signed push"
                      | stderr
                    )
                  | $state
                else
                  .
                end
            end
        end
    )) as $state
    | $state.entries[]
    | if .kind == "raw" then
        .raw
      else
        . as $entry
        | ($state.keyed[$entry.key]) as $winner
        | select($entry.id == $winner.id)
        | if $winner.source == $candidate_file then
            ($winner.row | @json)
          else
            $winner.raw
          end
      end
  ' "$STATS_FILE" "$CANDIDATE_FILE" > "$merged_tmp" 2> "$merge_stderr_tmp"; then
    if [[ -s "$merge_stderr_tmp" ]]; then
      cat "$merge_stderr_tmp" >&2
    fi
    if mv "$merged_tmp" "$STATS_FILE"; then
      rm -f "$merge_stderr_tmp"
      return 0
    fi
    echo "::warning::Could not replace stats file after stats candidate merge"
    rm -f "$merged_tmp" "$merge_stderr_tmp"
    return 1
  fi

  echo "::warning::Could not merge collected stats candidate into the worktree"
  rm -f "$merged_tmp" "$merge_stderr_tmp"
  return 1
}

validate_stats_file_jsonl() {
  local invalid_line

  if ! invalid_line=$(jq -Rn \
    --arg container_allowlist "$CONTAINER_ALLOWLIST" \
    --arg stats_date_floor "$STATS_DATE_FLOOR" \
    --arg stats_date_ceiling "$STATS_DATE_CEILING" \
    "${JQ_STATS_HELPERS}"'
    reduce inputs as $line (
      {invalid_line_number: null, line_number: 0};
      .line_number += 1
      | if .invalid_line_number != null
          or $line == ""
          or (($line | parsed_json_line).ok)
        then
          .
        else
          .invalid_line_number = .line_number
        end
    )
    | select(.invalid_line_number != null)
    | .invalid_line_number
  ' "$STATS_FILE"); then
    echo "::warning::Could not validate stats snapshot JSONL before commit"
    return 1
  fi

  if [[ -n "$invalid_line" ]]; then
    echo "::warning::Refusing to commit stats snapshot because $STATS_FILE has invalid JSON at line $invalid_line"
    return 1
  fi

  return 0
}

compute_still_missing_after_reconcile() {
  local today_utc
  local still_missing

  if ! today_utc=$(date -u +%Y-%m-%d); then
    echo "::warning::Could not compute Docker stats completion date" >&2
    return 1
  fi

  if [[ ! -f "$STATS_FILE" ]]; then
    printf 'true\n'
    return 0
  fi

  if ! still_missing=$(jq -Rrn \
    --arg today "$today_utc" \
    --arg container_allowlist "$CONTAINER_ALLOWLIST" \
    --arg stats_date_floor "$STATS_DATE_FLOOR" \
    --arg stats_date_ceiling "$STATS_DATE_CEILING" \
    "${JQ_STATS_HELPERS}"'
    reduce inputs as $line (
      {seen: {}};
      if $line == "" then
        .
      else
        ($line | parsed_stats_row) as $row
        | if $row != null and $row.date == $today then
            .seen[$row.container] = true
          else
            .
          end
      end
    )
    | . as $state
    | ($container_allowlist | split("\n") | map(select(. != ""))) as $containers
    | ([$containers[] | select(($state.seen[.] // false) | not)] | length > 0)
  ' "$STATS_FILE"); then
    echo "::warning::Could not reconcile stats snapshot completion state" >&2
    return 1
  fi

  case "$still_missing" in
    true|false)
      printf '%s\n' "$still_missing"
      ;;
    *)
      echo "::warning::Unexpected stats snapshot completion state: $still_missing" >&2
      return 1
      ;;
  esac
}

sleep_before_retry() {
  local attempt="$1"

  if [[ "$attempt" -lt 3 ]]; then
    if ! sleep $((attempt * 5)); then
      echo "::warning::Stats snapshot retry sleep failed after attempt $attempt"
    fi
  fi
}

retry_cleanup() {
  local attempt="$1"
  local committed="$2"
  local reset_failed=false

  if [[ "$committed" == "true" ]]; then
    if ! git reset --hard HEAD~1; then
      echo "::warning::Could not discard failed stats commit on attempt $attempt"
      reset_failed=true
    fi
  fi

  if ! git fetch origin master; then
    echo "::warning::Could not fetch origin/master after stats snapshot attempt $attempt"
  fi

  if ! git reset --hard origin/master; then
    echo "::warning::Could not reset stats snapshot worktree after attempt $attempt"
    reset_failed=true
  fi

  if [[ "$reset_failed" == "true" ]]; then
    return 1
  fi

  if ! merge_candidate_into_worktree; then
    return 1
  fi

  sleep_before_retry "$attempt"
}

# Deliberately no local `git config user.name/email` here — the calling
# workflow's GPG-import step sets the committer identity globally, matching
# the identity the signing key is bound to. A local override here (local
# config wins over global) would silently produce commits attributed to a
# name the GPG key doesn't sign for, defeating the "required_signatures"
# branch protection rule this job depends on.
if [[ -n "$push_token" && -n "$github_repository" ]]; then
  origin_restore_needed=true
  if ! git remote set-url origin "https://x-access-token:${push_token}@github.com/${github_repository}.git"; then
    echo "::warning::Could not configure authenticated origin remote for stats snapshot"
  fi
else
  echo "::warning::Missing push token or repository; stats snapshot push may not be authenticated"
fi

persisted=false
if merge_candidate_into_worktree; then
  for attempt in 1 2 3; do
    if git diff --quiet HEAD -- "$STATS_FILE"; then
      persisted=true
      break
    else
      diff_status=$?
      if [[ "$diff_status" -gt 1 ]]; then
        echo "::warning::Could not inspect stats snapshot diff on attempt $attempt"
        if ! retry_cleanup "$attempt" "false"; then
          break
        fi
        continue
      fi
    fi

    if ! validate_stats_file_jsonl; then
      if ! retry_cleanup "$attempt" "false"; then
        break
      fi
      continue
    fi

    if ! git add "$STATS_FILE"; then
      echo "::warning::Could not stage stats snapshot on attempt $attempt"
      if ! retry_cleanup "$attempt" "false"; then
        break
      fi
      continue
    fi

    if ! git commit -m "chore(stats): daily Docker Hub pull-count snapshot" -- "$STATS_FILE"; then
      echo "::warning::Could not commit stats snapshot on attempt $attempt"
      if ! retry_cleanup "$attempt" "false"; then
        break
      fi
      continue
    fi

    if git push origin master; then
      persisted=true
      break
    fi

    # Lost the race (or lack permission) — discard this attempt and retry
    # clean, re-merging this run's own candidate data back in afterward.
    if ! retry_cleanup "$attempt" "true"; then
      break
    fi
  done
fi

emit_persisted_output "$persisted"

still_missing_after_reconcile=true
if [[ "$persisted" == "true" ]]; then
  if ! still_missing_after_reconcile=$(compute_still_missing_after_reconcile); then
    still_missing_after_reconcile=true
  fi
fi
emit_still_missing_after_reconcile_output "$still_missing_after_reconcile"

if [[ "$persisted" != "true" ]]; then
  echo "::error::Could not persist stats snapshot this run — another same-day direct trigger may still cover it"
  exit 1
fi

exit 0
