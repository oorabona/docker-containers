#!/usr/bin/env bash
# open-dep-failure-issue.sh — Open or update a GitHub issue when a build fails on a dep-update commit/PR.
#
# One issue per (container, source-PR) so the failure is actionable and de-duplicated.
# Detection: commit subject, PR title, PR labels, or branch ref are matched against
# upstream-monitor conventions to identify the affected container and bump kind.
#
# Called by auto-build.yaml after a failed build run.
# All inputs are provided via environment variables listed in the "Required env vars" block.
#
# Exit codes:
#   0  — issue created or commented successfully (or DRY_RUN printed)
#   1  — no dep-bump detected (caller should fall back to generic issue logic)
#   2  — missing required env var
#   3  — gh CLI error after retries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../helpers/logging.sh
source "$ROOT_DIR/helpers/logging.sh"
# shellcheck source=../helpers/retry.sh
source "$ROOT_DIR/helpers/retry.sh"

# ---------------------------------------------------------------------------
# Required env vars
# ---------------------------------------------------------------------------
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${COMMIT_SUBJECT:?COMMIT_SUBJECT is required}"

# Optional
PR_NUMBER="${PR_NUMBER:-}"
PR_TITLE="${PR_TITLE:-}"
PR_BODY="${PR_BODY:-}"
PR_LABELS="${PR_LABELS:-}"
FAILED_JOBS_JSON="${FAILED_JOBS_JSON:-}"
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------------------------------------------------------
# gh wrapper — respects DRY_RUN
# ---------------------------------------------------------------------------
run_gh() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY_RUN] gh $*"
        return 0
    fi
    retry_with_backoff 3 5 gh "$@"
}

# ---------------------------------------------------------------------------
# detect_dep_bump
#
# Sets globals: DETECTED_CONTAINER DETECTED_KIND
# Returns 0 if a dep-bump was detected, 1 otherwise.
# Priority: commit/PR title > PR labels > branch ref.
# ---------------------------------------------------------------------------
detect_dep_bump() {
    DETECTED_CONTAINER=""
    DETECTED_KIND=""

    local container_from_commit="" kind_from_commit=""
    local container_from_title="" kind_from_title=""
    local container_from_labels="" kind_from_labels=""
    local container_from_branch="" kind_from_branch=""

    # Signal 1: commit subject — "build(<container>): …" or "deps(<container>): …"
    # Regex stored in variable to avoid bash parser confusion with ) in [[...]]
    local re_commit='^(build|deps)\(([^)]+)\):'
    if [[ "$COMMIT_SUBJECT" =~ $re_commit ]]; then
        container_from_commit="${BASH_REMATCH[2]}"
        if [[ "${BASH_REMATCH[1]}" == "deps" ]]; then
            kind_from_commit="deps"
        else
            kind_from_commit="version-bump"
        fi
    fi

    # Signal 2: PR title
    if [[ -n "$PR_TITLE" ]]; then
        # deps variant: "📦 deps(<container>): …" or "⚠️ deps(<container>): …"
        local re_deps_title='^[[:space:]]*(📦|⚠️)[[:space:]]*deps\(([^)]+)\):'
        local re_bump_title='^[[:space:]]*(🚀[[:space:]]*Minor|🔄[[:space:]]*Major):[[:space:]]+([^[:space:]]+)[[:space:]]+to'
        if [[ "$PR_TITLE" =~ $re_deps_title ]]; then
            container_from_title="${BASH_REMATCH[2]}"
            kind_from_title="deps"
        # version-bump variant: "🚀 Minor: <container> to …" or "🔄 Major: <container> to …"
        elif [[ "$PR_TITLE" =~ $re_bump_title ]]; then
            container_from_title="${BASH_REMATCH[2]}"
            kind_from_title="version-bump"
        fi
    fi

    # Signal 3: PR labels — must contain "automation" AND ("dependencies" or "*-update")
    # Upstream-monitor label format: automation,<container>,dependencies,<minor|major|patch>-update
    # The container name appears as a bare label (e.g. "sslh"), not "sslh-update".
    if [[ -n "$PR_LABELS" ]]; then
        if echo "$PR_LABELS" | grep -q "automation"; then
            local label_container=""
            local re_update='^[^-]+-update$'
            while IFS= read -r label; do
                label="$(echo "$label" | tr -d '[:space:]')"
                if [[ "$label" == "dependencies" ]]; then
                    kind_from_labels="${kind_from_labels:-deps}"
                elif [[ "$label" =~ $re_update ]]; then
                    # e.g. "minor-update", "major-update", "patch-update" — update-type marker, not container
                    :
                elif [[ "$label" != "automation" ]]; then
                    # Any other label is the container name
                    label_container="$label"
                fi
            done < <(echo "$PR_LABELS" | tr ',' '\n')
            if [[ -n "$label_container" ]]; then
                container_from_labels="$label_container"
                kind_from_labels="${kind_from_labels:-version-bump}"
            fi
        fi
    fi

    # Signal 4: branch ref — "update/<container>-deps" or "update/<container>-<version>"
    local re_branch='^update/([^/-]+)(-.*)?$'
    if [[ "$GITHUB_REF_NAME" =~ $re_branch ]]; then
        container_from_branch="${BASH_REMATCH[1]}"
        if [[ "$GITHUB_REF_NAME" =~ -deps$ ]]; then
            kind_from_branch="deps"
        else
            kind_from_branch="version-bump"
        fi
    fi

    # Priority: commit/title > labels > branch
    if [[ -n "$container_from_commit" ]]; then
        DETECTED_CONTAINER="$container_from_commit"
        DETECTED_KIND="$kind_from_commit"
    elif [[ -n "$container_from_title" ]]; then
        DETECTED_CONTAINER="$container_from_title"
        DETECTED_KIND="$kind_from_title"
    elif [[ -n "$container_from_labels" ]]; then
        DETECTED_CONTAINER="$container_from_labels"
        DETECTED_KIND="$kind_from_labels"
    elif [[ -n "$container_from_branch" ]]; then
        DETECTED_CONTAINER="$container_from_branch"
        DETECTED_KIND="$kind_from_branch"
    else
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# extract_dep_details <container> <kind>
#
# Prints a JSON array of dep objects to stdout.
# ---------------------------------------------------------------------------
extract_dep_details() {
    local container="$1"
    local kind="$2"

    if [[ "$kind" == "version-bump" ]]; then
        # Extract new version from PR title or commit subject
        local new_version="?"
        if [[ -n "$PR_TITLE" && "$PR_TITLE" =~ [[:space:]]to[[:space:]]+([^[:space:]]+) ]]; then
            new_version="${BASH_REMATCH[1]}"
        elif [[ "$COMMIT_SUBJECT" =~ [[:space:]]to[[:space:]]+([^[:space:]]+) ]]; then
            new_version="${BASH_REMATCH[1]}"
        fi
        printf '[{"name":"%s","old":"?","new":"%s"}]' "$container" "$new_version"
        return 0
    fi

    # kind == deps: parse PR_BODY for a markdown table
    if [[ -z "$PR_BODY" ]]; then
        printf '[{"name":"(unknown)","old":"?","new":"?","note":"PR body not available"}]'
        return 0
    fi

    # Match table rows: | col1 | col2 | col3 | (optional col4)
    # Skip header row and separator row (contains only dashes/pipes/spaces)
    local json_array="["
    local first=1
    while IFS= read -r line; do
        # Skip separator lines (e.g. |---|---|---|)
        if [[ "$line" =~ ^\|[[:space:]]*[-:]+[[:space:]]*\| ]]; then
            continue
        fi
        # Match data rows: | name | old | new | ... |
        if [[ "$line" =~ ^\|[[:space:]]*([^|]+)\|[[:space:]]*([^|]*)\|[[:space:]]*([^|]*)\| ]]; then
            local dep_name old_ver new_ver
            dep_name="$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            old_ver="$(echo "${BASH_REMATCH[2]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            new_ver="$(echo "${BASH_REMATCH[3]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

            # Skip the header row
            local lower_name
            lower_name="$(echo "$dep_name" | tr '[:upper:]' '[:lower:]')"
            case "$lower_name" in
                dependency|dependencies|dep|name|package) continue ;;
            esac

            # Escape JSON special characters
            dep_name="${dep_name//\\/\\\\}"
            dep_name="${dep_name//\"/\\\"}"
            old_ver="${old_ver//\\/\\\\}"
            old_ver="${old_ver//\"/\\\"}"
            new_ver="${new_ver//\\/\\\\}"
            new_ver="${new_ver//\"/\\\"}"

            if [[ "$first" -eq 0 ]]; then
                json_array+=","
            fi
            json_array+="{\"name\":\"${dep_name}\",\"old\":\"${old_ver}\",\"new\":\"${new_ver}\"}"
            first=0
        fi
    done <<< "$PR_BODY"

    json_array+="]"

    # Fallback if nothing was parsed
    if [[ "$json_array" == "[]" ]]; then
        printf '[{"name":"(unknown)","old":"?","new":"?","note":"PR body not available"}]'
    else
        printf '%s' "$json_array"
    fi
}

# ---------------------------------------------------------------------------
# build_deps_table <json_array>
#
# Converts the JSON array from extract_dep_details into a markdown table.
# Pure bash — no jq dependency.
# ---------------------------------------------------------------------------
build_deps_table() {
    local json="$1"

    echo "| Dependency | Old | New |"
    echo "|------------|-----|-----|"

    # Parse each {...} object from the flat array
    local entry
    while IFS= read -r entry; do
        local dep_name old_ver new_ver note
        dep_name="$(echo "$entry" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)"
        old_ver="$(echo "$entry" | grep -o '"old":"[^"]*"' | cut -d'"' -f4)"
        new_ver="$(echo "$entry" | grep -o '"new":"[^"]*"' | cut -d'"' -f4)"
        note="$(echo "$entry" | grep -o '"note":"[^"]*"' | cut -d'"' -f4)"
        if [[ -n "$note" ]]; then
            echo "| ${dep_name} | ${old_ver} | ${new_ver} | _${note}_ |"
        else
            echo "| ${dep_name} | ${old_ver} | ${new_ver} |"
        fi
    done < <(echo "$json" | grep -o '{[^}]*}')
}

# ---------------------------------------------------------------------------
# get_log_excerpt <job_id>
#
# Fetches last 30 lines of failed-step log for the given job.
# Outputs at most 50 lines. Falls back gracefully on error.
# ---------------------------------------------------------------------------
get_log_excerpt() {
    local job_id="$1"
    local excerpt

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "(log excerpt suppressed in DRY_RUN mode)"
        return 0
    fi

    if excerpt=$(gh run view "$GITHUB_RUN_ID" \
            --repo "$GITHUB_REPOSITORY" \
            --job "$job_id" \
            --log-failed 2>&1 | tail -30); then
        echo "$excerpt" | head -50
    else
        local reason="$excerpt"
        echo "(log excerpt unavailable: ${reason:-unknown error})"
    fi
}

# ---------------------------------------------------------------------------
# build_issue_body <container> <deps_table> <log_excerpt>
# ---------------------------------------------------------------------------
build_issue_body() {
    local container="$1"
    local deps_table="$2"
    local log_excerpt="$3"

    local short_sha="${GITHUB_SHA:0:8}"
    local run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

    # PR link row (empty string when no PR)
    local source_pr_line=""
    if [[ -n "$PR_NUMBER" ]]; then
        local pr_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER}"
        local pr_display="${PR_TITLE:-PR #${PR_NUMBER}}"
        source_pr_line="| **Source PR** | #${PR_NUMBER} ([${pr_display}](${pr_url})) |"$'\n'
    fi

    # Failing jobs section
    local failing_jobs_section
    if [[ -n "$FAILED_JOBS_JSON" ]]; then
        failing_jobs_section="## Failing jobs

"
        local job_item
        while IFS= read -r job_item; do
            job_item="$(echo "$job_item" | tr -d '"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            [[ -n "$job_item" ]] && failing_jobs_section+="- ${job_item}
"
        done < <(echo "$FAILED_JOBS_JSON" \
            | grep -o '"[^"]*"' \
            | grep -v '^"name"\|^"conclusion"\|^"failure"\|^"cancelled"' \
            | tr -d '"')
    else
        failing_jobs_section="## Failing jobs

(failure detail not provided)"
    fi

    # Log excerpt section
    local log_section=""
    if [[ -n "$log_excerpt" ]]; then
        log_section="## Log excerpt

\`\`\`
${log_excerpt}
\`\`\`"
    fi

    # Refs footer
    local refs_line=""
    if [[ -n "$PR_NUMBER" ]]; then
        refs_line="
Refs #${PR_NUMBER}
"
    fi

    cat <<BODY
## Failing build

| Property | Value |
|----------|-------|
| **Container** | \`${container}\` |
${source_pr_line}| **Commit** | \`${short_sha}\` (\`${COMMIT_SUBJECT}\`) |
| **Trigger** | \`${GITHUB_EVENT_NAME}\` |
| **Failing run** | [${GITHUB_RUN_ID}](${run_url}) |

## Dependencies in this bump

${deps_table}

${failing_jobs_section}

${log_section}

---
${refs_line}_Auto-generated by \`scripts/open-dep-failure-issue.sh\`_
BODY
}

# ---------------------------------------------------------------------------
# open_version_drift_issue <drift_json> <container>
#
# Open or refresh a version-drift issue.  Deduplicates on labels
# version-drift,automation[,dep:<container>] — repeated runs refresh via
# comment rather than open a duplicate.
#
# Arguments:
#   drift_json  — JSON array from check-version-drift.sh --json (may be empty
#                 or "[]"; function is a no-op in that case)
#   container   — optional single-container name; empty string for sweep mode
#
# Required env vars (subset of the standard set used by this script):
#   GH_TOKEN  (required; set at source-time via the `: "${GH_TOKEN:?}" guard)
#   GITHUB_REPOSITORY
#   GITHUB_RUN_ID
#   GITHUB_SERVER_URL
#   GITHUB_SHA
#
# Outputs: "created #N" | "commented #N" | "dry-run #0" | "" (no drift rows)
# Exit codes: 0 on success (issue created/refreshed, or no drift rows);
#             non-zero when gh issue create/comment fails after retries.
# ---------------------------------------------------------------------------
open_version_drift_issue() {
    local drift_json="$1"
    local container="${2:-}"

    # No drift rows → nothing to do
    if [[ -z "$drift_json" || "$drift_json" == "[]" ]]; then
        return 0
    fi

    # Validate that drift_json is a JSON array before parsing.
    # An empty/whitespace value is a legitimate no-op (handled above).
    # A non-empty value that does not parse as a JSON array indicates a caller bug
    # or upstream truncation — fail loudly so the sweep's issue_rc check fires.
    if [[ -n "${drift_json//[[:space:]]/}" ]] && \
        ! printf '%s' "$drift_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        echo "::error::open_version_drift_issue: drift_json is not valid JSON array" >&2
        return 1
    fi

    # Count drift rows
    local drift_count
    drift_count=$(printf '%s' "$drift_json" | jq '[.[] | select(.status=="drift")] | length' 2>/dev/null || echo "0")
    if [[ "$drift_count" -eq 0 ]]; then
        return 0
    fi

    # Validate container name before using it in label arguments.
    # An invalid name (e.g. containing spaces or shell metacharacters) must not
    # reach --label dep:<container>.  Fall back to the label-less set and emit
    # a single ::warning:: annotation.
    local validated_container=""
    if [[ -n "$container" ]]; then
        if [[ "$container" =~ ^[a-z0-9_-]+$ ]]; then
            validated_container="$container"
        else
            printf '::warning::open_version_drift_issue: container name failed validation; omitting dep: label\n' >&2
        fi
    fi

    # Build dedup label set.
    # Per-container path:  version-drift,automation,dep:<container>
    # Sweep path (empty):  version-drift,automation,version-drift-sweep
    # The two sets are disjoint: a per-container issue lacks version-drift-sweep;
    # the sweep issue lacks any dep: label.  This prevents the sweep dedup query
    # from matching (and commenting on) a per-container issue.
    local dedup_labels
    if [[ -n "$validated_container" ]]; then
        dedup_labels="version-drift,automation,dep:${validated_container}"
    else
        dedup_labels="version-drift,automation,version-drift-sweep"
    fi

    # Build issue title
    local issue_title
    if [[ -n "$validated_container" ]]; then
        issue_title="Version drift detected — ${validated_container}: ${drift_count} declared version(s) not published"
    else
        issue_title="Version drift detected — ${drift_count} declared version(s) not published"
    fi

    # Build markdown table from drift rows
    local drift_table
    drift_table="$(printf '%s' "$drift_json" | jq -r '
        (["| Kind | Name | Declared | Published | Status |",
          "|------|------|----------|-----------|--------|"] | .[]),
        (.[] | select(.status=="drift") |
         "| \(.kind) | \(.name) | \(.declared) | \(.published) | \(.status) |")
    ' 2>/dev/null || echo "_(unable to render drift table)_")"

    local short_sha="${GITHUB_SHA:0:8}"
    local run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

    local issue_body
    issue_body="$(cat <<VDRIFT_BODY
## Version drift detected

One or more declared versions have not been published to GHCR beyond the grace window.

${drift_table}

| Property | Value |
|----------|-------|
| **Commit** | \`${short_sha}\` |
| **Run** | [${GITHUB_RUN_ID}](${run_url}) |

## Next steps

1. Check if the build for the missing version(s) is still in progress (within the 6-hour grace window).
2. If not, trigger a rebuild: \`./make build <container> <version>\`
3. Verify with: \`scripts/check-version-drift.sh --mode post-build --container <name> --json\`

---
_Auto-generated by \`scripts/open-dep-failure-issue.sh::open_version_drift_issue\`_
VDRIFT_BODY
)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY_RUN] Would search issues with labels: ${dedup_labels}"
        log_info "[DRY_RUN] Title: ${issue_title}"
        echo ""
        echo "=== DRY_RUN: ISSUE BODY ==="
        echo "$issue_body"
        echo "==========================="
        echo "dry-run #0"
        return 0
    fi

    # Ensure the version-drift label exists (create best-effort)
    gh label create "version-drift" \
        --repo "$GITHUB_REPOSITORY" \
        --color "d93f0b" \
        --description "Declared version not published to GHCR" 2>/dev/null || true

    if [[ -n "$validated_container" ]]; then
        # Ensure dep:<container> label exists (create best-effort)
        gh label create "dep:${validated_container}" \
            --repo "$GITHUB_REPOSITORY" \
            --color "e4e669" \
            --description "Dep-attributed build failures for ${validated_container}" 2>/dev/null || true
    else
        # Sweep path: ensure version-drift-sweep label exists (create best-effort)
        gh label create "version-drift-sweep" \
            --repo "$GITHUB_REPOSITORY" \
            --color "d93f0b" \
            --description "Global version-drift sweep issue" 2>/dev/null || true
    fi

    # Search for open issue with dedup label set.
    # Per-container search includes dep:<container> — cannot match the sweep issue.
    # Sweep search includes version-drift-sweep   — cannot match per-container issues.
    local existing_number=""
    local search_output
    local gh_label_args=("--label" "version-drift" "--label" "automation")
    if [[ -n "$validated_container" ]]; then
        gh_label_args+=("--label" "dep:${validated_container}")
    else
        gh_label_args+=("--label" "version-drift-sweep")
    fi

    if search_output=$(gh issue list \
            --repo "$GITHUB_REPOSITORY" \
            "${gh_label_args[@]}" \
            --state open \
            --limit 5 \
            --json number,title 2>&1); then
        local candidate
        candidate=$(printf '%s' "$search_output" | grep -o '"number":[0-9]*' | grep -o '[0-9]*' | head -1 || true)
        if [[ -n "$candidate" ]]; then
            existing_number="$candidate"
        fi
    fi

    if [[ -n "$existing_number" ]]; then
        local comment_body
        comment_body="$(cat <<VDRIFT_COMMENT
## Version drift still detected

| Property | Value |
|----------|-------|
| **Run** | [${GITHUB_RUN_ID}](${run_url}) |
| **Time** | $(date -u +'%Y-%m-%d %H:%M UTC') |
| **Drift count** | ${drift_count} |
VDRIFT_COMMENT
)"
        if ! retry_with_backoff 3 5 gh issue comment \
            --repo "$GITHUB_REPOSITORY" \
            "$existing_number" \
            --body "$comment_body" >&2; then
            echo "::error::open_version_drift_issue: gh issue comment failed after retries" >&2
            return 1
        fi
        echo "commented #${existing_number}"
    else
        local create_out
        if ! create_out=$(retry_with_backoff 3 5 gh issue create \
            --repo "$GITHUB_REPOSITORY" \
            --title "$issue_title" \
            --label "$dedup_labels" \
            --body "$issue_body"); then
            echo "::error::open_version_drift_issue: gh issue create failed after retries" >&2
            return 1
        fi
        local new_number
        new_number=$(printf '%s' "$create_out" | grep -o '[0-9]*$' || true)
        if [[ -z "$new_number" ]]; then
            echo "::error::open_version_drift_issue: gh issue create succeeded but returned no issue number" >&2
            return 1
        fi
        echo "created #${new_number}"
    fi
}

# ---------------------------------------------------------------------------
# find_or_create_issue <container> <issue_title> <issue_body>
#
# Searches for an existing open issue with labels build-failure,automation,
# dep-attributed,dep:<container>. If found, posts a comment. Otherwise creates.
# Prints "commented #N" or "created #N".
# ---------------------------------------------------------------------------
find_or_create_issue() {
    local container="$1"
    local issue_title="$2"
    local issue_body="$3"

    local dedup_labels="build-failure,automation,dep-attributed,dep:${container}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY_RUN] Would search issues with labels: ${dedup_labels}"
        log_info "[DRY_RUN] Title: ${issue_title}"
        echo ""
        echo "=== DRY_RUN: ISSUE BODY ==="
        echo "$issue_body"
        echo "==========================="
        echo "dry-run #0"
        return 0
    fi

    # Search for open issue with dedup label set
    local existing_number=""
    local search_output
    if search_output=$(gh issue list \
            --repo "$GITHUB_REPOSITORY" \
            --label "build-failure" \
            --label "dep-attributed" \
            --label "dep:${container}" \
            --state open \
            --limit 10 \
            --json number,title,body 2>&1); then
        local candidate
        candidate=$(echo "$search_output" | grep -o '"number":[0-9]*' | grep -o '[0-9]*' | head -1 || true)
        if [[ -n "$candidate" ]]; then
            # Prefer a match that references the same PR if available
            if [[ -n "$PR_NUMBER" ]]; then
                if echo "$search_output" | grep -q "PR #${PR_NUMBER}\|Refs #${PR_NUMBER}\|(#${PR_NUMBER})"; then
                    existing_number="$candidate"
                else
                    existing_number="$candidate"
                fi
            else
                existing_number="$candidate"
            fi
        fi
    fi

    if [[ -n "$existing_number" ]]; then
        local run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
        local comment_body
        comment_body="$(cat <<COMMENT
## Another failure on the same dep update

| Property | Value |
|----------|-------|
| **Run** | [${GITHUB_RUN_ID}](${run_url}) |
| **Trigger** | \`${GITHUB_EVENT_NAME}\` |
| **Ref** | \`${GITHUB_REF_NAME}\` |
| **Time** | $(date -u +'%Y-%m-%d %H:%M UTC') |
COMMENT
)"
        retry_with_backoff 3 5 gh issue comment \
            --repo "$GITHUB_REPOSITORY" \
            "$existing_number" \
            --body "$comment_body" >&2
        echo "commented #${existing_number}"
    else
        # Ensure the dep:<container> label exists (create if missing — best effort)
        gh label create "dep:${container}" \
            --repo "$GITHUB_REPOSITORY" \
            --color "e4e669" \
            --description "Dep-attributed build failures for ${container}" 2>/dev/null || true

        local new_number
        new_number=$(retry_with_backoff 3 5 gh issue create \
            --repo "$GITHUB_REPOSITORY" \
            --title "$issue_title" \
            --label "$dedup_labels" \
            --body "$issue_body" \
            | grep -o '[0-9]*$' || true)
        echo "created #${new_number}"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    log_step "Detecting dep bump from commit/PR signals..."

    if ! detect_dep_bump; then
        log_info "No dep-bump pattern detected — falling back to generic issue logic."
        exit 1
    fi

    local container="$DETECTED_CONTAINER"
    local kind="$DETECTED_KIND"
    log_info "Detected: container=${container} kind=${kind}"

    # Build issue title
    local short_sha="${GITHUB_SHA:0:8}"
    local issue_title
    if [[ -n "$PR_NUMBER" ]]; then
        issue_title="🚨 [${container}] Build failed after dep update (PR #${PR_NUMBER})"
    else
        issue_title="🚨 [${container}] Build failed after dep update (commit ${short_sha})"
    fi

    # Extract dep details
    local deps_json
    deps_json="$(extract_dep_details "$container" "$kind")"

    # Build markdown table
    local deps_table
    deps_table="$(build_deps_table "$deps_json")"

    # Fetch log excerpt for first failing job
    local log_excerpt=""
    if [[ -n "$FAILED_JOBS_JSON" ]]; then
        local first_job_id
        first_job_id=$(echo "$FAILED_JOBS_JSON" \
            | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 \
            | grep -o '"[^"]*"$' \
            | tr -d '"' || true)
        if [[ -n "$first_job_id" ]]; then
            log_excerpt="$(get_log_excerpt "$first_job_id")"
        fi
    fi

    # Build issue body
    local issue_body
    issue_body="$(build_issue_body "$container" "$deps_table" "$log_excerpt")"

    # Find or create issue
    local result
    result="$(find_or_create_issue "$container" "$issue_title" "$issue_body")"
    log_success "Issue action: ${result}"
    echo "$result"
}

# Run main only when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
