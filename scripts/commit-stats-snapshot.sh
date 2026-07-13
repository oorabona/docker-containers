#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "::error::scripts/commit-stats-snapshot.sh is CI-only; refusing to run outside GitHub Actions because it opens and auto-merges stats PRs" >&2
  exit 2
fi

# Persist-only: scripts/collect-stats-snapshot.sh already ran in a separate
# workflow job and handed this job only stats/dockerhub-pull-history.jsonl via
# an artifact. This script never re-fetches Docker Hub — it only commits and
# pushes that inert candidate data, so it never needs the collection script's
# network access at all, and the reverse holds too: collection never has these
# push credentials in scope.
#
# Hardcoded origin/master targets are safe because update-dashboard.yaml pins
# this job's checkout to refs/heads/master and each run pushes a unique PR
# branch named from the workflow run id, workflow attempt, and local retry
# attempt.
#
# On every persist attempt, the worktree is reset to freshly-fetched
# origin/master before the immutable candidate copy of what collection produced
# is merged in. That preserves whatever a concurrent run's own successful PR
# may have already added while still carrying this run's candidate forward after
# a stale PR, transient git/GitHub failure, or retry.
#
# The run FAILS (exit 1) whenever it ends without a fully merged PR. This
# job has no downstream dependents (deploy only needs build), so failing it
# is isolated and visible rather than a silent, permanently-green job that
# would otherwise mask a real regression (revoked token scope, branch
# protection change) behind routine warning text.
#
# No explicit follow-up dispatch: the calling workflow authenticates the PR
# branch push and PR merge with a GitHub App installation token. Unlike
# GITHUB_TOKEN, App-token-authored PRs and squash-merge pushes DO trigger
# downstream workflow events; `stats/**` is already in update-dashboard.yaml's
# own push path filter, so a successful squash merge naturally retriggers the
# dashboard build.

STATS_FILE="stats/dockerhub-pull-history.jsonl"
# Floor predates this JSONL dashboard history and rejects absurdly old
# candidate rows. Already-committed rows before this floor are still preserved
# verbatim by merge_candidate_into_worktree's raw-line path.
STATS_DATE_FLOOR="2020-01-01"
STATS_PERSIST_MAX_ATTEMPTS=3
# Three consecutive PR view failures tolerates a brief GitHub API/CLI hiccup
# across multiple polls while bounding time spent on an unknowable PR state.
STATS_PR_VIEW_MAX_FAILURES="${STATS_PR_VIEW_MAX_FAILURES:-3}"
STATS_PR_MIN_MERGE_WAIT_SECONDS="${STATS_PR_MIN_MERGE_WAIT_SECONDS:-30}"

push_token="${STATS_PUSH_TOKEN:-}"
github_repository="${GITHUB_REPOSITORY:-}"
stats_pr_branch="${STATS_PR_BRANCH:-}"
safe_origin_url=""
origin_restore_needed=false

if [[ -z "$stats_pr_branch" && -n "${GITHUB_RUN_ID:-}" ]]; then
  if [[ -n "${GITHUB_RUN_ATTEMPT:-}" ]]; then
    stats_pr_branch="bot/stats-snapshot-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  else
    stats_pr_branch="bot/stats-snapshot-${GITHUB_RUN_ID}"
  fi
fi

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
  # this privileged signed PR path can trust them.
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
                      "::warning::Dropping nonconforming candidate-only stats line before signed PR"
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

delete_remote_pr_branch() {
  local branch="$1"

  if [[ -z "$branch" ]]; then
    return 0
  fi

  if ! git push origin --delete "$branch" >/dev/null 2>&1; then
    echo "::warning::Could not delete stale stats snapshot branch $branch after failure"
    return 1
  fi

  return 0
}

cleanup_failed_pr() {
  local pr_number="$1"
  local pr_branch="$2"
  local remote_branch_maybe_pushed="$3"

  if [[ -n "$pr_number" ]]; then
    if ! gh pr close "$pr_number" --delete-branch 2>&1; then
      echo "::warning::Could not close stale stats snapshot PR #$pr_number or delete branch $pr_branch after failure"
      if [[ "$remote_branch_maybe_pushed" == "true" ]]; then
        delete_remote_pr_branch "$pr_branch" || true
      fi
    fi
    return 0
  fi

  if [[ "$remote_branch_maybe_pushed" == "true" ]]; then
    delete_remote_pr_branch "$pr_branch" || true
  fi
}

parse_created_pr_number() {
  local pr_branch="$1"
  local pr_create_output="$2"
  local parsed_number

  parsed_number=$(printf '%s\n' "$pr_create_output" | sed -nE 's#.*github.com/[^[:space:]]+/pull/([0-9]+).*#\1#p' | tail -1)
  if [[ "$parsed_number" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$parsed_number"
    return 0
  fi

  if parsed_number=$(gh pr view "$pr_branch" --json number --jq '.number' 2>&1) && [[ "$parsed_number" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$parsed_number"
    return 0
  fi

  echo "::warning::Could not determine stats snapshot PR number after creation" >&2
  return 1
}

wait_for_pr_merge() {
  local pr_number="$1"
  local deadline_epoch="$2"
  local poll_seconds="$3"
  local max_query_failures="$4"
  local consecutive_query_failures=0
  local now_epoch pr_view remaining_seconds sleep_seconds state merged_at

  while true; do
    if ! now_epoch=$(date +%s); then
      echo "::warning::Could not read wall-clock time while waiting for stats snapshot PR #$pr_number"
      return 1
    fi
    remaining_seconds=$((deadline_epoch - now_epoch))
    if ((remaining_seconds <= 0)); then
      echo "::warning::Timed out waiting for stats snapshot PR #$pr_number to merge"
      return 1
    fi

    if ! pr_view=$(gh pr view "$pr_number" --json state,mergedAt --jq '[.state, (.mergedAt // "")] | @tsv' 2>&1); then
      consecutive_query_failures=$((consecutive_query_failures + 1))
      printf '%s\n' "$pr_view" >&2
      if ((consecutive_query_failures >= max_query_failures)); then
        echo "::warning::Could not inspect stats snapshot PR #$pr_number merge state after $consecutive_query_failures consecutive attempt(s)"
        return 1
      fi
      echo "::warning::Could not inspect stats snapshot PR #$pr_number merge state (attempt $consecutive_query_failures/$max_query_failures); continuing within the remaining wait budget"
    else
      consecutive_query_failures=0

      IFS=$'\t' read -r state merged_at <<< "$pr_view"
      if [[ "$state" == "MERGED" || -n "${merged_at:-}" ]]; then
        echo "::notice::Stats snapshot PR #$pr_number merged"
        return 0
      fi

      if [[ "$state" == "CLOSED" ]]; then
        echo "::warning::Stats snapshot PR #$pr_number closed without merging"
        return 1
      fi
    fi

    if ! now_epoch=$(date +%s); then
      echo "::warning::Could not read wall-clock time while waiting for stats snapshot PR #$pr_number"
      return 1
    fi
    remaining_seconds=$((deadline_epoch - now_epoch))
    if ((remaining_seconds <= 0)); then
      echo "::warning::Timed out waiting for stats snapshot PR #$pr_number to merge"
      return 1
    fi

    sleep_seconds="$poll_seconds"
    if ((sleep_seconds > remaining_seconds)); then
      sleep_seconds="$remaining_seconds"
    fi
    if ! sleep "$sleep_seconds"; then
      echo "::warning::Stats snapshot PR merge polling sleep failed"
      return 1
    fi
  done
}

validate_pr_budget_config() {
  local total_budget_seconds="$1"
  local min_wait_seconds="$2"
  local poll_seconds="$3"
  local max_query_failures="$4"

  if ! [[ "$total_budget_seconds" =~ ^[0-9]+$ ]] ||
      ! [[ "$min_wait_seconds" =~ ^[0-9]+$ ]] ||
      ! [[ "$poll_seconds" =~ ^[0-9]+$ ]] ||
      ! [[ "$max_query_failures" =~ ^[0-9]+$ ]] ||
      [[ "$poll_seconds" -eq 0 ]] ||
      [[ "$max_query_failures" -eq 0 ]]; then
    echo "::warning::Invalid stats PR merge polling configuration"
    return 1
  fi
}

remaining_pr_budget_seconds() {
  local deadline_epoch="$1"
  local now_epoch

  if ! now_epoch=$(date +%s); then
    echo "::warning::Could not read wall-clock time for stats snapshot PR budget" >&2
    printf '0\n'
    return 1
  fi

  if ((now_epoch >= deadline_epoch)); then
    printf '0\n'
  else
    printf '%s\n' "$((deadline_epoch - now_epoch))"
  fi
}

sleep_before_retry() {
  local attempt="$1"
  local deadline_epoch="$2"
  local remaining_seconds sleep_seconds

  if [[ "$attempt" -lt "$STATS_PERSIST_MAX_ATTEMPTS" ]]; then
    if ! remaining_seconds=$(remaining_pr_budget_seconds "$deadline_epoch"); then
      remaining_seconds=0
    fi
    if ((remaining_seconds <= 0)); then
      return 0
    fi

    sleep_seconds=$((attempt * 5))
    if ((sleep_seconds > remaining_seconds)); then
      sleep_seconds="$remaining_seconds"
    fi

    if ! sleep "$sleep_seconds"; then
      echo "::warning::Stats snapshot retry sleep failed after attempt $attempt"
    fi
  fi
}

reset_worktree_to_fresh_master() {
  local attempt="$1"

  if ! git fetch --force origin refs/heads/master:refs/remotes/origin/master; then
    echo "::warning::Could not fetch origin/master before stats snapshot attempt $attempt"
    return 1
  fi

  if ! git reset --hard origin/master; then
    echo "::warning::Could not reset stats snapshot worktree before attempt $attempt"
    return 1
  fi
}

ensure_stats_snapshot_pr() {
  local pr_branch="$1"
  local pr_create_output
  local pr_number

  if ! pr_create_output=$(gh pr create \
      --base master \
      --head "$pr_branch" \
      --title "chore(stats): daily Docker Hub pull-count snapshot" \
      --body "Automated Docker Hub pull-count snapshot for this workflow run." 2>&1); then
    printf '%s\n' "$pr_create_output" >&2
    echo "::warning::Could not create stats snapshot PR from $pr_branch" >&2
    if pr_number=$(parse_created_pr_number "$pr_branch" "$pr_create_output"); then
      echo "::notice::Using existing stats snapshot PR #$pr_number for $pr_branch" >&2
      printf '%s\n' "$pr_number"
      return 0
    fi
    return 1
  fi
  printf '%s\n' "$pr_create_output" >&2

  if ! pr_number=$(parse_created_pr_number "$pr_branch" "$pr_create_output"); then
    return 1
  fi
  printf '%s\n' "$pr_number"
}

persist_stats_snapshot_via_pr() {
  # The surrounding GitHub Actions job has a 45-minute hard timeout. This
  # function enforces one shared 35-minute wall-clock budget across all retry
  # attempts (legacy STATS_PR_MERGE_TIMEOUT_SECONDS still overrides the default)
  # so cleanup and output emission run before the job-level timeout can kill us.
  local total_budget_seconds="${STATS_PR_TOTAL_BUDGET_SECONDS:-${STATS_PR_MERGE_TIMEOUT_SECONDS:-2100}}"
  local min_wait_seconds="$STATS_PR_MIN_MERGE_WAIT_SECONDS"
  local poll_seconds="${STATS_PR_MERGE_POLL_SECONDS:-10}"
  local max_query_failures="$STATS_PR_VIEW_MAX_FAILURES"
  local attempt attempt_pr_branch attempt_pr_number attempt_remote_branch_maybe_pushed
  local deadline_epoch diff_status head_commit remaining_seconds start_epoch
  local attempts_remaining attempt_wait_epoch now_epoch_for_attempt_cap

  if [[ -z "$stats_pr_branch" ]]; then
    echo "::warning::GITHUB_RUN_ID or STATS_PR_BRANCH is required to name the stats snapshot PR branch"
    return 1
  fi

  if ! validate_pr_budget_config "$total_budget_seconds" "$min_wait_seconds" "$poll_seconds" "$max_query_failures"; then
    return 1
  fi

  if ! start_epoch=$(date +%s); then
    echo "::warning::Could not read wall-clock time before stats snapshot PR attempts"
    return 1
  fi
  deadline_epoch=$((start_epoch + total_budget_seconds))

  for ((attempt = 1; attempt <= STATS_PERSIST_MAX_ATTEMPTS; attempt++)); do
    if ! remaining_seconds=$(remaining_pr_budget_seconds "$deadline_epoch"); then
      remaining_seconds=0
    fi
    if ((remaining_seconds < min_wait_seconds)); then
      echo "::warning::Not enough stats PR budget remains before attempt $attempt (${remaining_seconds}s left, need at least ${min_wait_seconds}s)"
      return 1
    fi

    attempt_pr_branch="${stats_pr_branch}-attempt-${attempt}"
    attempt_pr_number=""
    attempt_remote_branch_maybe_pushed=false

    if ! reset_worktree_to_fresh_master "$attempt"; then
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! merge_candidate_into_worktree; then
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if git diff --quiet HEAD -- "$STATS_FILE"; then
      return 0
    else
      diff_status=$?
      if [[ "$diff_status" -gt 1 ]]; then
        echo "::warning::Could not inspect stats snapshot diff on attempt $attempt"
        sleep_before_retry "$attempt" "$deadline_epoch"
        continue
      fi
    fi

    if ! validate_stats_file_jsonl; then
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! git checkout -B "$attempt_pr_branch"; then
      echo "::warning::Could not create or reset stats snapshot branch $attempt_pr_branch on attempt $attempt"
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! git add "$STATS_FILE"; then
      echo "::warning::Could not stage stats snapshot on attempt $attempt"
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! git commit -m "chore(stats): daily Docker Hub pull-count snapshot" -- "$STATS_FILE"; then
      echo "::warning::Could not commit stats snapshot on attempt $attempt"
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! head_commit=$(git rev-parse HEAD); then
      echo "::warning::Could not resolve stats snapshot head commit on attempt $attempt"
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! git push --force origin "HEAD:${attempt_pr_branch}"; then
      echo "::warning::Could not push stats snapshot branch $attempt_pr_branch on attempt $attempt"
      cleanup_failed_pr "" "$attempt_pr_branch" true
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi
    attempt_remote_branch_maybe_pushed=true

    if ! attempt_pr_number=$(ensure_stats_snapshot_pr "$attempt_pr_branch"); then
      cleanup_failed_pr "" "$attempt_pr_branch" "$attempt_remote_branch_maybe_pushed"
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    if ! sleep 2; then
      echo "::warning::Stats snapshot PR label delay failed on attempt $attempt"
    elif ! gh pr edit "$attempt_pr_number" --add-label "automation" 2>&1; then
      echo "::warning::Failed to apply automation label to stats snapshot PR #${attempt_pr_number}; PR created successfully — continuing"
    fi

    if gh pr merge "$attempt_pr_number" --squash --auto --delete-branch --match-head-commit "$head_commit" 2>&1; then
      echo "::notice::Auto-merge enabled for stats snapshot PR #$attempt_pr_number"
    else
      echo "::warning::Failed to enable auto-merge for stats snapshot PR #$attempt_pr_number on attempt $attempt"
      cleanup_failed_pr "$attempt_pr_number" "$attempt_pr_branch" "$attempt_remote_branch_maybe_pushed"
      sleep_before_retry "$attempt" "$deadline_epoch"
      continue
    fi

    # Cap THIS attempt's own wait to a fair share of whatever budget remains,
    # not the full shared deadline — otherwise a single blocked/conflicted PR
    # (the most likely trigger for a retry at all, since it happens exactly
    # when a sibling stats PR merges first) can burn the entire budget on one
    # wait, leaving nothing for the attempts that exist specifically to
    # recover from that case. Recomputed fresh each attempt (not a fixed
    # 1/max_attempts of the original total) so an attempt that fails fast
    # doesn't shrink what's available to the ones after it.
    attempts_remaining=$((STATS_PERSIST_MAX_ATTEMPTS - attempt + 1))
    if ! remaining_seconds=$(remaining_pr_budget_seconds "$deadline_epoch"); then
      remaining_seconds=0
    fi
    if ! now_epoch_for_attempt_cap=$(date +%s); then
      now_epoch_for_attempt_cap="$deadline_epoch"
    fi
    attempt_wait_epoch=$((now_epoch_for_attempt_cap + remaining_seconds / attempts_remaining))
    if ((attempt_wait_epoch > deadline_epoch)); then
      attempt_wait_epoch="$deadline_epoch"
    fi

    if wait_for_pr_merge "$attempt_pr_number" "$attempt_wait_epoch" "$poll_seconds" "$max_query_failures"; then
      return 0
    fi

    cleanup_failed_pr "$attempt_pr_number" "$attempt_pr_branch" "$attempt_remote_branch_maybe_pushed"
    sleep_before_retry "$attempt" "$deadline_epoch"
  done

  return 1
}

# Deliberately no local `git config user.name/email` here — the calling
# workflow's GPG-import step sets the committer identity globally, matching
# the identity the signing key is bound to. A local override here (local
# config wins over global) would silently produce commits attributed to a
# name the GPG key doesn't sign for, defeating the "required_signatures"
# branch protection rule this job depends on.
if [[ -n "$push_token" && -n "$github_repository" ]]; then
  export GH_TOKEN="$push_token"
  origin_restore_needed=true
  if ! git remote set-url origin "https://x-access-token:${push_token}@github.com/${github_repository}.git"; then
    echo "::warning::Could not configure authenticated origin remote for stats snapshot"
  fi
else
  echo "::warning::Missing push token or repository; stats snapshot push may not be authenticated"
fi

persisted=false
if persist_stats_snapshot_via_pr; then
  persisted=true
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
  echo "::error::Could not persist stats snapshot this run — another same-day trigger may still cover it"
  exit 1
fi

exit 0
