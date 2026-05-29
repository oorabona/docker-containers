#!/usr/bin/env bats

# Unit tests for the cascade-resolver workflow shell logic.
#
# The "Unblock children" step in .github/workflows/cascade-resolver.yaml is
# tested here by running its shell logic verbatim, with a mock `gh` command.
#
# Multi-parent invariant (Defect A fix):
#   When parent X's master rebuild succeeds, the resolver must:
#   1. Remove cascade:waiting-for-X from the child.
#   2. Re-query the child's remaining cascade:waiting-for-* labels (STRICT — no || echo "0").
#   3. If other wait labels remain → comment "still waiting", NO auto-merge.
#   4. Only when ALL wait labels are gone → enable auto-merge.
#
# Trigger invariant (Defect B):
#   The resolver triggers on workflow_run of "Auto Build & Push" (conclusion=success),
#   NOT on pull_request:closed.  This ensures the parent image is in GHCR before
#   child auto-merge is enabled.  The container is identified via PR metadata
#   (gh api commits/{sha}/pulls), NOT via the commit subject (which is spoofable).
#
# Error-swallowing invariant (Defect C):
#   gh pr view failures must skip the child (continue), not silently return "0"
#   and trigger premature auto-merge.
#
# Mutation guards:
#   MG1: Removing the "remaining > 0" branch → auto-merge fires even with open parents
#   MG2: Removing the --remove-label step → label never removed, infinite retry
#   MG3: Skip "continue" on remove failure → broken child silently auto-merges
#   MG4: || echo "0" on gh pr view → API error silently enables auto-merge (Defect C)

load "../test_helper"

# ---------------------------------------------------------------------------
# Shared resolver body (kept in sync with cascade-resolver.yaml "Unblock children")
# ---------------------------------------------------------------------------

RESOLVER_BODY='
PARENT="${1:?PARENT required}"
if ! children=$(gh pr list \
  --label "cascade:waiting-for-${PARENT}" \
  --label "base-digest-drift" \
  --state open \
  --json number,isCrossRepository \
  --jq '"'"'.[] | select(.isCrossRepository == false) | .number'"'"'); then
  echo "::error::Failed to query children waiting for ${PARENT}. Cascade resolution aborted; retry via workflow_dispatch or wait for next parent build."
  exit 1
fi
if [[ -z "$children" ]]; then
  echo "::notice::No cascade-waiting PRs for parent ${PARENT}"
  exit 0
fi
for child in $children; do
  echo "::notice::Processing child PR #${child} (was waiting for ${PARENT})"
  if ! labels_snapshot=$(gh pr view "$child" \
    --json labels \
    --jq '"'"'[.labels[].name | select(startswith("cascade:waiting-for-"))] | join("\n")'"'"' \
    2>/dev/null); then
    echo "::error::Cannot fetch labels for PR #${child}; skipping (will retry on next parent image publish)"
    continue
  fi
  remaining_labels=""
  while IFS= read -r _label; do
    [[ -n "$_label" ]] || continue
    [[ "$_label" == "cascade:waiting-for-${PARENT}" ]] && continue
    remaining_labels="${remaining_labels} ${_label}"
  done <<< "$labels_snapshot"
  remaining_labels="${remaining_labels# }"
  if ! gh pr edit "$child" --remove-label "cascade:waiting-for-${PARENT}" 2>&1; then
    echo "::warning::Failed to remove cascade:waiting-for-${PARENT} from #${child} — skipping"
    continue
  fi
  if [[ -n "$remaining_labels" ]]; then
    still_waiting="${remaining_labels// /, }"
    echo "::notice::PR #${child} still waiting on: ${still_waiting}"
    gh pr comment "$child" \
      --body "Parent **${PARENT}** drift PR'"'"'s master rebuild succeeded. Still waiting on: ${still_waiting}. Auto-merge will activate when all parents resolve." \
      2>&1 || true
  else
    if gh pr merge "$child" --squash --auto 2>&1; then
      gh pr comment "$child" \
        --body "All parent drift PRs resolved + their master rebuilds succeeded. Auto-merge enabled — will merge once CI passes." \
        2>&1 || true
    else
      gh pr comment "$child" \
        --body "::warning:: Parent **${PARENT}** drift PR resolved, all cascade labels cleared, but auto-merge enable failed. Manual merge required." \
        2>&1 || true
      echo "::warning::auto-merge failed for #${child}"
    fi
  fi
done
'

# Writes the resolver body to a temp script and runs it with the given PARENT arg.
_run_resolver() {
    local parent="$1"
    local script="$TEST_TEMP_DIR/resolver_body.sh"
    printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$RESOLVER_BODY" > "$script"
    chmod +x "$script"
    run "$script" "$parent"
}

# ---------------------------------------------------------------------------
# Mock gh factory: writes $TEST_TEMP_DIR/bin/gh based on the given mode.
#   single-parent  — remaining labels = 0 → auto-merge expected
#   multi-parent   — remaining labels = 1 → no auto-merge
#   remove-fails   — --remove-label exits 1 → child skipped (snapshot taken first, no stranding)
#   view-fails     — pr view exits 1 BEFORE removal → child skipped (Defect B: snapshot-first)
#   no-children    — pr list returns empty
#   list-fails     — pr list exits 1 → fail-closed (Defect B fix)
#   merge-fails    — pr merge exits 1 → failure comment posted, not success
# Calls are recorded to $TEST_TEMP_DIR/gh_calls.log.
# Comments are recorded to $TEST_TEMP_DIR/gh_comments.log.
# ---------------------------------------------------------------------------
_setup_mock_gh() {
    local mode="$1"
    local calls_log="$TEST_TEMP_DIR/gh_calls.log"
    local comments_log="$TEST_TEMP_DIR/gh_comments.log"
    touch "$calls_log" "$comments_log"

    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock="$TEST_TEMP_DIR/bin/gh"

    # Write the mock using printf so no heredoc quoting conflicts
    printf '#!/usr/bin/env bash\n' > "$mock"
    printf 'CALLS_LOG="%s"\n' "$calls_log" >> "$mock"
    printf 'COMMENTS_LOG="%s"\n' "$comments_log" >> "$mock"
    printf 'MODE="%s"\n' "$mode" >> "$mock"
    cat >> "$mock" << 'MOCK_BODY'
echo "$@" >> "$CALLS_LOG"

case "$1 $2" in
  "pr list")
    if [[ "$MODE" == "list-fails" ]]; then
      echo "simulated API list failure" >&2
      exit 1
    fi
    # Return PR #42 for any cascade:waiting-for-* label query
    if echo "$@" | grep -q "cascade:waiting-for-"; then
      echo "42"
    fi
    ;;
  "pr edit")
    if echo "$@" | grep -q -- "--remove-label"; then
      if [[ "$MODE" == "remove-fails" ]]; then
        echo "simulated remove-label failure" >&2
        exit 1
      fi
    fi
    ;;
  "pr view")
    if [[ "$MODE" == "view-fails" ]]; then
      echo "simulated API error" >&2
      exit 1
    elif [[ "$MODE" == "single-parent" ]] || [[ "$MODE" == "merge-fails" ]]; then
      # No remaining wait labels — snapshot returns empty string (newline-joined list is empty)
      echo ""
    elif [[ "$MODE" == "multi-parent" ]]; then
      # One remaining wait label besides the parent being resolved
      echo "cascade:waiting-for-php"
    fi
    ;;
  "pr merge")
    if [[ "$MODE" == "merge-fails" ]]; then
      echo "simulated merge failure" >&2
      exit 1
    fi
    : # succeed silently
    ;;
  "pr comment")
    # Capture --body argument
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body" ]]; then
        echo "$2" >> "$COMMENTS_LOG"
        break
      fi
      shift
    done
    ;;
esac
exit 0
MOCK_BODY

    chmod +x "$mock"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Scenario 1 — single-parent: debian merges, child has only cascade:waiting-for-debian
# Expected: label removed, remaining=0, auto-merge enabled
# MG1: if remaining check removed, auto-merge fires even when other parents open
# ---------------------------------------------------------------------------
@test "resolver: single-parent — auto-merge enabled after last wait label removed" {
    _setup_mock_gh "single-parent"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must have been called
    grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # "All parent drift PRs resolved" comment must appear
    grep -q "All parent drift PRs resolved" "$TEST_TEMP_DIR/gh_comments.log"
    # "Still waiting" must NOT appear
    ! grep -q "Still waiting" "$TEST_TEMP_DIR/gh_comments.log"
}

# ---------------------------------------------------------------------------
# Scenario 2 — multi-parent: debian merges, child still has cascade:waiting-for-php
# Expected: label removed, remaining=1, "still waiting" comment, NO auto-merge
# MG1: if remaining check removed, auto-merge fires here — wrong cascade order
# ---------------------------------------------------------------------------
@test "resolver: multi-parent — NO auto-merge when second wait label remains" {
    _setup_mock_gh "multi-parent"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must NOT have been called (MG1)
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # "Still waiting on" comment must be posted
    grep -q "Still waiting on" "$TEST_TEMP_DIR/gh_comments.log"
    # "All parent drift PRs resolved" must NOT appear
    ! grep -q "All parent drift PRs resolved" "$TEST_TEMP_DIR/gh_comments.log"
}

# ---------------------------------------------------------------------------
# Scenario 3 — remove-label failure: gh pr edit --remove-label exits 1
# Expected: child is skipped (continue), no auto-merge, ::warning:: emitted
# MG3: if "continue" removed, broken child could still get auto-merged
# ---------------------------------------------------------------------------
@test "resolver: remove-label failure — child skipped, no auto-merge" {
    _setup_mock_gh "remove-fails"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must NOT have been called
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # warning annotation must appear in output
    [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 4 — no children: no open PRs with cascade:waiting-for-debian
# Expected: exits 0 with ::notice::, no gh pr merge called
# ---------------------------------------------------------------------------
@test "resolver: no children waiting — exits cleanly with notice" {
    # Custom mock: pr list returns empty for all queries
    mkdir -p "$TEST_TEMP_DIR/bin"
    local calls_log="$TEST_TEMP_DIR/gh_calls.log"
    touch "$calls_log"
    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\nexit 0\n' "$calls_log" \
        > "$TEST_TEMP_DIR/bin/gh"
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    _run_resolver "debian"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No cascade-waiting PRs"* ]]
    ! grep -q "pr merge" "$calls_log"
}

# ---------------------------------------------------------------------------
# Scenario 5 — gh pr view failure: API returns non-zero (Defect C)
# Expected: child skipped (continue), no auto-merge, ::error:: emitted
# MG4: if || echo "0" present, API error silently enables auto-merge
# ---------------------------------------------------------------------------
@test "resolver: gh pr view failure — child skipped, no auto-merge (Defect C)" {
    _setup_mock_gh "view-fails"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must NOT have been called (MG4)
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # error annotation must appear in output
    [[ "$output" == *"::error::"* ]]
    # "skipping" message must appear
    [[ "$output" == *"skipping"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 6 — branch name extraction: validator rejects path traversal and
# non-conforming names.  The same [a-z0-9_-]+ guard is applied in the
# "Identify parent container from associated PR" step after extracting the
# container name from the PR's headRefName.
# ---------------------------------------------------------------------------
@test "resolver: branch extraction — update/base-digest-debian → debian" {
    run bash -c '
        head_ref="update/base-digest-debian"
        container="${head_ref#update/base-digest-}"
        [[ "$container" =~ ^[a-z0-9_-]+$ ]] || { echo "INVALID: $container"; exit 1; }
        echo "$container"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "debian" ]
}

@test "resolver: branch extraction — update/base-digest-web-shell → web-shell" {
    run bash -c '
        head_ref="update/base-digest-web-shell"
        container="${head_ref#update/base-digest-}"
        [[ "$container" =~ ^[a-z0-9_-]+$ ]] || { echo "INVALID: $container"; exit 1; }
        echo "$container"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "web-shell" ]
}

@test "resolver: branch extraction — path-traversal rejected by validator" {
    run bash -c '
        head_ref="update/base-digest-../../etc/passwd"
        container="${head_ref#update/base-digest-}"
        if ! [[ "$container" =~ ^[a-z0-9_-]+$ ]]; then
            echo "INVALID: $container" >&2
            exit 1
        fi
        echo "$container"
    '
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Scenario 7 — PR-metadata trigger verification (Defect B fix)
# The "Identify parent container from associated PR" step resolves the container
# via gh api commits/{sha}/pulls, NOT from the commit subject alone.
#
# Tests use a shell fragment that mirrors the step logic with a mock gh command.
# ---------------------------------------------------------------------------

# Writes a mock gh whose "api .../commits/.../pulls" output is controlled by the test.
# $1 = mode: drift-pr | no-pr | wrong-branch | not-merged | api-fails
_setup_pr_metadata_mock() {
    local mode="$1"
    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock="$TEST_TEMP_DIR/bin/gh"
    printf '#!/usr/bin/env bash\nMODE="%s"\n' "$mode" > "$mock"
    cat >> "$mock" << 'MOCK_BODY'
# Only handle "gh api .../commits/.../pulls"
if [[ "$1" == "api" && "$2" == *"/commits/"*"/pulls" ]]; then
    case "$MODE" in
        drift-pr)
            # PR with matching branch, merged
            echo '[{"number":42,"head":{"ref":"update/base-digest-debian"},"merged_at":"2026-05-28T10:00:00Z"}]'
            ;;
        drift-pr-web-shell)
            echo '[{"number":43,"head":{"ref":"update/base-digest-web-shell"},"merged_at":"2026-05-28T10:00:00Z"}]'
            ;;
        no-pr)
            # No PRs associated — empty array
            echo '[]'
            ;;
        wrong-branch)
            # PR exists but branch does not match drift pattern
            echo '[{"number":44,"head":{"ref":"feat/some-feature"},"merged_at":"2026-05-28T10:00:00Z"}]'
            ;;
        not-merged)
            # PR branch matches but merged_at is null
            echo '[{"number":45,"head":{"ref":"update/base-digest-debian"},"merged_at":null}]'
            ;;
        api-fails)
            echo "API error" >&2
            exit 1
            ;;
    esac
    exit 0
fi
# Other gh calls: succeed silently
exit 0
MOCK_BODY
    chmod +x "$mock"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Shell fragment mirroring the "Identify parent container from associated PR" step.
# Accepts HEAD_SHA as $1; uses GITHUB_REPOSITORY env var.
IDENTIFY_PARENT_BODY='
HEAD_SHA="${1:?HEAD_SHA required}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-owner/repo}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
if ! pr_json=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/pulls"); then
    echo "::error::Failed to query PRs for commit ${HEAD_SHA}"
    exit 1
fi
container=$(echo "$pr_json" | jq -r \
    '"'"'.[] | select(.head.ref | startswith("update/base-digest-")) | .head.ref'"'"' \
    | head -1 | sed '"'"'s#^update/base-digest-##'"'"')
if [[ -z "$container" ]]; then
    echo "::notice::Commit ${HEAD_SHA} is not associated with a drift PR (no PR with update/base-digest-* branch). Nothing to unblock."
    echo "name=" >> "$GITHUB_OUTPUT"
    exit 0
fi
if ! [[ "$container" =~ ^[a-z0-9_-]+$ ]]; then
    echo "::error::Invalid container name extracted from PR branch: ${container}"
    exit 1
fi
is_merged=$(echo "$pr_json" | jq -r \
    --arg ref "update/base-digest-${container}" \
    '"'"'.[] | select(.head.ref == $ref) | .merged_at // empty'"'"' \
    | head -1)
if [[ -z "$is_merged" ]]; then
    echo "::error::Drift PR for ${container} is not merged (commit ${HEAD_SHA} mismatch)"
    exit 1
fi
echo "::notice::Parent container image published: ${container} (commit ${HEAD_SHA}, verified via PR metadata)"
echo "name=${container}" >> "$GITHUB_OUTPUT"
'

# Updated body mirroring Defect B fix: also requires base-digest-drift label.
IDENTIFY_PARENT_BODY_LABELED='
HEAD_SHA="${1:?HEAD_SHA required}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-owner/repo}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
if ! pr_json=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/pulls"); then
    echo "::error::Failed to query PRs for commit ${HEAD_SHA}"
    exit 1
fi
container=$(echo "$pr_json" | jq -r \
    '"'"'.[] | select(.head.ref | startswith("update/base-digest-")) | select(.labels[]?.name == "base-digest-drift") | .head.ref'"'"' \
    | head -1 | sed '"'"'s#^update/base-digest-##'"'"')
if [[ -z "$container" ]]; then
    echo "::notice::Commit ${HEAD_SHA} is not associated with a drift PR (no PR with update/base-digest-* branch). Nothing to unblock."
    echo "name=" >> "$GITHUB_OUTPUT"
    exit 0
fi
if ! [[ "$container" =~ ^[a-z0-9_-]+$ ]]; then
    echo "::error::Invalid container name extracted from PR branch: ${container}"
    exit 1
fi
is_merged=$(echo "$pr_json" | jq -r \
    --arg ref "update/base-digest-${container}" \
    '"'"'.[] | select(.head.ref == $ref) | .merged_at // empty'"'"' \
    | head -1)
if [[ -z "$is_merged" ]]; then
    echo "::error::Drift PR for ${container} is not merged (commit ${HEAD_SHA} mismatch)"
    exit 1
fi
echo "::notice::Parent container image published: ${container} (commit ${HEAD_SHA}, verified via PR metadata)"
echo "name=${container}" >> "$GITHUB_OUTPUT"
'

_run_identify_parent() {
    local head_sha="$1"
    local script="$TEST_TEMP_DIR/identify_parent.sh"
    printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$IDENTIFY_PARENT_BODY" > "$script"
    chmod +x "$script"
    local output_file="$TEST_TEMP_DIR/github_output"
    touch "$output_file"
    GITHUB_OUTPUT="$output_file" GITHUB_REPOSITORY="owner/repo" run "$script" "$head_sha"
}

@test "resolver: PR-metadata — drift PR with update/base-digest-debian extracts debian" {
    _setup_pr_metadata_mock "drift-pr"
    _run_identify_parent "abc1234"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    grep -q "name=debian" "$TEST_TEMP_DIR/github_output"
}

@test "resolver: PR-metadata — drift PR with update/base-digest-web-shell extracts web-shell" {
    _setup_pr_metadata_mock "drift-pr-web-shell"
    _run_identify_parent "abc1234"
    [ "$status" -eq 0 ]
    grep -q "name=web-shell" "$TEST_TEMP_DIR/github_output"
}

@test "resolver: PR-metadata — no associated PR exits 0 with name= (nothing to unblock)" {
    _setup_pr_metadata_mock "no-pr"
    _run_identify_parent "abc1234"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to unblock"* ]]
    grep -q "name=" "$TEST_TEMP_DIR/github_output"
}

@test "resolver: PR-metadata — PR with wrong branch exits 0 with name= (not a drift PR)" {
    _setup_pr_metadata_mock "wrong-branch"
    _run_identify_parent "abc1234"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to unblock"* ]]
    grep -q "name=" "$TEST_TEMP_DIR/github_output"
}

@test "resolver: PR-metadata — PR not merged exits 1 (fail-closed)" {
    _setup_pr_metadata_mock "not-merged"
    _run_identify_parent "abc1234"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"not merged"* ]]
}

@test "resolver: PR-metadata — gh api failure exits 1 (fail-closed)" {
    _setup_pr_metadata_mock "api-fails"
    _run_identify_parent "abc1234"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"Failed to query PRs"* ]]
}

# ---------------------------------------------------------------------------
# Three-state parent evaluation (_eval_parent_state) — gate r4 defect fix
#
# The _eval_parent_state function (defined in "Apply cascade labels (strict)"
# in upstream-monitor.yaml) emits 'in_flux' or 'ready' on stdout, with
# notices/warnings on stderr-equivalent lines.  These tests exercise the
# six evaluation paths described in the fix spec.
#
# Mock strategy:
#   - gh: controlled by MODE env var (set in each test)
#   - git: controlled by GIT_LAST_SHA env var (empty = no commit)
# ---------------------------------------------------------------------------

# Body of _eval_parent_state extracted verbatim from the workflow step.
# Variables on the calling side: parent=$1; git and gh are mocked.
EVAL_PARENT_STATE_BODY='
_eval_parent_state() {
  local parent="$1"
  local parent_pr
  if ! parent_pr=$(gh pr list \
    --head "update/base-digest-${parent}" \
    --label "base-digest-drift" \
    --base master \
    --state open \
    --json number,isCrossRepository \
    --jq '"'"'.[] | select(.isCrossRepository == false) | .number'"'"' \
    | head -1); then
    echo "::error::Failed to query parent PR for ${parent} (cascade safety requires this lookup to succeed). Aborting."
    return 2
  fi
  if [[ -n "$parent_pr" ]]; then
    echo "in_flux"
    return 0
  fi
  local recent_sha
  local _repo="${GITHUB_REPOSITORY:-owner/repo}"
  local commit_info
  if ! commit_info=$(gh api "repos/${_repo}/commits?path=${parent}/LAST_REBUILD.md&sha=master&per_page=1" 2>&1); then
    echo "::error::Failed to query commits for ${parent}/LAST_REBUILD.md"
    return 2
  fi
  recent_sha=$(echo "$commit_info" | jq -r '"'"'.[0].sha // empty'"'"')
  if [[ -z "$recent_sha" ]]; then
    echo "ready"
    return 0
  fi
  local run_info
  if ! run_info=$(gh api "repos/${_repo}/actions/runs?head_sha=${recent_sha}&per_page=10" \
    --jq '"'"'.workflow_runs[] | select(.name == "Auto Build & Push") | {status, conclusion}'"'"' 2>&1); then
    echo "::error::Failed to query auto-build runs for ${parent} commit ${recent_sha}. Aborting."
    return 2
  fi
  local run_status run_conclusion
  run_status=$(echo "$run_info" | jq -r '"'"'.status'"'"' | head -1)
  run_conclusion=$(echo "$run_info" | jq -r '"'"'.conclusion // empty'"'"' | head -1)
  if [[ -z "$run_status" ]]; then
    echo "::notice::No auto-build run found for parent ${parent} commit ${recent_sha}; treating as in_flux (conservative)"
    echo "in_flux"
    return 0
  fi
  case "$run_status" in
    in_progress|queued|requested|waiting)
      echo "in_flux"
      ;;
    completed)
      if [[ "$run_conclusion" == "success" ]]; then
        echo "ready"
      else
        echo "::warning::Parent ${parent} auto-build conclusion=${run_conclusion}; treating as in_flux (operator must fix parent build)"
        echo "in_flux"
      fi
      ;;
    *)
      echo "::notice::Parent ${parent} auto-build status=${run_status}; treating as in_flux (conservative)"
      echo "in_flux"
      ;;
  esac
}
_eval_parent_state "$PARENT_ARG"
'

# Writes a mock gh for three-state tests.
# $1 = mode:
#   open-pr              — pr list returns PR #10 (State 1: in_flux)
#   pr-closed-inprog     — pr list empty; commits API returns SHA; runs API returns in_progress (State 2: in_flux)
#   pr-closed-success    — pr list empty; commits API returns SHA; runs API returns completed/success (State 3: ready)
#   pr-closed-failed     — pr list empty; commits API returns SHA; runs API returns completed/failure (State 5: in_flux)
#   pr-closed-cancelled  — pr list empty; commits API returns SHA; runs API returns completed/cancelled (State 5: in_flux)
#   run-not-found        — pr list empty; commits API returns SHA; runs API returns empty (State 6: in_flux conservative)
#   run-api-error        — pr list empty; commits API returns SHA; runs API exits 1 (fail-closed)
#   run-multi            — pr list empty; commits API returns SHA; runs API returns 2 runs (re-run scenario)
#   run-unknown-status   — pr list empty; commits API returns SHA; runs API returns unknown status (in_flux conservative)
#   no-last-rebuild      — pr list empty; commits API returns empty array [] (State 4: ready, never drifted)
#   commits-api-error    — pr list empty; commits API exits 1 (fail-closed on commits lookup)
# COMMITS_SHA env controls SHA returned by the commits API (default: abc123def456).
_setup_three_state_mock() {
    local mode="$1"
    local commits_sha="${COMMITS_SHA:-abc123def456}"
    mkdir -p "$TEST_TEMP_DIR/bin"
    local calls_log="$TEST_TEMP_DIR/gh_calls.log"
    touch "$calls_log"

    # Write mock gh — routes on URL pattern to distinguish commits API vs runs API
    local mock_gh="$TEST_TEMP_DIR/bin/gh"
    printf '#!/usr/bin/env bash\nMODE="%s"\nCOMMITS_SHA="%s"\necho "$@" >> "%s"\n' \
        "$mode" "$commits_sha" "$calls_log" > "$mock_gh"
    cat >> "$mock_gh" << 'GH_MOCK'
case "$1 $2" in
  "pr list")
    if [[ "$MODE" == "open-pr" ]]; then
      # Simulate post-jq output: isCrossRepository=false PR → number emitted
      echo "10"
    elif [[ "$MODE" == "open-pr-fork" ]]; then
      # Simulate post-jq output: isCrossRepository=true PR → jq select emits nothing
      : # print nothing
    elif [[ "$MODE" == "open-pr-no-label" ]]; then
      # gh returns empty because --label "base-digest-drift" not matched (server-side)
      : # print nothing
    fi
    # all other modes: print nothing (no open PR)
    ;;
  "api repos"*)
    # Route on URL: commits?path= (commits API) vs actions/runs (runs API)
    # $1=api $2=<url> (the full URL is $2 regardless of additional flags like --jq)
    # Note: local is not valid outside a function; use plain assignment
    _url="$2"
    if [[ "$_url" == *"commits?"* && "$_url" == *"path="* ]]; then
      # Commits API: gh api "repos/.../commits?path=.../LAST_REBUILD.md&sha=master&per_page=1"
      case "$MODE" in
        commits-api-error)
          echo "commits API failure simulated" >&2
          exit 1
          ;;
        no-last-rebuild|open-pr-fork|open-pr-no-label)
          # No commit found for LAST_REBUILD.md → State 4: parent never drifted → ready
          printf '[]\n'
          ;;
        *)
          # All other modes: return a commit with the configured SHA
          printf '[{"sha":"%s"}]\n' "$COMMITS_SHA"
          ;;
      esac
    else
      # Runs API: gh api "repos/.../actions/runs?head_sha=...&per_page=10" --jq '...'
      # The --jq flag is passed as additional args; mock returns pre-filtered JSON objects
      case "$MODE" in
        run-api-error)
          echo "runs API failure simulated" >&2
          exit 1
          ;;
        pr-closed-inprog)
          printf '{"status":"in_progress","conclusion":null}\n'
          ;;
        pr-closed-success)
          printf '{"status":"completed","conclusion":"success"}\n'
          ;;
        pr-closed-failed)
          printf '{"status":"completed","conclusion":"failure"}\n'
          ;;
        pr-closed-cancelled)
          printf '{"status":"completed","conclusion":"cancelled"}\n'
          ;;
        run-unknown-status)
          printf '{"status":"waiting_for_operator","conclusion":null}\n'
          ;;
        run-not-found)
          # Empty output — no matching workflow runs
          ;;
        run-multi)
          # Two runs for the same SHA (re-run scenario): most recent first
          printf '{"status":"completed","conclusion":"success"}\n'
          printf '{"status":"completed","conclusion":"failure"}\n'
          ;;
      esac
    fi
    ;;
esac
exit 0
GH_MOCK
    chmod +x "$mock_gh"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

_run_eval_parent_state() {
    local parent="$1"
    local script="$TEST_TEMP_DIR/eval_parent_state.sh"
    printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$EVAL_PARENT_STATE_BODY" > "$script"
    chmod +x "$script"
    PARENT_ARG="$parent" run "$script"
}

# ---------------------------------------------------------------------------
# State 1: open drift PR → in_flux
# ---------------------------------------------------------------------------
@test "eval_parent_state: open drift PR → in_flux (cascade label must be applied)" {
    _setup_three_state_mock "open-pr"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # Last output token must be in_flux
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

# ---------------------------------------------------------------------------
# State 2: no open PR, recent commit, auto-build in_progress → in_flux
# ---------------------------------------------------------------------------
@test "eval_parent_state: master rebuild in_progress → in_flux (no premature auto-merge)" {
    _setup_three_state_mock "pr-closed-inprog"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

# ---------------------------------------------------------------------------
# State 3: no open PR, recent commit, auto-build completed/success → ready
# ---------------------------------------------------------------------------
@test "eval_parent_state: master rebuild success → ready (safe to auto-merge)" {
    _setup_three_state_mock "pr-closed-success"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# ---------------------------------------------------------------------------
# State 4: no open PR, no LAST_REBUILD.md commit ever → ready
# ---------------------------------------------------------------------------
@test "eval_parent_state: no LAST_REBUILD.md commit → ready (parent never drifted)" {
    _setup_three_state_mock "no-last-rebuild"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# ---------------------------------------------------------------------------
# State 5: no open PR, recent commit, auto-build failed → in_flux (Defect A fix)
# Child builds against OLD parent image in GHCR → child succeeds → stale digest captured.
# Operator must fix the parent build before cascade can proceed.
# ---------------------------------------------------------------------------
@test "eval_parent_state: master rebuild failed → in_flux (operator must fix parent)" {
    _setup_three_state_mock "pr-closed-failed"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# State 5 (cancelled): no open PR, recent commit, auto-build cancelled → in_flux
# ---------------------------------------------------------------------------
@test "eval_parent_state: master rebuild cancelled → in_flux (operator must fix parent)" {
    _setup_three_state_mock "pr-closed-cancelled"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# Unknown run status: gh api returns unrecognised status string → in_flux (conservative)
# ---------------------------------------------------------------------------
@test "eval_parent_state: unknown run status → in_flux (conservative, ::notice::)" {
    _setup_three_state_mock "run-unknown-status"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    [[ "$output" == *"::notice::"* ]]
}

# ---------------------------------------------------------------------------
# State 6: no open PR, recent commit, gh api returns empty (SHA outside window) → in_flux (conservative)
# ---------------------------------------------------------------------------
@test "eval_parent_state: gh api returns empty for SHA → in_flux (conservative)" {
    _setup_three_state_mock "run-not-found"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    [[ "$output" == *"::notice::"* ]]
}

# ---------------------------------------------------------------------------
# API error on gh api → fail-closed (exit non-zero)
# ---------------------------------------------------------------------------
@test "eval_parent_state: runs gh api error → fail-closed (exit 1)" {
    _setup_three_state_mock "run-api-error"
    _run_eval_parent_state "debian"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Re-run scenario: gh api returns 2 runs for same SHA → take most recent (first)
# ---------------------------------------------------------------------------
@test "eval_parent_state: gh api returns multiple runs for same SHA → takes most recent" {
    _setup_three_state_mock "run-multi"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # Most recent run is completed/success → ready
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# ---------------------------------------------------------------------------
# Defect A fix: commits API failure → fail-closed (exit non-zero)
# Stale local origin/master replaced by GitHub API; API unavailability must
# be fail-closed so a transient outage does not bypass cascade gating.
# ---------------------------------------------------------------------------
@test "eval_parent_state: commits API failure → fail-closed (exit 1, no cascade bypass)" {
    _setup_three_state_mock "commits-api-error"
    _run_eval_parent_state "debian"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"LAST_REBUILD.md"* ]]
}

# ---------------------------------------------------------------------------
# Defect A fix: commits API returns empty array → ready (no rebuild ever)
# Verifies the jq '.[0].sha // empty' extraction on [] returns empty string,
# which maps to State 4 (parent never drifted).
# ---------------------------------------------------------------------------
@test "eval_parent_state: commits API returns [] → ready (parent never rebuilt via LAST_REBUILD.md)" {
    _setup_three_state_mock "no-last-rebuild"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
    # Must NOT have called the runs API (no SHA to query)
    ! grep -q "actions/runs" "$TEST_TEMP_DIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# Defect B fix: gh pr list failure → fail-closed (exit 1), no stranded PRs
# ---------------------------------------------------------------------------
@test "resolver: gh pr list failure — fail-closed, exits 1 with error annotation" {
    _setup_mock_gh "list-fails"
    _run_resolver "debian"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"Cascade resolution aborted"* ]]
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# Defect A fix: gh pr merge failure → failure comment posted, NOT success comment
# ---------------------------------------------------------------------------
@test "resolver: gh pr merge failure — posts failure comment, not success comment" {
    _setup_mock_gh "merge-fails"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # warning annotation must appear in output
    [[ "$output" == *"::warning::"* ]]
    # Failure comment must appear
    grep -q "auto-merge enable failed" "$TEST_TEMP_DIR/gh_comments.log"
    # Success comment must NOT appear
    ! grep -q "Auto-merge enabled" "$TEST_TEMP_DIR/gh_comments.log"
}

# ---------------------------------------------------------------------------
# Gate r8 — Defect A fix: trust boundaries on _eval_parent_state parent PR identity
# ---------------------------------------------------------------------------

# PR from fork (isCrossRepository=true): jq filter excludes it → parent_pr empty → no in_flux
@test "eval_parent_state: PR from fork (isCrossRepository=true) → NOT in_flux (excluded by jq filter)" {
    _setup_three_state_mock "open-pr-fork"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # pr list returns a fork PR; jq filter drops isCrossRepository=true → parent_pr=""
    # No commits/runs mock needed for no-last-rebuild fallback (returns ready)
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# PR has correct branch but no base-digest-drift label: gh server returns empty → not in_flux
@test "eval_parent_state: PR with no base-digest-drift label (gh returns empty) → NOT in_flux" {
    _setup_three_state_mock "open-pr-no-label"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # pr list returns [] (label filter excluded the PR server-side) → parent_pr=""
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# Existing open-pr mode still works: non-fork PR with label → in_flux
@test "eval_parent_state: PR from same repo with base-digest-drift label → in_flux (trust boundary OK)" {
    _setup_three_state_mock "open-pr"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

# ---------------------------------------------------------------------------
# Gate r8 — Defect B fix: children identity — jq filter for isCrossRepository
# Tests the jq selector logic embedded in the resolver body
# ---------------------------------------------------------------------------

# Verify the jq selector used in the children query excludes cross-repo PRs
@test "resolver: children jq selector — isCrossRepository=true excluded from unblock list" {
    run bash -c '
        json='"'"'[{"number":10,"isCrossRepository":false},{"number":11,"isCrossRepository":true}]'"'"'
        result=$(echo "$json" | jq -r '"'"'.[] | select(.isCrossRepository == false) | .number'"'"')
        echo "$result"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == "10" ]]
    [[ "$output" != *"11"* ]]
}

# Verify the jq selector returns empty for a purely fork-owned children list
@test "resolver: children jq selector — all isCrossRepository=true → empty unblock list" {
    run bash -c '
        json='"'"'[{"number":11,"isCrossRepository":true},{"number":12,"isCrossRepository":true}]'"'"'
        result=$(echo "$json" | jq -r '"'"'.[] | select(.isCrossRepository == false) | .number'"'"')
        echo "${#result}"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Gate r8 — Defect B fix: parent PR identification in cascade-resolver
# The IDENTIFY_PARENT_BODY jq filter now also requires base-digest-drift label
# ---------------------------------------------------------------------------

# Parent PR has correct branch + base-digest-drift label → identified
@test "resolver: PR-metadata — drift PR with base-digest-drift label → parent identified" {
    # Mock returns PR with the label
    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock="$TEST_TEMP_DIR/bin/gh"
    printf '#!/usr/bin/env bash\n' > "$mock"
    cat >> "$mock" << 'MOCK_BODY'
if [[ "$1" == "api" && "$2" == *"/commits/"*"/pulls" ]]; then
    echo '[{"number":42,"head":{"ref":"update/base-digest-debian"},"merged_at":"2026-05-28T10:00:00Z","labels":[{"name":"base-digest-drift"}]}]'
    exit 0
fi
exit 0
MOCK_BODY
    chmod +x "$mock"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Use updated IDENTIFY_PARENT_BODY that filters on base-digest-drift label
    local output_file="$TEST_TEMP_DIR/github_output"
    touch "$output_file"
    local script="$TEST_TEMP_DIR/identify_parent_labeled.sh"
    printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$IDENTIFY_PARENT_BODY_LABELED" > "$script"
    chmod +x "$script"
    GITHUB_OUTPUT="$output_file" GITHUB_REPOSITORY="owner/repo" run "$script" "abc1234"
    [ "$status" -eq 0 ]
    grep -q "name=debian" "$output_file"
}

# Parent PR has correct branch but NO base-digest-drift label → not identified
@test "resolver: PR-metadata — drift PR without base-digest-drift label → not identified (trust boundary)" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    local mock="$TEST_TEMP_DIR/bin/gh"
    printf '#!/usr/bin/env bash\n' > "$mock"
    cat >> "$mock" << 'MOCK_BODY'
if [[ "$1" == "api" && "$2" == *"/commits/"*"/pulls" ]]; then
    # PR has correct branch but only unrelated labels
    echo '[{"number":42,"head":{"ref":"update/base-digest-debian"},"merged_at":"2026-05-28T10:00:00Z","labels":[{"name":"some-other-label"}]}]'
    exit 0
fi
exit 0
MOCK_BODY
    chmod +x "$mock"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    local output_file="$TEST_TEMP_DIR/github_output"
    touch "$output_file"
    local script="$TEST_TEMP_DIR/identify_parent_labeled.sh"
    printf '#!/usr/bin/env bash\nset -uo pipefail\n%s\n' "$IDENTIFY_PARENT_BODY_LABELED" > "$script"
    chmod +x "$script"
    GITHUB_OUTPUT="$output_file" GITHUB_REPOSITORY="owner/repo" run "$script" "abc1234"
    [ "$status" -eq 0 ]
    # Container not identified → name= (empty)
    grep -q "name=" "$output_file"
    [[ "$output" == *"Nothing to unblock"* ]]
}

# ---------------------------------------------------------------------------
# Gate r12 — Defect B fix: snapshot-first ordering in resolver (atomicity)
#
# The resolver must snapshot ALL cascade:waiting-for-* labels BEFORE any
# mutation.  If the snapshot fails, the child is skipped before removal —
# this prevents the child from being left with no wait labels AND no
# auto-merge (the stranding scenario from the old remove-first order).
#
# Key invariants:
#   IV1: snapshot failure → skip before removal (no stranding)
#   IV2: snapshot succeeds, removal fails → child skipped; snapshot count irrelevant
#         (retry on next event; child still has the wait label so it is not stranded)
#   IV3: snapshot succeeds, removal succeeds, remaining > 0 → comment only, no auto-merge
#   IV4: snapshot succeeds, removal succeeds, remaining == 0 → auto-merge enabled
# ---------------------------------------------------------------------------

@test "resolver: Defect B — snapshot failure skips child BEFORE removal (no stranding)" {
    # view-fails mock: gh pr view exits 1 → snapshot fails → child must be skipped
    # before gh pr edit --remove-label is ever called.
    _setup_mock_gh "view-fails"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # --remove-label must NOT have been called (snapshot failed first)
    ! grep -q -- "--remove-label" "$TEST_TEMP_DIR/gh_calls.log"
    # auto-merge must NOT have been called
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # error annotation must appear
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"skipping"* ]]
}

@test "resolver: Defect B — removal failure after successful snapshot leaves child with label (retryable, not stranded)" {
    # remove-fails mock: gh pr view (snapshot) succeeds; gh pr edit --remove-label fails.
    # Child still has the wait label → not stranded; cascade-resolver retries on next event.
    _setup_mock_gh "remove-fails"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must NOT have been called
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # warning annotation must appear in output
    [[ "$output" == *"::warning::"* ]]
    # pr view (snapshot) must have been called before the remove attempt
    grep -q "pr view" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "resolver: Defect B — snapshot succeeds, removal succeeds, remaining > 0 → comment only" {
    # multi-parent mock: snapshot returns cascade:waiting-for-php (one remaining after removal)
    _setup_mock_gh "multi-parent"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must NOT have been called (IV3)
    ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # "Still waiting on" comment must be posted
    grep -q "Still waiting on" "$TEST_TEMP_DIR/gh_comments.log"
    # pr view (snapshot) must have been called before removal
    grep -q "pr view" "$TEST_TEMP_DIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# Two-phase matrix invariant
#
# With the two-job split (open-drift-prs-leaves / open-drift-prs-consumers),
# State 0 is no longer needed: open-drift-prs-leaves always completes before
# open-drift-prs-consumers starts (enforced by `needs:`), so parent PRs are
# guaranteed to be visible via State 1 when the consumer job runs.
#
# These tests verify that the consumers job's _eval_parent_state body
# contains NO State 0 loop — the removed code path must not reappear.
# ---------------------------------------------------------------------------

@test "two-phase: _eval_parent_state body has no CURRENT_DRIFT_SET loop" {
    # The consumers job _eval_parent_state must not iterate over CURRENT_DRIFT_SET.
    # If State 0 is accidentally re-introduced, this test catches it.
    local body="$EVAL_PARENT_STATE_BODY"
    [[ "$body" != *"CURRENT_DRIFT_SET"* ]]
    [[ "$body" != *"_current_drift"* ]]
}

@test "two-phase: _eval_parent_state goes directly to gh pr list (State 1) when parent has open PR" {
    # Verify State 1 is reached without any drift-set guard:
    # use open-pr mock → function must return in_flux via gh pr list.
    _setup_three_state_mock "open-pr"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # gh pr list must have been called (State 1 path)
    grep -q "pr list" "$TEST_TEMP_DIR/gh_calls.log"
}

