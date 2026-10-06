#!/usr/bin/env bash
# cancel-stuck-pages-deploys.sh — Cancel dashboard runs whose `deploy` job never got a runner.
#
# A `deploy` job left queued/pending (e.g. during a GitHub runners outage) keeps the
# `pages-deploy` concurrency group occupied, so every later deploy waits behind it
# and the site goes stale. `timeout-minutes` only starts counting once a job runs,
# so queue time needs this external watchdog.
#
# Usage: cancel-stuck-pages-deploys.sh
# Env:
#   GH_TOKEN         Token with actions: write (required)
#   GITHUB_REPOSITORY owner/repo (required)
#   MAX_QUEUE_MINUTES Queue age before a deploy job counts as stuck (default: 60)
#   DRY_RUN          true = report only, cancel nothing (default: false)
#   WORKFLOW_FILE    Workflow to watch (default: update-dashboard.yaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../helpers/logging.sh
source "$SCRIPT_DIR/../helpers/logging.sh"

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
MAX_QUEUE_MINUTES="${MAX_QUEUE_MINUTES:-60}"
WORKFLOW_FILE="${WORKFLOW_FILE:-update-dashboard.yaml}"
DRY_RUN="${DRY_RUN:-false}"

cutoff=$(date -u -d "-${MAX_QUEUE_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)
cancelled=0

for state in queued pending waiting; do
    run_ids=$(gh api --paginate \
        "repos/${GITHUB_REPOSITORY}/actions/workflows/${WORKFLOW_FILE}/runs?status=${state}&per_page=100" \
        --jq '.workflow_runs[].id') || run_ids=""

    for run_id in $run_ids; do
        stuck=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/jobs?per_page=100" \
            | jq --arg cutoff "$cutoff" \
                '[.jobs[] | select(.name == "deploy" and (.status == "queued" or .status == "pending") and .created_at < $cutoff)] | length' \
            2>/dev/null || echo 0)
        [[ "$stuck" -gt 0 ]] || continue

        log_warning "Run ${run_id}: deploy job queued since before ${cutoff}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "DRY_RUN: would cancel run ${run_id}"
        else
            gh api -X POST "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/cancel" >/dev/null
            log_success "Cancelled run ${run_id}"
        fi
        cancelled=$((cancelled + 1))
    done
done

log_info "Stuck pages deploy runs found: ${cancelled}"
