#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "::error::scripts/commit-stats-snapshot.sh is CI-only; refusing to run outside GitHub Actions because it resets the worktree and rewrites origin" >&2
  exit 2
fi

# This job deliberately re-fetches Docker Hub stats instead of consuming build artifacts; the duplicate read is cheap and avoids cross-job coupling.
# Hardcoded origin/master targets are safe because update-dashboard.yaml pins this job's checkout to refs/heads/master.
#
# Snapshot persistence is attempted best-effort by every direct update-dashboard
# invocation (schedule, push, workflow_dispatch on master, and filtered
# workflow_run), not only by the 07:00 UTC cron. A missed schedule attempt is
# usually recovered by a same-day post-build workflow_run with a fresh checkout
# and retry loop. The genuinely irrecoverable data-loss case is narrower: a UTC
# day with zero container builds, where the schedule run is the only invocation
# and all 3 persistence attempts are exhausted before midnight. A successful bot
# commit also does not retrigger the Pages deploy by itself, so the deployed UI
# can lag the committed snapshot until a later normal dashboard trigger; this is
# a freshness lag, not a data-loss path.
#
# A successful push does not end the loop by itself when that attempt's own
# snapshot was only partial (some containers failed to fetch) — the loop keeps
# retrying the still-missing containers with its remaining attempts. This is
# safe against data loss: origin/master already has whatever was pushed, and
# retry_cleanup's "reset --hard origin/master" only ever discards a LATER
# attempt's uncommitted work, never data that already made it to origin.
# `still_missing` tracks confirmed end-of-run state (not just the first
# success) so the final outcome reflects reality even when an earlier attempt
# already persisted something.
#
# The run FAILS (exit 1) whenever it ends with anything still missing —
# whether nothing was ever pushed or only a partial persist landed. This job
# has no downstream dependents (deploy only needs build), so failing it is
# isolated and visible rather than a silent, permanently-green job that
# would otherwise mask a real regression (revoked token scope, branch
# protection change) behind the same warning text a routine Docker Hub
# hiccup produces. A day where only external fetches were flaky still
# self-heals via the next day's idempotent retry; a day where NOTHING can be
# pushed at all needs a human to notice, which a green job would hide.
#
# A genuine change to origin/master's content (not just a same-day idempotent
# no-op) also best-effort triggers a follow-up dashboard build so the
# deployed trend doesn't wait for the next independent trigger — a bot
# commit via GITHUB_TOKEN cannot retrigger the `push` path itself (documented
# GitHub anti-loop behavior), so this uses an explicit workflow_dispatch
# instead. Detected via a before/after hash of origin/master's ACTUAL content
# (remote_stats_hash, a fresh fetch + `git show`), not tracking `git push`'s
# own exit code or the local worktree: an ambiguous network failure (the
# remote accepts the push but the client never sees the ack) reports failure
# locally even though origin DID change, and the local worktree can itself
# diverge from origin under compound cleanup failures (retry_cleanup's own
# fetch/reset are warn-and-continue, not hard stops) — querying origin
# directly at both ends is immune to either misreading. If the hash check
# itself is degraded (either fetch failed, distinguished from a CONFIRMED
# empty file via the REMOTE_HASH_UNKNOWN sentinel), the dispatch decision
# falls back to whether a `git push` command reported success this run
# (push_confirmed) rather than risk a raw comparison against an unknown
# baseline in either direction.

github_token="${GITHUB_TOKEN:-}"
github_repository="${GITHUB_REPOSITORY:-}"
safe_origin_url=""

if [[ -n "$github_repository" ]]; then
  safe_origin_url="https://github.com/${github_repository}.git"
fi

restore_origin_remote() {
  [[ -n "$safe_origin_url" ]] || return 0
  git remote set-url origin "$safe_origin_url" >/dev/null 2>&1 || true
}

sleep_before_retry() {
  local attempt="$1"

  if [[ "$attempt" -lt 3 ]]; then
    if ! sleep $((attempt * 5)); then
      echo "::warning::Stats snapshot retry sleep failed after attempt $attempt"
    fi
  fi
}

# Hashes origin/master's ACTUAL current content for the stats file via a
# fresh fetch + `git show`, never the local worktree. The local file is only
# a reliable proxy for origin's state when every cleanup fetch/reset in this
# run has succeeded — retry_cleanup treats those as warnings, not hard
# failures, so under compound git-operation failures the local worktree can
# diverge from what's really on origin in either direction (missing a
# landed-but-ambiguous push, or still holding rows that never actually
# pushed). Querying origin directly is immune to that assumption.
#
# Returns the sentinel REMOTE_HASH_UNKNOWN (never a real sha256sum output —
# always exactly 64 lowercase hex chars) when the fetch itself fails, kept
# distinct from a CONFIRMED "the file is empty/absent" hash. Conflating the
# two would let a lucky-then-unlucky fetch pair (or vice versa) misfire the
# dispatch decision in either direction — the caller must never compare an
# UNKNOWN reading against anything, only fall back to a different signal.
REMOTE_HASH_UNKNOWN="unknown"
remote_stats_hash() {
  # Called via command substitution — anything this function writes to
  # stdout becomes the caller's captured value, so diagnostics MUST go to
  # stderr or they'd silently corrupt the hash instead of surfacing as a
  # real warning.
  if ! git fetch origin master >/dev/null 2>&1; then
    echo "::warning::Could not fetch origin/master to check remote stats state" >&2
    printf '%s' "$REMOTE_HASH_UNKNOWN"
    return
  fi
  git show origin/master:stats/dockerhub-pull-history.jsonl 2>/dev/null | sha256sum | awk '{print $1}' || true
}

retry_cleanup() {
  local attempt="$1"
  local committed="$2"

  if [[ "$committed" == "true" ]]; then
    if ! git reset --hard HEAD~1; then
      echo "::warning::Could not discard failed stats commit on attempt $attempt"
    fi
  fi

  if ! git fetch origin master; then
    echo "::warning::Could not fetch origin/master after stats snapshot attempt $attempt"
  fi

  if ! git reset --hard origin/master; then
    echo "::warning::Could not reset stats snapshot worktree after attempt $attempt"
  fi

  sleep_before_retry "$attempt"
}

trap restore_origin_remote EXIT

if ! git config user.name "github-actions[bot]"; then
  echo "::warning::Could not configure git user.name for stats snapshot"
fi
if ! git config user.email "github-actions[bot]@users.noreply.github.com"; then
  echo "::warning::Could not configure git user.email for stats snapshot"
fi
if [[ -n "$github_token" && -n "$github_repository" ]]; then
  if ! git remote set-url origin "https://x-access-token:${github_token}@github.com/${github_repository}.git"; then
    echo "::warning::Could not configure authenticated origin remote for stats snapshot"
  fi
else
  echo "::warning::Missing GitHub token or repository; stats snapshot push may not be authenticated"
fi

# Pinned once, before the first attempt, so all 3 retries — including any
# that happen to fire after a UTC midnight rollover mid-run — stay focused on
# THIS run's day rather than silently switching to a fresh "today" partway
# through. See snapshot-stats.sh's SNAPSHOT_DATE_OVERRIDE doc comment.
export SNAPSHOT_DATE_OVERRIDE
SNAPSHOT_DATE_OVERRIDE="$(date -u +%Y-%m-%d)"

initial_stats_hash="$(remote_stats_hash)"

persisted=false
# Pessimistic by default: only cleared at the two points below where we have
# actually CONFIRMED the run ends with nothing outstanding (full fetch AND
# either nothing new to push or a successful push). Every other path —
# fetch failure, diff-inspection failure, add/commit/push failure, or even a
# FULLY successful fetch whose subsequent git operations then fail — leaves
# this true, so the final outcome reflects reality regardless of which
# attempt an earlier successful partial push happened on.
still_missing=true
# Narrower than `persisted` (which also becomes true via the "nothing new,
# already done" no-op) — set true ONLY when a `git push` command itself
# reports success this run. Used solely as the fallback dispatch signal when
# the remote hash check is degraded (see the final dispatch decision below);
# the hash comparison remains the primary, more reliable signal whenever
# both its fetches succeed.
push_confirmed=false
for attempt in 1 2 3; do
  snapshot_failed=false
  if ! ./scripts/snapshot-stats.sh; then
    snapshot_failed=true
    echo "::warning::Stats snapshot collection failed on attempt $attempt; some containers failed, but valid rows from successful containers will still be considered for commit"
  fi

  # HEAD (not index) comparison: catches a change staged-but-not-committed by
  # a prior attempt that failed between `git add` and a successful `git
  # commit`+cleanup — a plain `git diff` (working tree vs index) would see
  # that case as "clean" and wrongly skip straight to persisted=true.
  if git diff --quiet HEAD -- stats/dockerhub-pull-history.jsonl; then
    if [[ "$snapshot_failed" == "true" ]]; then
      echo "::warning::Stats snapshot collection made no commit-worthy progress on attempt $attempt"
      sleep_before_retry "$attempt"
      continue
    fi
    persisted=true  # nothing new this attempt: either already done, or a
    still_missing=false  # concurrent run already covered it. Either way, not a failure.
    break
  else
    diff_status=$?
    if [[ "$diff_status" -gt 1 ]]; then
      echo "::warning::Could not inspect stats snapshot diff on attempt $attempt"
      retry_cleanup "$attempt" "false"
      continue
    fi
  fi

  if ! git add stats/dockerhub-pull-history.jsonl; then
    echo "::warning::Could not stage stats snapshot on attempt $attempt"
    retry_cleanup "$attempt" "false"
    continue
  fi

  if ! git commit -m "chore(stats): daily Docker Hub pull-count snapshot"; then
    echo "::warning::Could not commit stats snapshot on attempt $attempt"
    retry_cleanup "$attempt" "false"
    continue
  fi

  if git push origin master; then
    persisted=true
    push_confirmed=true
    if [[ "$snapshot_failed" == "true" ]]; then
      echo "::warning::Persisted partial stats snapshot on attempt $attempt; some containers may still be missing — retrying for the rest"
      sleep_before_retry "$attempt"
      continue
    fi
    still_missing=false  # confirmed: fetch was fully successful AND this push succeeded
    break
  fi

  # Lost the race (or lack permission) — discard this attempt and retry clean.
  # origin/master already holds any earlier successful push from this run, so
  # this reset can never discard already-persisted data.
  retry_cleanup "$attempt" "true"
done

final_stats_hash="$(remote_stats_hash)"

should_dispatch=false
if [[ "$initial_stats_hash" != "$REMOTE_HASH_UNKNOWN" && "$final_stats_hash" != "$REMOTE_HASH_UNKNOWN" ]]; then
  # Both checkpoints confirmed — the direct origin-content comparison is the
  # authoritative signal, regardless of any single git push's own exit code.
  [[ "$final_stats_hash" != "$initial_stats_hash" ]] && should_dispatch=true
elif [[ "$push_confirmed" == "true" ]]; then
  # The remote hash check was unavailable at least once this run (a fetch
  # failure at either checkpoint), so a raw comparison can't be trusted in
  # either direction. Fall back to the best remaining signal: did a `git
  # push` command itself report success. This won't catch an ambiguous
  # push (reported failure, actually landed) in this degraded path — an
  # acceptable secondary-order gap given we're already short one reliable
  # signal, and a missed dispatch here just means the usual freshness lag.
  should_dispatch=true
  echo "::warning::Remote stats hash check was unavailable this run; falling back to this run's own confirmed push status for the follow-up dispatch decision"
fi

if [[ "$should_dispatch" == "true" ]]; then
  if [[ -n "$github_token" && -n "$github_repository" ]]; then
    if ! GH_TOKEN="$github_token" gh workflow run update-dashboard.yaml \
        --repo "$github_repository" \
        --ref master \
        -f trigger_reason="Docker Hub stats snapshot committed"; then
      echo "::warning::Could not trigger a follow-up dashboard build after persisting stats — the deployed trend may lag until the next independent trigger"
    fi
  else
    echo "::warning::Missing GitHub token or repository; could not trigger a follow-up dashboard build after persisting stats"
  fi
fi

if [[ "$still_missing" == "true" ]]; then
  if [[ "$persisted" != "true" ]]; then
    # No extra snapshot-stats.sh call here — nothing downstream reads the
    # local worktree after this point (the job ends right after), and a 4th
    # invocation was pushing the worst-case Docker-Hub-outage runtime close
    # to the job's own timeout budget for no observable benefit.
    echo "::error::Could not persist stats snapshot this run — another same-day direct trigger may still cover it"
  else
    echo "::error::Exhausted retries with some containers still missing after at least one successful persist — another same-day direct trigger may still cover them"
  fi
  restore_origin_remote
  trap - EXIT
  exit 1
fi

restore_origin_remote
trap - EXIT

exit 0
