#!/usr/bin/env bash
# cascade-find-resolved-parents.sh — list parents whose cascade wait label is stranded.
#
# cascade-resolver.yaml normally removes `cascade:waiting-for-<parent>` when the
# parent drift PR's merge commit gets a successful "Auto Build & Push" on master.
# auto-build.yaml serialises master pushes (one pending run, `cancel-in-progress`
# only for PRs), so when several drift PRs merge in a burst every middle run is
# cancelled — including the parent's own — and that signal is lost. The child then
# waits forever even though a later successful master build already covers the parent
# (detect-containers diffs against the coverage checkpoint tag, not the push event).
#
# A parent X is reported as resolved when ALL hold:
#   1. an open same-repo drift PR carries `cascade:waiting-for-X`;
#   2. no drift PR `update/base-digest-X` is open any more (X is not in flux again);
#   3. the latest merged `update/base-digest-X` PR merged AFTER the newest waiting
#      child was created (a parent merged earlier belongs to an older cycle);
#   4. an Auto Build & Push run on master that SUCCEEDED was created after that merge.
#
# Output: one parent name per line on stdout (names validated against [a-z0-9_-]+).
# Env:    GH_TOKEN, GH_REPO (required).
#
# Fail-closed: a lookup failure for a parent skips that parent (retried next sweep);
# a failure listing the waiting children exits non-zero.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../helpers/logging.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/helpers/logging.sh"

: "${GH_REPO:?GH_REPO required}"

# Same trust boundary as the resolver: bot-named branch, master base, same repo.
# shellcheck disable=SC2016  # $c is a jq variable, not a shell expansion
if ! waiting=$(gh pr list \
  --label base-digest-drift \
  --state open \
  --limit 100 \
  --json number,createdAt,labels,isCrossRepository,baseRefName,headRefName \
  --jq '.[]
        | select(.isCrossRepository == false)
        | select(.baseRefName == "master")
        | select(.headRefName | startswith("update/base-digest-"))
        | .createdAt as $c
        | .labels[].name
        | select(startswith("cascade:waiting-for-"))
        | ltrimstr("cascade:waiting-for-") + " " + $c'); then
  log_error "Cannot list cascade-waiting drift PRs"
  exit 1
fi

[[ -n "$waiting" ]] || { log_info "No cascade-waiting drift PRs"; exit 0; }

# One line per parent: "<parent> <newest waiting child createdAt>".
parents=$(sort <<< "$waiting" | awk '{ last[$1] = $2 } END { for (p in last) print p, last[p] }' | sort)

while read -r parent child_created; do
  [[ -n "$parent" ]] || continue
  if ! [[ "$parent" =~ ^[a-z0-9_-]+$ ]]; then
    log_warning "Ignoring invalid parent name: ${parent}"
    continue
  fi

  if ! open_parent=$(gh pr list --head "update/base-digest-${parent}" --state open \
    --json number --jq 'length'); then
    log_warning "Cannot check open drift PR for ${parent}; skipping"
    continue
  fi
  if [[ "$open_parent" -gt 0 ]]; then
    log_info "${parent}: drift PR still open — keep waiting"
    continue
  fi

  if ! merged_at=$(gh pr list --head "update/base-digest-${parent}" --state merged \
    --limit 1 --json mergedAt --jq '.[0].mergedAt // empty'); then
    log_warning "Cannot look up merged drift PR for ${parent}; skipping"
    continue
  fi
  if [[ -z "$merged_at" || ! "$merged_at" > "$child_created" ]]; then
    log_info "${parent}: no drift PR merged after the waiting child was created — keep waiting"
    continue
  fi

  if ! covered=$(gh run list --workflow auto-build.yaml --branch master --status success \
    --limit 100 --json createdAt \
    | jq --arg m "$merged_at" '[.[] | select(.createdAt > $m)] | length'); then
    log_warning "Cannot list master builds for ${parent}; skipping"
    continue
  fi
  if [[ "$covered" -eq 0 ]]; then
    log_info "${parent}: merged ${merged_at} but no successful master build since — keep waiting"
    continue
  fi

  log_info "${parent}: merged ${merged_at}, covered by a later successful master build — stranded label"
  echo "$parent"
done <<< "$parents"
