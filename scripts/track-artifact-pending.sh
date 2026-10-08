#!/usr/bin/env bash
# track-artifact-pending.sh — escalate a candidate stuck in `artifact-pending`.
#
# `make check-updates` holds a candidate back (status: artifact-pending) while the
# release artifact declared by `artifact_url` is not downloadable. That is
# deliberately non-fatal, so a candidate whose artifact never appears would be
# ignored forever. This script reads the check-updates JSON and:
#
#   - records when each candidate was first seen pending;
#   - once it has been pending for ARTIFACT_PENDING_THRESHOLD_DAYS (default 3),
#     opens ONE issue per container (label `artifact-pending:<container>`) with the
#     candidate tag, the probed URL(s) and the last status seen (404 / 5xx /
#     timeout / terminal 3xx), refreshing it on later runs instead of duplicating it;
#   - closes that issue and forgets the state as soon as the candidate is no longer
#     pending (artifact found, or superseded by another candidate / up to date).
#
# State: one annotated tag `artifact-pending/<container>` per pending candidate,
# message `candidate=<tag>` + `first_seen=<epoch>`, pushed to the remote. It is a
# git ref, so it survives between daily runs with the `contents: write` the
# monitor already holds, needs no counter file or extra service, and an issue only
# exists once the threshold is crossed (no new signal for a candidate that
# resolves in time). Issue open/dedup/refresh follows open-key-lifecycle-issue.sh.
#
# Input: the `make check-updates` JSON array, on stdin or --json-file.
# Env:   GH_TOKEN, GITHUB_REPOSITORY (required);
#        ARTIFACT_PENDING_THRESHOLD_DAYS (default 3), ARTIFACT_PENDING_REMOTE
#        (default origin), ARTIFACT_PENDING_NOW (epoch override, for tests).
#
# Lookup failures (registry/upstream/downgrade-guard) say nothing about the
# artifact, so they leave the state untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../helpers/logging.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/helpers/logging.sh"
# shellcheck source=../helpers/retry.sh
# shellcheck disable=SC1091
source "$ROOT_DIR/helpers/retry.sh"

REF_PREFIX="artifact-pending"

usage() {
    echo "usage: track-artifact-pending.sh [--json-file check-updates.json]" >&2
}

run_gh() {
    retry_with_backoff 3 5 gh "$@"
}

remote() { printf '%s' "${ARTIFACT_PENDING_REMOTE:-origin}"; }
now() { printf '%s' "${ARTIFACT_PENDING_NOW:-$(date +%s)}"; }

# Container keys may be `name:major` (latest_per_major); ':' is not valid in a ref.
state_ref() { printf '%s/%s' "$REF_PREFIX" "${1//:/--}"; }

valid_key() { [[ "$1" =~ ^[a-z0-9][a-z0-9._:-]*$ ]]; }

md_cell() {
    local s="$1"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    s="${s//|/\\|}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

# ─── state (annotated tags) ──────────────────────────────────────────────────

fetch_state() {
    git fetch --quiet --force "$(remote)" "+refs/tags/${REF_PREFIX}/*:refs/tags/${REF_PREFIX}/*" 2>/dev/null || true
}

# Prints "<candidate> <first_seen>" or nothing.
read_state() {
    local msg candidate first_seen
    msg=$(git for-each-ref --format='%(contents)' "refs/tags/$(state_ref "$1")" 2>/dev/null) || return 0
    candidate=$(sed -n 's/^candidate=//p' <<< "$msg" | head -n1)
    first_seen=$(sed -n 's/^first_seen=//p' <<< "$msg" | head -n1)
    [[ -n "$candidate" && "$first_seen" =~ ^[0-9]+$ ]] && printf '%s %s\n' "$candidate" "$first_seen"
    return 0
}

write_state() {
    local key="$1" candidate="$2" first_seen="$3" ref
    ref=$(state_ref "$key")
    git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        tag -f -a "$ref" -m "candidate=${candidate}"$'\n'"first_seen=${first_seen}" HEAD >/dev/null
    retry_with_backoff 3 5 git push --quiet --force "$(remote)" "refs/tags/${ref}"
}

clear_state() {
    local ref
    ref=$(state_ref "$1")
    git tag -d "$ref" >/dev/null 2>&1 || true
    retry_with_backoff 3 5 git push --quiet "$(remote)" ":refs/tags/${ref}" 2>/dev/null || true
}

# ─── issues ──────────────────────────────────────────────────────────────────

ensure_labels() {
    local key="$1"
    run_gh label create "automation" --repo "$GITHUB_REPOSITORY" --color "0e8a16" \
        --description "Automated process" --force >/dev/null 2>&1 || true
    run_gh label create "artifact-pending:${key}" --repo "$GITHUB_REPOSITORY" --color "fbca04" \
        --description "Release artifact still missing for ${key}" --force >/dev/null 2>&1 || true
}

# Number of the open issue carrying the label (empty if none).
open_issue_number() {
    gh issue list --repo "$GITHUB_REPOSITORY" --label "artifact-pending:$1" --state open \
        --limit 100 --json number,title | jq -r '.[0].number // empty'
}

build_body() {
    local key="$1" candidate="$2" urls="$3" last_status="$4" first_seen="$5" days="$6" url_lines=""
    local u
    for u in $urls; do url_lines+="- \`$(md_cell "$u")\`"$'\n'; done
    [[ -n "$url_lines" ]] || url_lines=$'- (none resolved)\n'
    cat <<BODY
## Release artifact still not downloadable

| Property | Value |
|----------|-------|
| **Container** | $(md_cell "$key") |
| **Candidate tag** | $(md_cell "$candidate") |
| **Last status seen** | $(md_cell "${last_status:-unknown}") |
| **First seen pending** | $(date -u -d "@${first_seen}" '+%Y-%m-%d %H:%M UTC') |
| **Pending for** | ${days} day(s) |

Probed URL(s):

${url_lines}
\`make check-updates\` holds this candidate back until the artifact answers 2xx.
\`404\` for days usually means the upstream release was withdrawn/re-tagged or the
asset naming changed (\`artifact_url\` in \`config.yaml\` no longer matches); \`5xx\`,
\`timeout\` or a terminal \`3xx\` point at the host or the probe itself.

This issue is refreshed on every monitor run and closed automatically once the
artifact is found or the candidate is superseded.

_Auto-generated by \`scripts/track-artifact-pending.sh\`_
BODY
}

upsert_issue() {
    local key="$1" candidate="$2" body="$3" number title
    title="[artifact-pending] ${key}: ${candidate} release artifact not downloadable"
    ensure_labels "$key"
    number=$(open_issue_number "$key") || { echo "track-artifact-pending: gh issue list failed for ${key}" >&2; return 1; }
    if [[ -n "$number" ]]; then
        gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --title "$title" --body "$body" >/dev/null
        echo "refreshed #${number} (${key})"
    else
        local out
        out=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" \
            --label "automation,artifact-pending:${key}" --body "$body")
        echo "created #$(grep -o '[0-9]*$' <<< "$out" || true) (${key})"
    fi
}

close_issue() {
    local key="$1" reason="$2" number
    number=$(open_issue_number "$key") || return 1
    [[ -n "$number" ]] || return 0
    gh issue close "$number" --repo "$GITHUB_REPOSITORY" --reason completed --comment "$reason" >/dev/null
    echo "closed #${number} (${key})"
}

# ─── per-entry logic ─────────────────────────────────────────────────────────

handle_pending() {
    local entry="$1" key candidate urls last_status state first_seen state_candidate days threshold
    key=$(jq -r '.container' <<< "$entry")
    candidate=$(jq -r '.latest_version' <<< "$entry")
    urls=$(jq -r '(.pending_urls // []) | join(" ")' <<< "$entry")
    last_status=$(jq -r '.pending_status // ""' <<< "$entry")
    threshold="${ARTIFACT_PENDING_THRESHOLD_DAYS:-3}"

    state=$(read_state "$key")
    state_candidate="${state%% *}"
    first_seen="${state##* }"

    if [[ -n "$state" && "$state_candidate" != "$candidate" ]]; then
        close_issue "$key" "Candidate ${state_candidate} was superseded by ${candidate}; tracking restarts for the new candidate." || return 1
        state=""
    fi
    if [[ -z "$state" ]]; then
        write_state "$key" "$candidate" "$(now)"
        echo "tracking ${key}: ${candidate} pending since now (below ${threshold}d threshold)"
        return 0
    fi

    days=$(( ( $(now) - first_seen ) / 86400 ))
    if (( days < threshold )); then
        echo "${key}: ${candidate} pending ${days}d (below ${threshold}d threshold)"
        return 0
    fi
    upsert_issue "$key" "$candidate" "$(build_body "$key" "$candidate" "$urls" "$last_status" "$first_seen" "$days")"
}

handle_resolved() {
    local entry="$1" key candidate state state_candidate reason
    key=$(jq -r '.container' <<< "$entry")
    candidate=$(jq -r '.latest_version' <<< "$entry")
    state=$(read_state "$key")
    [[ -n "$state" ]] || return 0
    state_candidate="${state%% *}"
    if [[ "$state_candidate" == "$candidate" ]]; then
        reason="The release artifact for ${state_candidate} is now downloadable."
    else
        reason="Candidate ${state_candidate} was superseded (latest is now ${candidate:-unknown})."
    fi
    close_issue "$key" "$reason" || return 1
    clear_state "$key"
    echo "resolved ${key}: ${reason}"
}

process_entries() {
    local json="$1" failures=0 entry key status
    jq -e 'type == "array"' >/dev/null <<< "$json" || { echo "track-artifact-pending: input must be a JSON array" >&2; return 2; }

    fetch_state
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        key=$(jq -r '.container // ""' <<< "$entry")
        valid_key "$key" || { printf '::warning::track-artifact-pending: invalid container key; skipping\n' >&2; continue; }
        status=$(jq -r '.status // ""' <<< "$entry")
        case "$status" in
            artifact-pending)
                handle_pending "$entry" || failures=$((failures + 1)) ;;
            up_to_date|update-available|new-container)
                handle_resolved "$entry" || failures=$((failures + 1)) ;;
            *) ;;   # lookup failures: no information about the artifact
        esac
    done < <(jq -c '.[]' <<< "$json")

    if (( failures > 0 )); then
        echo "track-artifact-pending: ${failures} entr(y/ies) failed" >&2
        return 1
    fi
}

main() {
    : "${GH_TOKEN:?GH_TOKEN is required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

    local json_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json-file) [[ $# -ge 2 ]] || { usage; return 2; }; json_file="$2"; shift 2 ;;
            *) usage; return 2 ;;
        esac
    done

    local json
    if [[ -n "$json_file" ]]; then json="$(cat "$json_file")"; else json="$(cat)"; fi
    process_entries "$json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
