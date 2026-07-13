#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  echo "::error::scripts/collect-stats-snapshot.sh is CI-only" >&2
  exit 2
fi

# Pure data collection — no git operations, no push credentials in scope at
# all (this step in the calling workflow runs BEFORE the App token is minted
# and the GPG key is imported), so a compromised snapshot-stats.sh (or a
# malicious Docker Hub response) has nothing here that could push a signed,
# branch-protection-bypassing change to master. Only
# scripts/commit-stats-snapshot.sh, run later with those credentials in scope,
# does that.
#
# Pinned once, before the first attempt, so all 3 retries stay focused on
# the day this run started for, not whatever the clock says by the time a
# later attempt fires.
export SNAPSHOT_DATE_OVERRIDE
SNAPSHOT_DATE_OVERRIDE="$(date -u +%Y-%m-%d)"

still_missing=true
for attempt in 1 2 3; do
  if ./scripts/snapshot-stats.sh; then
    still_missing=false
    break
  fi
  echo "::warning::Stats snapshot collection failed on attempt $attempt; some containers failed, but valid rows from successful containers are still kept"
  if [[ "$attempt" -lt 3 ]]; then
    if ! sleep $((attempt * 5)); then
      echo "::warning::Stats snapshot collection retry sleep failed after attempt $attempt"
    fi
  fi
done

if [[ "$still_missing" == "true" ]]; then
  echo "::warning::Stats snapshot collection ended with some containers still missing after 3 attempts"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "still_missing=$still_missing" >> "$GITHUB_OUTPUT"
fi

exit 0
