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
children=$(gh pr list \
  --label "cascade:waiting-for-${PARENT}" \
  --state open \
  --json number \
  --jq '"'"'.[].number'"'"' 2>/dev/null || true)
if [[ -z "$children" ]]; then
  echo "::notice::No cascade-waiting PRs for parent ${PARENT}"
  exit 0
fi
for child in $children; do
  echo "::notice::Processing child PR #${child} (was waiting for ${PARENT})"
  if ! gh pr edit "$child" --remove-label "cascade:waiting-for-${PARENT}" 2>&1; then
    echo "::warning::Failed to remove cascade:waiting-for-${PARENT} from #${child} — skipping"
    continue
  fi
  if ! remaining=$(gh pr view "$child" \
    --json labels \
    --jq '"'"'[.labels[].name | select(startswith("cascade:waiting-for-"))] | length'"'"' \
    2>/dev/null); then
    echo "::error::Cannot fetch labels for PR #${child}; skipping (will retry on next parent image publish)"
    continue
  fi
  if [[ "$remaining" -gt 0 ]]; then
    if ! still_waiting=$(gh pr view "$child" \
      --json labels \
      --jq '"'"'[.labels[].name | select(startswith("cascade:waiting-for-"))] | join(", ")'"'"' \
      2>/dev/null); then
      still_waiting="(label fetch failed)"
    fi
    echo "::notice::PR #${child} still waiting on: ${still_waiting}"
    gh pr comment "$child" \
      --body "Parent **${PARENT}** drift PR'"'"'s master rebuild succeeded. Still waiting on: ${still_waiting}. Auto-merge will activate when all parents resolve." \
      2>&1 || true
  else
    gh pr merge "$child" --squash --auto 2>&1 || \
      echo "::warning::auto-merge failed for #${child} — may already be enabled or not eligible"
    gh pr comment "$child" \
      --body "All parent drift PRs resolved + their master rebuilds succeeded. Auto-merge enabled — this PR will merge once CI passes." \
      2>&1 || true
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
#   remove-fails   — --remove-label exits 1 → child skipped
#   view-fails     — pr view exits 1 → child skipped (Defect C: no silent "0")
#   no-children    — pr list returns empty
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
    elif [[ "$MODE" == "single-parent" ]]; then
      # No remaining wait labels
      echo "0"
    elif [[ "$MODE" == "multi-parent" ]]; then
      if echo "$@" | grep -q "length"; then
        echo "1"
      else
        echo "cascade:waiting-for-php"
      fi
    fi
    ;;
  "pr merge")
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
    --state open \
    --json number \
    --jq '"'"'.[0].number // empty'"'"'); then
    echo "::error::Failed to query parent PR for ${parent} (cascade safety requires this lookup to succeed). Aborting."
    return 2
  fi
  if [[ -n "$parent_pr" ]]; then
    echo "in_flux"
    return 0
  fi
  local recent_sha
  recent_sha=$(git log origin/master --max-count=10 --pretty=%H -- "${parent}/LAST_REBUILD.md" 2>/dev/null | head -1)
  if [[ -z "$recent_sha" ]]; then
    echo "ready"
    return 0
  fi
  local run_info
  if ! run_info=$(gh run list \
    --workflow="Auto Build & Push" \
    --branch=master \
    --limit 20 \
    --json databaseId,headSha,status,conclusion 2>&1); then
    echo "::error::Failed to query auto-build runs for ${parent} (cascade safety requires this lookup to succeed). Aborting."
    return 2
  fi
  local run_status run_conclusion
  run_status=$(echo "$run_info" | jq -r ".[] | select(.headSha == \"$recent_sha\") | .status" | head -1)
  run_conclusion=$(echo "$run_info" | jq -r ".[] | select(.headSha == \"$recent_sha\") | .conclusion // empty" | head -1)
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
        echo "::warning::Parent ${parent} auto-build status=${run_status} conclusion=${run_conclusion}; treating as ready (failure will surface in child CI)"
        echo "ready"
      fi
      ;;
    *)
      echo "::warning::Parent ${parent} auto-build status=${run_status} conclusion=${run_conclusion}; treating as ready (unknown status)"
      echo "ready"
      ;;
  esac
}
_eval_parent_state "$PARENT_ARG"
'

# Writes a mock gh + git pair for three-state tests.
# $1 = mode:
#   open-pr           — pr list returns PR #10 (State 1: in_flux)
#   pr-closed-inprog  — pr list empty; gh run list returns in_progress run (State 2: in_flux)
#   pr-closed-success — pr list empty; gh run list returns completed/success (State 3: ready)
#   pr-closed-failed  — pr list empty; gh run list returns completed/failure (State 5: ready+warning)
#   run-not-found     — pr list empty; gh run list returns empty array (State 6: in_flux conservative)
#   run-api-error     — pr list empty; gh run list exits 1 (fail-closed)
# GIT_LAST_SHA env controls what git log returns (empty = no commit).
_setup_three_state_mock() {
    local mode="$1"
    local git_sha="${GIT_LAST_SHA:-}"
    mkdir -p "$TEST_TEMP_DIR/bin"
    local calls_log="$TEST_TEMP_DIR/gh_calls.log"
    touch "$calls_log"

    # Write mock gh
    local mock_gh="$TEST_TEMP_DIR/bin/gh"
    printf '#!/usr/bin/env bash\nMODE="%s"\necho "$@" >> "%s"\n' "$mode" "$calls_log" > "$mock_gh"
    cat >> "$mock_gh" << 'GH_MOCK'
SHA="abc123def456"
case "$1 $2" in
  "pr list")
    if [[ "$MODE" == "open-pr" ]]; then
      echo "10"
    fi
    # all other modes: print nothing (no open PR)
    ;;
  "run list")
    case "$MODE" in
      run-api-error)
        echo "API failure simulated" >&2
        exit 1
        ;;
      pr-closed-inprog)
        printf '[{"databaseId":1,"headSha":"%s","status":"in_progress","conclusion":""}]\n' "$SHA"
        ;;
      pr-closed-success)
        printf '[{"databaseId":2,"headSha":"%s","status":"completed","conclusion":"success"}]\n' "$SHA"
        ;;
      pr-closed-failed)
        printf '[{"databaseId":3,"headSha":"%s","status":"completed","conclusion":"failure"}]\n' "$SHA"
        ;;
      run-not-found)
        echo '[]'
        ;;
    esac
    ;;
esac
exit 0
GH_MOCK
    chmod +x "$mock_gh"

    # Write mock git — returns GIT_LAST_SHA when set, empty otherwise
    local mock_git="$TEST_TEMP_DIR/bin/git"
    local sha_val="${GIT_LAST_SHA:-}"
    printf '#!/usr/bin/env bash\nSHA_VAL="%s"\n' "$sha_val" > "$mock_git"
    cat >> "$mock_git" << 'GIT_MOCK'
if [[ "$1" == "log" ]]; then
  if [[ -n "$SHA_VAL" ]]; then
    echo "$SHA_VAL"
  fi
fi
exit 0
GIT_MOCK
    chmod +x "$mock_git"

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
    GIT_LAST_SHA="abc123def456" _setup_three_state_mock "open-pr"
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
    GIT_LAST_SHA="abc123def456" _setup_three_state_mock "pr-closed-inprog"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
}

# ---------------------------------------------------------------------------
# State 3: no open PR, recent commit, auto-build completed/success → ready
# ---------------------------------------------------------------------------
@test "eval_parent_state: master rebuild success → ready (safe to auto-merge)" {
    GIT_LAST_SHA="abc123def456" _setup_three_state_mock "pr-closed-success"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# ---------------------------------------------------------------------------
# State 4: no open PR, no LAST_REBUILD.md commit ever → ready
# ---------------------------------------------------------------------------
@test "eval_parent_state: no LAST_REBUILD.md commit → ready (parent never drifted)" {
    GIT_LAST_SHA="" _setup_three_state_mock "pr-closed-success"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
}

# ---------------------------------------------------------------------------
# State 5: no open PR, recent commit, auto-build failed → ready + warning
# ---------------------------------------------------------------------------
@test "eval_parent_state: master rebuild failed → ready with warning (child CI detects)" {
    GIT_LAST_SHA="abc123def456" _setup_three_state_mock "pr-closed-failed"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "ready" ]
    [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# State 6: no open PR, recent commit, run not findable (pruned) → in_flux (conservative)
# ---------------------------------------------------------------------------
@test "eval_parent_state: auto-build run not found (pruned) → in_flux (conservative)" {
    GIT_LAST_SHA="abc123def456" _setup_three_state_mock "run-not-found"
    _run_eval_parent_state "debian"
    [ "$status" -eq 0 ]
    state_token=$(echo "$output" | grep -E '^(in_flux|ready)$' | tail -1)
    [ "$state_token" = "in_flux" ]
    [[ "$output" == *"::notice::"* ]]
}

# ---------------------------------------------------------------------------
# API error on gh run list → fail-closed (exit non-zero)
# ---------------------------------------------------------------------------
@test "eval_parent_state: gh run list API error → fail-closed (exit 1)" {
    GIT_LAST_SHA="abc123def456" _setup_three_state_mock "run-api-error"
    _run_eval_parent_state "debian"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
}
