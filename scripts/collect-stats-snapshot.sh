#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHA_HELPER="${SCRIPT_DIR}/../helpers/gha.sh"
if [[ ! -r "$GHA_HELPER" ]]; then
  # Static text. This runs before the helper that escapes workflow commands is
  # loaded, so an interpolated path — which a symlinked invocation takes from
  # its own directory name — would be the one place in this script where a
  # newline in that name could open a workflow command. The path is a constant
  # relative to this file, so naming it literally loses no diagnosis.
  printf '%s\n' 'scripts/collect-stats-snapshot.sh cannot run: required helper helpers/gha.sh is not readable' >&2
  exit 2
fi
# shellcheck source=../helpers/gha.sh
source "$GHA_HELPER"

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  gha_error 'scripts/collect-stats-snapshot.sh is CI-only' >&2
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
  gha_warning 'Stats snapshot collection failed on attempt %s; some containers failed, but valid rows from successful containers are still kept' "$attempt"
  if [[ "$attempt" -lt 3 ]]; then
    if ! sleep $((attempt * 5)); then
      gha_warning 'Stats snapshot collection retry sleep failed after attempt %s' "$attempt"
    fi
  fi
done

if [[ "$still_missing" == "true" ]]; then
  gha_warning 'Stats snapshot collection ended with some containers still missing after 3 attempts'
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if ! gha_output still_missing "$still_missing"; then
    gha_warning 'Stats snapshot artifact was collected, but its workflow output could not be delivered'
    exit 1
  fi
fi

exit 0
