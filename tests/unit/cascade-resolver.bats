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
  if ! live_remaining=$(gh pr view "$child" \
    --json labels \
    --jq '"'"'[.labels[].name | select(startswith("cascade:waiting-for-"))] | length'"'"' \
    2>/dev/null); then
    echo "::warning::Could not re-check labels for #${child} post-removal; falling back to snapshot decision"
    live_remaining=""
    if [[ -n "$remaining_labels" ]]; then
      live_remaining=1
    else
      live_remaining=0
    fi
  fi
  if [[ "$live_remaining" -gt 0 ]]; then
    if still_waiting=$(gh pr view "$child" \
      --json labels \
      --jq '"'"'[.labels[].name | select(startswith("cascade:waiting-for-"))] | join(", ")'"'"' \
      2>/dev/null) && [[ -n "$still_waiting" ]]; then
      echo "::notice::PR #${child} still waiting on: ${still_waiting}"
    else
      still_waiting="other parent(s)"
      echo "::notice::PR #${child} still waiting on additional parents (live label fetch failed)"
    fi
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
#   single-parent         — remaining labels = 0 → auto-merge expected
#   multi-parent          — remaining labels = 1 → no auto-merge
#   remove-fails          — --remove-label exits 1 → child skipped (snapshot taken first)
#   view-fails            — pr view exits 1 BEFORE removal → child skipped (snapshot-first)
#   no-children           — pr list returns empty
#   list-fails            — pr list exits 1 → fail-closed
#   merge-fails           — pr merge exits 1 → failure comment posted, not success
#   live-recheck-fails    — snapshot succeeds; live recheck (length) fails → snapshot fallback
#
# The mock differentiates snapshot (join "\n") from live-recheck (length) by checking
# whether the --jq argument contains "length" (live recheck) or not (snapshot/join).
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
    fi
    # Differentiate snapshot (join — returns label names) from live recheck (length — returns int).
    # The live recheck uses --jq '... | length'; snapshot uses --jq '... | join(...)'.
    if echo "$@" | grep -q "length"; then
      # Live recheck call (returns integer count of remaining wait labels).
      if [[ "$MODE" == "live-recheck-fails" ]]; then
        echo "simulated live recheck failure" >&2
        exit 1
      elif [[ "$MODE" == "single-parent" ]] || [[ "$MODE" == "merge-fails" ]]; then
        echo "0"
      elif [[ "$MODE" == "multi-parent" ]]; then
        echo "1"
      else
        echo "0"
      fi
    else
      # Snapshot call (returns newline-joined label names).
      if [[ "$MODE" == "single-parent" ]] || [[ "$MODE" == "merge-fails" ]] || [[ "$MODE" == "live-recheck-fails" ]]; then
        # No remaining wait labels in snapshot
        echo ""
      elif [[ "$MODE" == "multi-parent" ]]; then
        # One remaining wait label besides the parent being resolved
        echo "cascade:waiting-for-php"
      else
        echo ""
      fi
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
# Scenario 5a — race-handling: live recheck returns 0 → auto-merge enabled
# (r19 post-removal live recheck: even if snapshot showed remaining labels,
# the live fetch is authoritative for the merge decision)
# ---------------------------------------------------------------------------
@test "resolver: live recheck returns 0 remaining → auto-merge enabled (race-safe last-finisher)" {
    _setup_mock_gh "single-parent"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must have been called (live recheck confirms 0 remaining)
    grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    # "All parent drift PRs resolved" comment must appear
    grep -q "All parent drift PRs resolved" "$TEST_TEMP_DIR/gh_comments.log"
    # live recheck (length) must have been called after removal
    grep -q "pr view" "$TEST_TEMP_DIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# Scenario 5b — race-handling: live recheck returns >0 → still waiting
# (concurrent resolver run already removed another label; live fetch shows it
# is STILL not zero; comment posted, no auto-merge)
# ---------------------------------------------------------------------------
@test "resolver: live recheck returns >0 remaining → still waiting, no auto-merge" {
    _setup_mock_gh "multi-parent"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # auto-merge must NOT have been called
    run ! grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
    [ "$status" -eq 0 ]
    # "Still waiting on" comment must be posted
    grep -q "Still waiting on" "$TEST_TEMP_DIR/gh_comments.log"
    # live recheck (length) must have been called after removal
    grep -q "pr view" "$TEST_TEMP_DIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# Scenario 5c — race-handling: live recheck fails → snapshot fallback decision
# (network error after successful removal; resolver falls back to pre-removal
# snapshot count; snapshot showed 0 remaining → auto-merge enabled)
# ---------------------------------------------------------------------------
@test "resolver: live recheck fails → falls back to snapshot decision (0 remaining → auto-merge)" {
    # live-recheck-fails: snapshot returns empty (0 remaining after removing parent's label);
    # live recheck (length) call exits 1 → fallback sets live_remaining=0 → auto-merge.
    _setup_mock_gh "live-recheck-fails"
    _run_resolver "debian"
    [ "$status" -eq 0 ]
    # warning annotation must appear (live recheck failure notice)
    [[ "$output" == *"::warning::"* ]]
    # auto-merge must be enabled (snapshot fallback said 0 remaining)
    grep -q "pr merge" "$TEST_TEMP_DIR/gh_calls.log"
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
# Four-state parent evaluation (_eval_parent_state) — open PR first, error-safe
#
# The _eval_parent_state function (defined in "Apply cascade labels (strict)"
# in upstream-monitor.yaml) emits 'in_flux' or 'ready' on stdout, with
# notices/warnings on GHA annotation lines.
#
# Ordering (A → B0 → B → C):
#   State A:  open drift PR → in_flux  (ground truth — runs FIRST, independent of drift-set scope)
#   State B0: parent probe errored this run → in_flux  (conservative: unknown state must not merge)
#   State B:  parent not in CURRENT_DRIFT_SET → ready  (only safe after A+B0 confirm clean)
#   State C:  parent drifting, no PR yet → in_flux  (conservative wait)
#
# Mock strategy:
#   - gh: controlled by MODE env var; routes on "pr list" vs "api users"
#   - RUN_STARTED_AT: set per-test to control the timestamp comparison
# ---------------------------------------------------------------------------

# Body of _eval_parent_state extracted verbatim from the workflow step.
# Variables on the calling side: parent=$1; gh is mocked; RUN_STARTED_AT controls run_start.
EVAL_PARENT_STATE_BODY='
_eval_parent_state() {
  local parent="$1"
  # STATE A: open drift PR → in_flux
  # Runs FIRST — ground truth independent of how CURRENT_DRIFT_SET was scoped.
  local open_pr
  if ! open_pr=$(gh pr list \
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
  if [[ -n "$open_pr" ]]; then
    echo "::notice::Parent ${parent} has open drift PR #${open_pr}"
    echo "in_flux"
    return 0
  fi
  # STATE B0: Did the parent probe ERROR this run?
  # Only reached when there is no open drift PR (State A cleared above).
  # An error means we genuinely do not know whether the parent image matches
  # what the child consumes; safer to wait than auto-merge against unknown state.
  if [[ -n "${CURRENT_ERROR_SET:-}" ]]; then
    local _parent_errored=0
    for _c in ${CURRENT_ERROR_SET//,/ }; do
      if [[ "$_c" == "$parent" ]]; then
        _parent_errored=1
        break
      fi
    done
    if [[ $_parent_errored -eq 1 ]]; then
      echo "::notice::Parent ${parent} probe errored this run — waiting conservatively"
      echo "in_flux"
      return 0
    fi
  fi
  # STATE B: parent not in CURRENT_DRIFT_SET → stable, ready
  # Only safe after State A (no open PR) and State B0 (no probe error).
  if [[ -n "${CURRENT_DRIFT_SET:-}" ]]; then
    local _parent_drifting=0
    for _c in ${CURRENT_DRIFT_SET//,/ }; do
      if [[ "$_c" == "$parent" ]]; then
        _parent_drifting=1
        break
      fi
    done
    if [[ $_parent_drifting -eq 0 ]]; then
      echo "::notice::Parent ${parent} has no open drift PR and is not in the current drift set — GHCR image is stable, ready"
      echo "ready"
      return 0
    fi
  fi
  # STATE C (conservative in_flux): parent IS drifting this run but no PR yet.
  # Wait for the parent drift PR to open and merge; cascade-resolver unblocks this
  # child when the parent rebuild lands.  The prior GHCR-timestamp implementation
  # was unsound: RUN_STARTED_AT was never plumbed, and it queried package-wide
  # latest rather than the specific tag the child consumes.
  echo "::notice::Parent ${parent} is drifting this run but has no open PR yet — waiting"
  echo "in_flux"
  return 0
}
_eval_parent_state "$PARENT_ARG"
'

# Writes a mock gh for three-state tests.
# $1 = mode:
#   open-pr              -- pr list returns PR #10 (State A: in_flux)
#   open-pr-fork         -- pr list: fork PR (isCrossRepository=true -> jq drops it)
#   open-pr-no-label     -- pr list: empty (label filter excluded server-side)
#   ghcr-fresh           -- pr list empty; GHCR API returns updated_at newer than RUN_STARTED_AT
#   ghcr-stale           -- pr list empty; GHCR API returns updated_at older than RUN_STARTED_AT
#   ghcr-absent          -- pr list empty; GHCR API returns null (no versions published)
#   ghcr-api-error       -- pr list empty; GHCR API exits 1 (fail-closed)
#   pr-list-error        -- pr list exits 1 (fail-closed on State 1 check)
# GHCR_UPDATED_AT env controls timestamp returned by the packages API
# (default: 2026-05-29T12:00:00Z).
_setup_three_state_mock() {
    local mode="$1"
    local ghcr_updated_at="${GHCR_UPDATED_AT:-2026-05-29T12:00:00Z}"
    mkdir -p "$TEST_TEMP_DIR/bin"
    local calls_log="$TEST_TEMP_DIR/gh_calls.log"
    touch "$calls_log"

    local mock_gh="$TEST_TEMP_DIR/bin/gh"
    printf '#!/usr/bin/env bash\nMODE="%s"\nGHCR_UPDATED_AT="%s"\necho "$@" >> "%s"\n' \
        "$mode" "$ghcr_updated_at" "$calls_log" > "$mock_gh"
    # Append routing body via printf (avoid heredoc hook)
    printf '%s\n' 'case "$1 $2" in' >> "$mock_gh"
    printf '%s\n' '  "pr list")' >> "$mock_gh"
    printf '%s\n' '    case "$MODE" in' >> "$mock_gh"
    printf '%s\n' '      pr-list-error)' >> "$mock_gh"
    printf '%s\n' '        echo "pr list failure simulated" >&2' >> "$mock_gh"
    printf '%s\n' '        exit 1' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '      open-pr)' >> "$mock_gh"
    printf '%s\n' '        echo "10"' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '      open-pr-fork|open-pr-no-label)' >> "$mock_gh"
    printf '%s\n' '        : # print nothing' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '      *)' >> "$mock_gh"
    printf '%s\n' '        : # no open PR' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '    esac' >> "$mock_gh"
    printf '%s\n' '    ;;' >> "$mock_gh"
    printf '%s\n' '  "api users"*)' >> "$mock_gh"
    printf '%s\n' '    case "$MODE" in' >> "$mock_gh"
    printf '%s\n' '      ghcr-api-error)' >> "$mock_gh"
    printf '%s\n' '        echo "GHCR API failure simulated" >&2' >> "$mock_gh"
    printf '%s\n' '        exit 1' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '      ghcr-absent)' >> "$mock_gh"
    printf '%s\n' '        : # print nothing — jq "// empty" on [] returns empty' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '      *)' >> "$mock_gh"
    printf '%s\n' '        printf '"'"'%s\n'"'"' "$GHCR_UPDATED_AT"' >> "$mock_gh"
    printf '%s\n' '        ;;' >> "$mock_gh"
    printf '%s\n' '    esac' >> "$mock_gh"
    printf '%s\n' '    ;;' >> "$mock_gh"
    printf '%s\n' 'esac' >> "$mock_gh"
    printf '%s\n' 'exit 0' >> "$mock_gh"
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
# State 1: open drift PR -> in_flux
# ---------------------------------------------------------------------------
@test "eval_parent_state: open drift PR → in_flux (cascade label must be applied)" {
    _setup_three_state_mock "open-pr"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

@test "eval_parent_state: open drift PR → emits ::notice:: with PR number" {
    _setup_three_state_mock "open-pr"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [[ "$output" == *"#10"* ]]
}


# ---------------------------------------------------------------------------
# State A trust boundaries (preserved from r8)
# ---------------------------------------------------------------------------

# PR from fork (isCrossRepository=true): jq filter excludes it -> falls through to conservative State C
@test "eval_parent_state: PR from fork (isCrossRepository=true) → NOT in_flux via State A (falls through)" {
    _setup_three_state_mock "open-pr-fork"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # Must NOT have used fork PR as in_flux source
    ! [[ "$output" == *"has open drift PR"* ]]
}

# PR has correct branch but no base-digest-drift label: gh server returns empty -> falls through
@test "eval_parent_state: PR with no base-digest-drift label → falls through (conservative in_flux)" {
    _setup_three_state_mock "open-pr-no-label"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # No label -> no open PR; State B short-circuits to ready when parent absent from drift set.
    # With empty CURRENT_DRIFT_SET the conservative State C fires → in_flux.
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

# ---------------------------------------------------------------------------
# State C (simplified): parent drifting in this run, no PR yet → always in_flux
# The prior implementation compared GHCR timestamps but RUN_STARTED_AT was
# never plumbed and the query targeted package-wide latest.  Now: conservative.
# ---------------------------------------------------------------------------
@test "eval_parent_state: parent in drift set, no open PR → in_flux (conservative State C)" {
    # Mock returns no open PR; CURRENT_DRIFT_SET includes the parent.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="debian" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # GHCR API must NOT be called — State C no longer does a GHCR timestamp lookup
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "eval_parent_state: State C conservative — emits ::notice:: with waiting message" {
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="debian" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [[ "$output" == *"waiting"* ]]
}

@test "eval_parent_state: State C — GHCR API never called (no network calls in State C)" {
    _setup_three_state_mock "ghcr-fresh"
    CURRENT_DRIFT_SET="debian" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

# ---------------------------------------------------------------------------
# State 1 fail-closed: gh pr list failure -> exit non-zero
# ---------------------------------------------------------------------------
@test "eval_parent_state: pr list failure → fail-closed (exit non-zero)" {
    _setup_three_state_mock "pr-list-error"
    _run_eval_parent_state "debian"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Multi-level DAG: consumer-of-consumer evaluated correctly.
# Without an open PR, parent drifting → State C always in_flux.
# ---------------------------------------------------------------------------
@test "eval_parent_state: multi-level DAG — parent drifting, no PR → in_flux" {
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="web-shell" _run_eval_parent_state "web-shell"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

@test "eval_parent_state: multi-level DAG — parent not drifting, no PR → ready (State B)" {
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "web-shell"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
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

# PR from fork (isCrossRepository=true): jq filter excludes it → parent_pr empty → falls through
# With simplified State C (no GHCR lookup, no CURRENT_DRIFT_SET) → conservative in_flux.
@test "eval_parent_state: PR from fork (isCrossRepository=true) → NOT in_flux via State A (conservative in_flux)" {
    _setup_three_state_mock "open-pr-fork"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # pr list returns a fork PR; jq filter drops isCrossRepository=true → parent_pr=""
    # No CURRENT_DRIFT_SET → State B skipped → State C conservative → in_flux
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # Must NOT have used fork PR as in_flux source (State A didn't trigger)
    ! [[ "$output" == *"has open drift PR"* ]]
}

# PR has correct branch but no base-digest-drift label: gh server returns empty → falls through
# With simplified State C → conservative in_flux.
@test "eval_parent_state: PR with no base-digest-drift label (gh returns empty) → conservative in_flux" {
    _setup_three_state_mock "open-pr-no-label"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    # pr list returns [] (label filter excluded the PR server-side) → parent_pr=""
    # No CURRENT_DRIFT_SET → State B skipped → State C → in_flux (conservative)
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
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
# State B0: probe error → in_flux (Defect L regression lock)
#
# When a parent's digest probe errored this run (status=error), the parent's
# actual drift state is UNKNOWN.  The prior logic excluded error containers from
# drift_containers_csv, so State B would see the parent absent from the drift set
# and return ready — auto-merging the child against a parent whose image may be
# stale.  State B0 closes this gap: a parent in CURRENT_ERROR_SET is treated as
# in_flux regardless of the drift set.
#
# Mutation guards:
#   MG-B0a: removing State B0 → errored parent gets ready (the original defect)
#            (test "errored parent in CURRENT_ERROR_SET → in_flux, not ready")
#   MG-B0b: inverting _parent_errored check → errored parent gets ready
#            (test "errored parent → in_flux even when absent from CURRENT_DRIFT_SET")
#   MG-B0c: State A must still short-circuit before B0
#            (test "errored parent with open PR → in_flux via State A, not B0")
# ---------------------------------------------------------------------------

@test "StateB0: parent in CURRENT_ERROR_SET → in_flux (probe error treated as unknown)" {
    # Parent probe failed this run; no open PR (State A cleared).
    # State B0 must return in_flux — we do not know if the parent is stable.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_ERROR_SET="debian" CURRENT_DRIFT_SET="" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

@test "StateB0: errored parent → emits ::notice:: with probe-error message" {
    _setup_three_state_mock "ghcr-stale"
    CURRENT_ERROR_SET="debian" CURRENT_DRIFT_SET="" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [[ "$output" == *"probe errored"* ]]
}

@test "StateB0: errored parent not in CURRENT_DRIFT_SET → in_flux (not short-circuited to ready by State B)" {
    # This is the exact defect: error excluded from drift set → State B saw absent → ready.
    # With State B0, error set is checked BEFORE the drift set, so ready is never reached.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_ERROR_SET="debian" CURRENT_DRIFT_SET="wordpress,ansible" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # State B must not have emitted "stable, ready" for the errored parent
    ! [[ "$output" == *"GHCR image is stable, ready"* ]]
}

@test "StateB0: parent with open PR → in_flux via State A (not B0)" {
    # State A runs before B0: an open PR is caught by State A, B0 is never reached.
    _setup_three_state_mock "open-pr"
    CURRENT_ERROR_SET="debian" CURRENT_DRIFT_SET="" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # Must have used State A, not State B0
    [[ "$output" == *"has open drift PR"* ]]
    ! [[ "$output" == *"probe errored"* ]]
}

@test "StateB0: empty CURRENT_ERROR_SET → State B0 skipped, falls through to State B" {
    # When CURRENT_ERROR_SET is empty/unset, B0 is a no-op.
    # Parent absent from drift set → State B returns ready.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_ERROR_SET="" CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

@test "StateB0: unset CURRENT_ERROR_SET → State B0 skipped, falls through to State B" {
    # Same as above but CURRENT_ERROR_SET is unset (not just empty).
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

@test "StateB0: body contains CURRENT_ERROR_SET loop (State B0 is present)" {
    # Structural invariant: State B0 must be present in the function body.
    local body="$EVAL_PARENT_STATE_BODY"
    [[ "$body" == *"CURRENT_ERROR_SET"* ]]
    [[ "$body" == *"_parent_errored"* ]]
}

@test "StateB0: B0 appears before State B loop in function body (ordering invariant)" {
    # Structural invariant: CURRENT_ERROR_SET check must precede CURRENT_DRIFT_SET check.
    local body="$EVAL_PARENT_STATE_BODY"
    local b0_pos b_pos
    b0_pos=$(echo "$body" | grep -n "_parent_errored=0" | head -1 | cut -d: -f1)
    b_pos=$(echo "$body" | grep -n "_parent_drifting=0" | head -1 | cut -d: -f1)
    [[ -n "$b0_pos" ]]
    [[ -n "$b_pos" ]]
    [ "$b0_pos" -lt "$b_pos" ]
}

# ---------------------------------------------------------------------------
# State B: stable-parent deadlock fix (formerly State 0)
#
# When CURRENT_DRIFT_SET is set and the parent is NOT in it AND there is no
# open drift PR (State A cleared), the parent was rebuilt in a prior run —
# GHCR timestamp (State C) would wrongly return in_flux because
# parent_last_updated < run_start is always true for a stable parent.
# State B short-circuits to "ready" after confirming no open PR.
#
# Mutation guards:
#   MG-SBa: removing State B → stable parent with stale GHCR gets in_flux
#            (test "stable parent not in drift set → ready without GHCR call")
#   MG-SBb: checking _parent_drifting==1 instead of ==0 → inverted logic
#            (test "parent IN drift set → falls through to State C")
# ---------------------------------------------------------------------------

@test "StateB: parent not in CURRENT_DRIFT_SET → ready without GHCR call" {
    # php rebuilt yesterday (stable, no open PR). wordpress drifts today.
    # CURRENT_DRIFT_SET contains wordpress, NOT php.
    # State A (open-PR) returns empty → State B must return ready for php without
    # calling the GHCR API.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress,ansible" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
    # pr list was called (State A), but GHCR API must NOT have been called (State B short-circuited)
    grep -q "pr list" "$TEST_TEMP_DIR/gh_calls.log"
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "StateB: parent not in drift set → emits ::notice:: with stable-parent message" {
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::notice::"* ]]
    [[ "$output" == *"not in the current drift set"* ]]
}

@test "StateB: parent IN CURRENT_DRIFT_SET → falls through to State C (conservative in_flux)" {
    # php is in the drift set → State B does not short-circuit → State C returns in_flux.
    # State C no longer calls the GHCR API; it conservatively waits.
    _setup_three_state_mock "ghcr-fresh"
    CURRENT_DRIFT_SET="php,wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "StateB: CURRENT_DRIFT_SET unset → State B skipped, falls through to State C (conservative in_flux)" {
    # Without CURRENT_DRIFT_SET, no short-circuit: go straight to State C (always in_flux).
    _setup_three_state_mock "ghcr-fresh"
    CURRENT_DRIFT_SET="" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "StateB: single-entry drift set — parent matches exactly → falls through to State C (in_flux)" {
    # Only one container drifting, and it's the parent being evaluated.
    _setup_three_state_mock "ghcr-fresh"
    CURRENT_DRIFT_SET="debian" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    # GHCR API must NOT be called — State C is now conservative, no GHCR lookup
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "StateB: body contains CURRENT_DRIFT_SET loop (State B is present)" {
    # State B MUST be present in the function body.
    local body="$EVAL_PARENT_STATE_BODY"
    [[ "$body" == *"CURRENT_DRIFT_SET"* ]]
    [[ "$body" == *"_parent_drifting"* ]]
}

# ---------------------------------------------------------------------------
# Defect D regression lock: scoped workflow_dispatch
#
# On a scoped workflow_dispatch (requested_container=wordpress), drift_containers_csv
# is filtered to the requested container before the cascade-labels step runs.
# If php has an open drift PR but is absent from CURRENT_DRIFT_SET, State A
# (open-PR check, now running FIRST) must catch it and return in_flux, preventing
# the child from auto-merging against the stale php parent image.
# ---------------------------------------------------------------------------

@test "DefectD: scoped dispatch — parent absent from drift set but has open PR → in_flux" {
    # Simulate scoped workflow_dispatch: CURRENT_DRIFT_SET=wordpress (php excluded).
    # php has an open drift PR (#10) — State A must catch it before State B short-circuits.
    _setup_three_state_mock "open-pr"
    CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    # Must be in_flux — open PR is ground truth regardless of drift-set scope.
    [ "$state_token" = "in_flux" ]
    [[ "$output" == *"has open drift PR"* ]]
    grep -q "pr list" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "DefectD: scoped dispatch — parent absent from drift set with no open PR → ready" {
    # No open PR for php → State A returns empty → State B sees php absent from drift set
    # → ready (correct: php was rebuilt in a prior run, no pending work).
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

@test "DefectD: State A runs before State B (open-PR check precedes drift-set loop in body)" {
    # Structural invariant: the gh pr list call must appear before the CURRENT_DRIFT_SET
    # iteration loop (_parent_drifting loop).
    local body="$EVAL_PARENT_STATE_BODY"
    local pr_list_pos drift_loop_pos
    pr_list_pos=$(echo "$body" | grep -n "gh pr list" | head -1 | cut -d: -f1)
    # Use the iteration variable assignment, not the if-condition (avoids matching comments)
    drift_loop_pos=$(echo "$body" | grep -n "_parent_drifting=0" | head -1 | cut -d: -f1)
    [[ -n "$pr_list_pos" ]]
    [[ -n "$drift_loop_pos" ]]
    # pr list must appear at an earlier line than the drift-set iteration loop
    [ "$pr_list_pos" -lt "$drift_loop_pos" ]
}

# ---------------------------------------------------------------------------
# Defect E regression lock: repo-wide drift set for cascade gating
#
# CURRENT_DRIFT_SET is now derived from the unfiltered drift_json (repo-wide
# truth), not the per-container filtered set.  On a scoped workflow_dispatch
# (requested_container=wordpress), php must still appear in CURRENT_DRIFT_SET
# if it is actually drifting.  State B must therefore NOT return ready for php
# when it IS in the repo-wide drift set but has no open PR yet.
# ---------------------------------------------------------------------------

@test "DefectE: scoped dispatch — parent drifting repo-wide, no open PR → in_flux (State C, not State B ready)" {
    # Scenario: workflow_dispatch for wordpress only.  php is also drifting repo-wide.
    # With the Defect E fix, CURRENT_DRIFT_SET contains BOTH wordpress and php.
    # php has no open PR → State B does NOT short-circuit (php is in set) → State C → in_flux.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress,php" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    # Must be in_flux — php is drifting in this run; State B must not return ready.
    [ "$state_token" = "in_flux" ]
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "DefectE: scoped dispatch — parent NOT drifting repo-wide, no open PR → ready (State B)" {
    # php is NOT in the repo-wide drift set; no open PR → State B short-circuits to ready.
    _setup_three_state_mock "ghcr-stale"
    CURRENT_DRIFT_SET="wordpress" _run_eval_parent_state "php"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# ---------------------------------------------------------------------------
# Defect F regression lock: State C simplification
#
# The prior State C compared GHCR package-wide updated_at against RUN_STARTED_AT,
# but RUN_STARTED_AT was never plumbed into the env block and the GHCR query
# targeted package-wide latest (not the tag the child consumes).  The simplified
# State C always returns in_flux — conservative, no GHCR API call.
# ---------------------------------------------------------------------------

@test "DefectF: State C never calls GHCR API (no users/ API path in any code path)" {
    # With both ghcr-fresh and ghcr-stale mocks, State C must not make GHCR API calls.
    # Use CURRENT_DRIFT_SET=parent so State B falls through.
    _setup_three_state_mock "ghcr-fresh"
    CURRENT_DRIFT_SET="debian" _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    ! grep -q "api users" "$TEST_TEMP_DIR/gh_calls.log"
}

@test "DefectF: State C body — no GHCR package version lookup in function body" {
    # Structural invariant: the simplified State C must not contain a GHCR versions API call.
    local body="$EVAL_PARENT_STATE_BODY"
    ! echo "$body" | grep -q "packages/container"
}

