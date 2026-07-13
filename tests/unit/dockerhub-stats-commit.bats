#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    TEST_REPO="$TEST_TEMP_DIR/repo"
    FAKE_GIT_STATE="$TEST_TEMP_DIR/git-state"
    mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/stats" "$TEST_REPO/bin" "$FAKE_GIT_STATE"
    mkdir -p "$TEST_REPO/alpha" "$TEST_REPO/gamma"
    printf 'FROM scratch\n' > "$TEST_REPO/alpha/Dockerfile"
    printf 'FROM scratch\n' > "$TEST_REPO/gamma/Dockerfile"

    ln -s "$SCRIPTS_DIR/commit-stats-snapshot.sh" "$TEST_REPO/scripts/commit-stats-snapshot.sh"
    # Simulates what the (separate, already-run) collect step left behind.
    printf '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    : > "$FAKE_GIT_STATE/head_stats"

cat > "$TEST_REPO/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GIT_STATE:?}"
stats_file="stats/dockerhub-pull-history.jsonl"
head_stats="$state/head_stats"
local_head_stats="$state/local_head_stats"
commit_stats="$state/commit_stats"
head_oid="$state/head_oid"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/git.log"

branch_state_path() {
  local branch="$1"
  local safe_branch
  safe_branch=$(printf '%s' "$branch" | tr '/:' '__')
  printf '%s/branch_%s_stats\n' "$state" "$safe_branch"
}

branch_commit_path() {
  local branch="$1"
  local safe_branch
  safe_branch=$(printf '%s' "$branch" | tr '/:' '__')
  printf '%s/branch_%s_commit\n' "$state" "$safe_branch"
}

ensure_local_head() {
  if [[ ! -f "$local_head_stats" ]]; then
    if [[ -f "$head_stats" ]]; then
      cp "$head_stats" "$local_head_stats"
    else
      : > "$local_head_stats"
    fi
  fi
}

reset_worktree_to_origin() {
  mkdir -p stats
  if [[ -f "$head_stats" ]]; then
    cp "$head_stats" "$local_head_stats"
  else
    : > "$local_head_stats"
  fi
  cp "$local_head_stats" "$stats_file"
  printf '%s\n' "origin-master" > "$head_oid"
}

case "${1:-}" in
  config)
    exit 0
    ;;
  checkout)
    if { [[ "${2:-}" == "-b" ]] || [[ "${2:-}" == "-B" ]]; } && [[ -n "${3:-}" ]]; then
      ensure_local_head
      printf '%s\n' "$3" > "$state/current_branch"
      exit 0
    fi
    echo "unsupported fake git checkout: $*" >&2
    exit 64
    ;;
  remote)
    if [[ "${2:-}" == "set-url" && "${3:-}" == "origin" ]]; then
      if [[ "${FAKE_GIT_FAIL_SAFE_REMOTE_RESTORE:-}" == "1" && "${4:-}" == "https://github.com/owner/repo.git" ]]; then
        exit 1
      fi
      printf '%s\n' "${4:-}" > "$state/origin_url"
    fi
    exit 0
    ;;
  diff)
    # The production script always compares against HEAD. local_head_stats
    # models that local HEAD; origin/master is head_stats and they coincide
    # at the start of each checkout/reset.
    ensure_local_head
    if [[ "${FAKE_GIT_CORRUPT_ON_DIFF:-}" == "1" ]]; then
      printf 'not-json-after-merge\n' >> "$stats_file"
    fi
    if cmp -s "$stats_file" "$local_head_stats"; then
      exit 0
    fi
    exit 1
    ;;
  add)
    if [[ "${FAKE_GIT_FAIL_ADD_ONCE:-}" == "1" ]] && [[ ! -f "$state/add_failed_once" ]]; then
      : > "$state/add_failed_once"
      exit 1
    fi
    if [[ "${FAKE_GIT_FAIL_ADD_ALWAYS:-}" == "1" ]]; then
      exit 1
    fi
    cp "$stats_file" "$state/index_stats"
    exit 0
    ;;
  commit)
    if [[ "${FAKE_GIT_FAIL_COMMIT_ALWAYS:-}" == "1" ]]; then
      exit 1
    fi
    ensure_local_head
    cp "$state/index_stats" "$commit_stats"
    cp "$commit_stats" "$local_head_stats"
    commits=$(cat "$state/commit_count" 2>/dev/null || echo 0)
    commits=$((commits + 1))
    echo "$commits" > "$state/commit_count"
    printf 'commit-%s\n' "$commits" > "$head_oid"
    exit 0
    ;;
  rev-parse)
    if [[ "${2:-}" == "HEAD" ]]; then
      cat "$head_oid"
      exit 0
    fi
    echo "unsupported fake git rev-parse: $*" >&2
    exit 64
    ;;
  push)
    if [[ "${2:-}" == "origin" && "${3:-}" == "--delete" && -n "${4:-}" ]]; then
      deletes=$(cat "$state/delete_branch_count" 2>/dev/null || echo 0)
      echo $((deletes + 1)) > "$state/delete_branch_count"
      if [[ "${FAKE_GIT_FAIL_DELETE_BRANCH:-}" == "1" ]]; then
        exit 1
      fi
      rm -f "$(branch_state_path "$4")"
      rm -f "$(branch_commit_path "$4")"
      exit 0
    fi

    if [[ "${2:-}" == "--force" && "${3:-}" == "origin" && "${4:-}" == HEAD:* ]]; then
      branch="${4#HEAD:}"
      pushes=$(cat "$state/push_count" 2>/dev/null || echo 0)
      echo $((pushes + 1)) > "$state/push_count"
      mode="${FAKE_GIT_PUSH_MODE:-always_success}"
      if [[ "$mode" == "always_fail" ]]; then
        exit 1
      fi
      if [[ "$mode" == "success_on_retry" ]] && [[ "$pushes" -eq 0 ]]; then
        exit 1
      fi
      cp "$commit_stats" "$(branch_state_path "$branch")"
      cp "$head_oid" "$(branch_commit_path "$branch")"
      printf '%s\n' "$branch" > "$state/pushed_branch"
      exit 0
    fi

    echo "unsupported fake git push: $*" >&2
    exit 64
    ;;
  fetch)
    exit 0
    ;;
  reset)
    if [[ "$*" == *"origin/master"* ]]; then
      reset_worktree_to_origin
      exit 0
    fi
    echo "unsupported fake git reset: $*" >&2
    exit 64
    ;;
  *)
    echo "unsupported fake git command: $*" >&2
    exit 64
    ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/git"

    cat > "$TEST_REPO/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GIT_STATE:?}"
echo "$*" >> "$state/sleep.log"
if [[ -f "$state/fake_time_epoch" ]]; then
  seconds="${1:-0}"
  if [[ "$seconds" =~ ^[0-9]+$ ]]; then
    now=$(cat "$state/fake_time_epoch")
    echo $((now + seconds)) > "$state/fake_time_epoch"
  fi
fi
EOF
    chmod +x "$TEST_REPO/bin/sleep"

    hash -r
    real_date="$(command -v date)"
    real_jq="$(command -v jq)"
    echo 0 > "$FAKE_GIT_STATE/fake_time_epoch"
cat > "$TEST_REPO/bin/date" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if { [[ "\$#" -eq 1 && "\${1:-}" == "+%s" ]] || [[ "\$#" -eq 2 && "\${1:-}" == "-u" && "\${2:-}" == "+%s" ]]; } && [[ -f "\${FAKE_GIT_STATE:?}/fake_time_epoch" ]]; then
  cat "\$FAKE_GIT_STATE/fake_time_epoch"
  exit 0
fi
exec "$real_date" "\$@"
EOF
    chmod +x "$TEST_REPO/bin/date"

cat > "$TEST_REPO/bin/jq" <<EOF
#!/usr/bin/env bash
set -euo pipefail
count_file="\${FAKE_GIT_STATE:?}/jq_count"
count=\$(cat "\$count_file" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "\$count_file"
if [[ "\${FAKE_JQ_FAIL_MERGE:-}" == "1" ]]; then
  exit 42
fi
if [[ -n "\${FAKE_JQ_FAIL_MERGE_ON_CALL:-}" && "\$count" -eq "\$FAKE_JQ_FAIL_MERGE_ON_CALL" ]]; then
  exit 42
fi
exec "$real_jq" "\$@"
EOF
    chmod +x "$TEST_REPO/bin/jq"

    cat > "$TEST_REPO/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GIT_STATE:?}"
head_stats="$state/head_stats"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/gh.log"

safe_ref() {
  printf '%s' "$1" | tr '/:' '__'
}

branch_state_path() {
  printf '%s/branch_%s_stats\n' "$state" "$(safe_ref "$1")"
}

branch_commit_path() {
  printf '%s/branch_%s_commit\n' "$state" "$(safe_ref "$1")"
}

pr_field_path() {
  local number="$1"
  local field="$2"
  printf '%s/pr_%s_%s\n' "$state" "$number" "$field"
}

branch_pr_number_path() {
  printf '%s/pr_branch_%s_number\n' "$state" "$(safe_ref "$1")"
}

next_pr_number() {
  local number
  number=$(cat "$state/pr_next_number" 2>/dev/null || echo 123)
  echo $((number + 1)) > "$state/pr_next_number"
  printf '%s\n' "$number"
}

pr_number_for_ref() {
  local ref="$1"

  if [[ "$ref" =~ ^[0-9]+$ && -f "$(pr_field_path "$ref" head)" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi

  if [[ -f "$(branch_pr_number_path "$ref")" ]]; then
    cat "$(branch_pr_number_path "$ref")"
    return 0
  fi

  return 1
}

merge_pr_branch() {
  local number="$1"
  local branch
  branch=$(cat "$(pr_field_path "$number" head)")
  cp "$(branch_state_path "$branch")" "$head_stats"
  printf '%s\n' "MERGED" > "$(pr_field_path "$number" state)"
  printf '%s\n' "2026-07-12T07:05:00Z" > "$(pr_field_path "$number" merged_at)"
  if [[ -f "$(pr_field_path "$number" delete_branch)" ]]; then
    rm -f "$(branch_state_path "$branch")" "$(branch_commit_path "$branch")"
  fi
}

advance_auto_merge_for_view() {
  local number="$1"
  local per_pr_views="$2"
  local mode="${FAKE_GH_PR_VIEW_MODE:-merged}"
  local branch

  if [[ "$(cat "$(pr_field_path "$number" state)")" != "OPEN" ]]; then
    return 0
  fi

  case "$mode" in
    closed)
      printf '%s\n' "CLOSED" > "$(pr_field_path "$number" state)"
      ;;
    always_open)
      ;;
    open_then_merged)
      if [[ "$per_pr_views" -ge 2 && -f "$(pr_field_path "$number" auto_merge)" ]]; then
        merge_pr_branch "$number"
      fi
      ;;
    stale_once_then_closed_then_merged)
      if [[ ! -f "$state/stale_once_done" ]]; then
        printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
          > "$head_stats"
        cp "$head_stats" "$state/first_stale_head_stats"
        printf '%s\n' "CLOSED" > "$(pr_field_path "$number" state)"
        : > "$state/stale_once_done"
      elif [[ -f "$(pr_field_path "$number" auto_merge)" ]]; then
        merge_pr_branch "$number"
      fi
      ;;
    first_pr_closed_then_merged)
      if [[ ! -f "$state/first_pr_closed_done" ]]; then
        printf '%s\n' "CLOSED" > "$(pr_field_path "$number" state)"
        : > "$state/first_pr_closed_done"
      elif [[ -f "$(pr_field_path "$number" auto_merge)" ]]; then
        merge_pr_branch "$number"
      fi
      ;;
    cover_then_closed)
      if [[ ! -f "$state/cover_then_closed_done" ]]; then
        branch=$(cat "$(pr_field_path "$number" head)")
        cp "$(branch_state_path "$branch")" "$head_stats"
        printf '%s\n' "CLOSED" > "$(pr_field_path "$number" state)"
        : > "$state/cover_then_closed_done"
      elif [[ -f "$(pr_field_path "$number" auto_merge)" ]]; then
        merge_pr_branch "$number"
      fi
      ;;
    fail_once_then_merged|merged)
      if [[ -f "$(pr_field_path "$number" auto_merge)" ]]; then
        merge_pr_branch "$number"
      fi
      ;;
    *)
      echo "unsupported fake gh pr view mode: $mode" >&2
      exit 64
      ;;
  esac
}

case "${1:-} ${2:-}" in
  "pr create")
    if [[ "${FAKE_GH_PR_CREATE_FAIL:-}" == "1" ]]; then
      echo "simulated gh pr create failure" >&2
      exit 1
    fi
    head_branch=""
    while (($# > 0)); do
      case "$1" in
        --head)
          head_branch="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    number=$(next_pr_number)
    printf '%s\n' "${head_branch:?}" > "$(pr_field_path "$number" head)"
    printf '%s\n' "OPEN" > "$(pr_field_path "$number" state)"
    : > "$(pr_field_path "$number" merged_at)"
    printf '%s\n' "$number" > "$(branch_pr_number_path "$head_branch")"
    printf '%s\n' "$number" > "$state/pr_number"
    printf 'https://github.com/owner/repo/pull/%s\n' "$number"
    exit 0
    ;;
  "pr edit")
    if [[ "${FAKE_GH_PR_EDIT_FAIL:-}" == "1" ]]; then
      echo "simulated gh pr edit failure" >&2
      exit 1
    fi
    : > "$state/pr_edit_called"
    exit 0
    ;;
  "pr merge")
    merges=$(cat "$state/pr_merge_count" 2>/dev/null || echo 0)
    echo $((merges + 1)) > "$state/pr_merge_count"
    printf '%s\n' "$*" >> "$state/pr_merge_args"
    if [[ "${FAKE_GH_PR_MERGE_FAIL:-}" == "1" ]]; then
      echo "simulated gh pr merge failure" >&2
      exit 1
    fi

    number="${3:-}"
    if ! number=$(pr_number_for_ref "$number"); then
      echo "could not resolve pull request: ${3:-}" >&2
      exit 1
    fi
    if [[ "$(cat "$(pr_field_path "$number" state)")" != "OPEN" ]]; then
      echo "pull request is not open" >&2
      exit 1
    fi

    match_head=""
    delete_branch=false
    while (($# > 0)); do
      case "$1" in
        --match-head-commit)
          match_head="${2:-}"
          shift 2
          ;;
        --delete-branch)
          delete_branch=true
          shift
          ;;
        *)
          shift
          ;;
      esac
    done

    branch=$(cat "$(pr_field_path "$number" head)")
    actual_head=$(cat "$(branch_commit_path "$branch")" 2>/dev/null || true)
    if [[ -z "$match_head" || "$actual_head" != "$match_head" ]]; then
      echo "head commit mismatch" >&2
      exit 1
    fi

    if [[ "$delete_branch" == "true" ]]; then
      : > "$(pr_field_path "$number" delete_branch)"
    fi
    printf '%s\n' "$match_head" >> "$state/pr_merge_head_commits"
    : > "$(pr_field_path "$number" auto_merge)"
    : > "$state/pr_merge_called"
    exit 0
    ;;
  "pr view")
    ref="${3:-}"
    if ! number=$(pr_number_for_ref "$ref"); then
      echo "could not resolve pull request: $ref" >&2
      exit 1
    fi

    if [[ "$*" == *"--json number"* ]]; then
      printf '%s\n' "$number"
      exit 0
    fi

    mode="${FAKE_GH_PR_VIEW_MODE:-merged}"
    if [[ "$mode" == "fail_once_then_merged" && ! -f "$state/pr_view_failed_once" ]]; then
      : > "$state/pr_view_failed_once"
      echo "simulated transient gh pr view failure" >&2
      exit 1
    fi

    views=$(cat "$state/pr_view_count" 2>/dev/null || echo 0)
    views=$((views + 1))
    echo "$views" > "$state/pr_view_count"
    per_pr_views=$(cat "$(pr_field_path "$number" view_count)" 2>/dev/null || echo 0)
    per_pr_views=$((per_pr_views + 1))
    echo "$per_pr_views" > "$(pr_field_path "$number" view_count)"

    advance_auto_merge_for_view "$number" "$per_pr_views"

    state_value=$(cat "$(pr_field_path "$number" state)")
    merged_at=$(cat "$(pr_field_path "$number" merged_at)")
    printf '%s\t%s\n' "$state_value" "$merged_at"
    exit 0
    ;;
  "pr close")
    if [[ "${FAKE_GH_PR_CLOSE_FAIL:-}" == "1" ]]; then
      echo "simulated gh pr close failure" >&2
      exit 1
    fi
    closes=$(cat "$state/pr_close_count" 2>/dev/null || echo 0)
    echo $((closes + 1)) > "$state/pr_close_count"
    : > "$state/pr_close_called"
    number="${3:-}"
    if number=$(pr_number_for_ref "$number"); then
      printf '%s\n' "CLOSED" > "$(pr_field_path "$number" state)"
      branch=$(cat "$(pr_field_path "$number" head)")
      rm -f "$(branch_state_path "$branch")" "$(branch_commit_path "$branch")"
    fi
    exit 0
    ;;
  *)
    echo "unsupported fake gh command: $*" >&2
    exit 64
    ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/gh"

    export FAKE_GIT_STATE
    export PATH="$TEST_REPO/bin:$PATH"
    export GITHUB_ACTIONS="true"
    export STATS_PUSH_TOKEN="test-app-token"
    export GITHUB_REPOSITORY="owner/repo"
    export GITHUB_RUN_ID="876123"
    export GITHUB_RUN_ATTEMPT="1"
    export GITHUB_OUTPUT="$FAKE_GIT_STATE/github_output"
    : > "$GITHUB_OUTPUT"
}

teardown() {
    teardown_temp_dir
}

get_output() {
    local key="$1"
    grep "^${key}=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "commit-stats-snapshot refuses to run outside GitHub Actions before touching git state" {
    unset GITHUB_ACTIONS

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::scripts/commit-stats-snapshot.sh is CI-only"* ]]

    [ ! -e "$FAKE_GIT_STATE/git.log" ]
}

@test "commit-stats-snapshot treats an already-clean worktree as persisted with no git writes" {
    # Collection produced nothing new (e.g. everything was already recorded
    # today) — the worktree already matches origin, so there's nothing to
    # add/commit/push.
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    [ ! -e "$FAKE_GIT_STATE/commit_count" ]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]
}

@test "commit-stats-snapshot fails closed when configured candidate source is missing" {
    export CANDIDATE_SOURCE_FILE="$TEST_TEMP_DIR/missing-candidate.jsonl"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::error::CANDIDATE_SOURCE_FILE is set but does not exist:"* ]]

    [ ! -e "$FAKE_GIT_STATE/git.log" ]
    [ ! -e "$FAKE_GIT_STATE/commit_count" ]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]
}

@test "commit-stats-snapshot creates per-run branch, PR, label, auto-merge, and waits for merge" {
    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 1 ]
    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null

    # origin_url alone reflects the FINAL state, which the cleanup trap
    # always restores to the safe/unauthenticated URL — check the append-only
    # git.log for evidence the authenticated URL was actually used to push.
    grep -qF "https://x-access-token:test-app-token@github.com/owner/repo.git" "$FAKE_GIT_STATE/git.log"
    grep -qF "fetch --force origin refs/heads/master:refs/remotes/origin/master" "$FAKE_GIT_STATE/git.log"
    grep -qF "checkout -B bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/git.log"
    grep -qF "push --force origin HEAD:bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/git.log"
    grep -qF "commit -m chore(stats): daily Docker Hub pull-count snapshot -- stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/git.log"
    grep -qF "rev-parse HEAD" "$FAKE_GIT_STATE/git.log"
    grep -qF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/gh.log"
    grep -qF "pr edit 123 --add-label automation" "$FAKE_GIT_STATE/gh.log"
    grep -qF "pr merge 123 --squash --auto --delete-branch --match-head-commit commit-1" "$FAKE_GIT_STATE/gh.log"
    grep -qF "pr view 123 --json state,mergedAt" "$FAKE_GIT_STATE/gh.log"
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
}

@test "commit-stats-snapshot does not let failed origin restore abort cleanup" {
    export FAKE_GIT_FAIL_SAFE_REMOTE_RESTORE="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Could not restore unauthenticated origin remote after stats snapshot"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]
}

@test "commit-stats-snapshot merges downloaded candidate into fresh checkout before diff" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot keeps newer checkout row over stale candidate on same key" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"alpha","pull_count":100,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T09:00:00Z","date":"2026-07-12","container":"alpha","pull_count":200,"star_count":2,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]

    jq -s -e '
        length == 1
        and .[0].container == "alpha"
        and .[0].ts == "2026-07-12T09:00:00Z"
        and .[0].pull_count == 200
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot lets genuinely newer candidate win on same key" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"2026-07-12T09:00:00Z","date":"2026-07-12","container":"alpha","pull_count":200,"star_count":2,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"alpha","pull_count":100,"star_count":1,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    jq -s -e '
        length == 1
        and .[0].container == "alpha"
        and .[0].ts == "2026-07-12T09:00:00Z"
        and .[0].pull_count == 200
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot drops candidate rows missing ts instead of replacing committed data" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    committed_line='{"ts":"2026-07-12T09:00:00Z","date":"2026-07-12","container":"alpha","pull_count":200,"star_count":2,"source":"dockerhub"}'
    printf '{"date":"2026-07-12","container":"alpha","pull_count":999,"star_count":9,"source":"dockerhub"}\n{"date":"2026-07-12","container":"gamma","pull_count":777,"star_count":7,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '%s\n' "$committed_line" > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]

    mapfile -t merged_lines < "$FAKE_GIT_STATE/head_stats"
    [ "${#merged_lines[@]}" -eq 1 ]
    [ "${merged_lines[0]}" = "$committed_line" ]
    ! grep -qF '"container":"gamma"' "$FAKE_GIT_STATE/head_stats"
}

@test "commit-stats-snapshot drops candidate rows with malformed ts instead of replacing committed data" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    committed_line='{"ts":"2026-07-12T09:00:00Z","date":"2026-07-12","container":"alpha","pull_count":200,"star_count":2,"source":"dockerhub"}'
    printf '{"ts":"2026-07-12 10:00:00Z","date":"2026-07-12","container":"alpha","pull_count":999,"star_count":9,"source":"dockerhub"}\n{"ts":"not-a-snapshot-ts","date":"2026-07-12","container":"gamma","pull_count":777,"star_count":7,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '%s\n' "$committed_line" > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]

    mapfile -t merged_lines < "$FAKE_GIT_STATE/head_stats"
    [ "${#merged_lines[@]}" -eq 1 ]
    [ "${merged_lines[0]}" = "$committed_line" ]
    ! grep -qF '"container":"gamma"' "$FAKE_GIT_STATE/head_stats"
}

@test "commit-stats-snapshot drops candidate-only malformed raw lines but still commits valid candidate rows" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf 'not-json-from-candidate\n{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    ! grep -qF 'not-json-from-candidate' "$FAKE_GIT_STATE/head_stats"
    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot drops candidate row with unknown container but still commits valid candidate rows" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"fabricated","pull_count":777,"star_count":7,"source":"dockerhub"}\n{"ts":"2026-07-12T07:01:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]

    ! grep -qF '"container":"fabricated"' "$FAKE_GIT_STATE/head_stats"
    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot drops candidate row with future date beyond grace window" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    future_date="$(date -u -d '+2 days' +%Y-%m-%d)"
    printf '{"ts":"%sT07:00:00Z","date":"%s","container":"alpha","pull_count":777,"star_count":7,"source":"dockerhub"}\n{"ts":"2026-07-12T07:01:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' "$future_date" "$future_date" \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]

    ! grep -qF "\"date\":\"$future_date\"" "$FAKE_GIT_STATE/head_stats"
    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot drops candidate row with non-dockerhub source" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":777,"star_count":7,"source":"ghcr"}\n{"ts":"2026-07-12T07:01:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]

    ! grep -qF '"source":"ghcr"' "$FAKE_GIT_STATE/head_stats"
    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot drops candidate rows with negative or fractional counts" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":-1,"star_count":7,"source":"dockerhub"}\n{"ts":"2026-07-13T07:00:00Z","date":"2026-07-13","container":"alpha","pull_count":777,"star_count":-1,"source":"dockerhub"}\n{"ts":"2026-07-14T07:00:00Z","date":"2026-07-14","container":"alpha","pull_count":1.5,"star_count":7,"source":"dockerhub"}\n{"ts":"2026-07-12T07:01:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed PR"* ]]

    ! grep -qF '"pull_count":-1' "$FAKE_GIT_STATE/head_stats"
    ! grep -qF '"star_count":-1' "$FAKE_GIT_STATE/head_stats"
    ! grep -qF '"pull_count":1.5' "$FAKE_GIT_STATE/head_stats"
    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot preserves committed history row that fails new semantic checks" {
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    committed_line='{ "date" : "2019-12-31", "container" : "fabricated", "pull_count" : -5, "star_count" : -1, "source" : "ghcr" }'
    printf '%s\n' "$committed_line" > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    printf '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' \
        > "$candidate_file"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    mapfile -t merged_lines < "$FAKE_GIT_STATE/head_stats"
    [ "${#merged_lines[@]}" -eq 2 ]
    [ "${merged_lines[0]}" = "$committed_line" ]
    [ "${merged_lines[1]}" = '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}' ]
}

@test "commit-stats-snapshot re-merges candidate after a stale PR base advances" {
    export FAKE_GH_PR_VIEW_MODE="stale_once_then_closed_then_merged"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Stats snapshot PR #123 closed without merging"* ]]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 2 ]
    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 2 ]
    [ "$(grep -cF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-2" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr merge 123 --squash --auto --delete-branch --match-head-commit" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr merge 124 --squash --auto --delete-branch --match-head-commit" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]

    jq -s -e '
        length == 1
        and .[0].container == "gamma"
    ' "$FAKE_GIT_STATE/first_stale_head_stats" >/dev/null

    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null

    mapfile -t merge_heads < "$FAKE_GIT_STATE/pr_merge_head_commits"
    [ "${#merge_heads[@]}" -eq 2 ]
    [ "${merge_heads[0]}" = "commit-1" ]
    [ "${merge_heads[1]}" = "commit-2" ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-2_stats" ]
}

@test "commit-stats-snapshot caps each attempt's wait to a fair share of the shared deadline" {
    # A PR that never resolves (always OPEN — modeling a blocked/conflicted
    # PR, the most likely retry trigger since it happens exactly when a
    # sibling stats PR merges first) must not be allowed to consume the
    # entire shared budget on a single attempt's wait — that would starve
    # the remaining attempts that exist specifically to recover from this
    # case. Each attempt gets a fair, dynamically recomputed share of
    # whatever budget remains, so multiple attempts genuinely get to run
    # before the shared deadline is exhausted.
    export FAKE_GH_PR_VIEW_MODE="always_open"
    export STATS_PR_MERGE_TIMEOUT_SECONDS="30"
    export STATS_PR_MERGE_POLL_SECONDS="5"
    export STATS_PR_MIN_MERGE_WAIT_SECONDS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Timed out waiting for stats snapshot PR #123 to merge"* ]]
    [[ "$output" == *"::warning::Not enough stats PR budget remains before attempt 3"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 2 ]
    [ "$(cat "$FAKE_GIT_STATE/pr_close_count")" -eq 2 ]
    [ "$(cat "$FAKE_GIT_STATE/fake_time_epoch")" -le 30 ]
    grep -qF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/gh.log"
    grep -qF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-2" "$FAKE_GIT_STATE/gh.log"
    ! grep -qF "bot/stats-snapshot-876123-1-attempt-3" "$FAKE_GIT_STATE/gh.log"
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-2_stats" ]
}

@test "commit-stats-snapshot uses a fresh PR when a prior attempt's PR closes" {
    export FAKE_GH_PR_VIEW_MODE="first_pr_closed_then_merged"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Stats snapshot PR #123 closed without merging"* ]]

    [ "$(grep -cF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-2" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr merge 123 --squash --auto --delete-branch --match-head-commit" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr merge 124 --squash --auto --delete-branch --match-head-commit" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(cat "$FAKE_GIT_STATE/pr_close_count")" -eq 1 ]
    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-2_stats" ]
}

@test "commit-stats-snapshot cleans a pushed branch when a later attempt converges to no-op" {
    export FAKE_GH_PR_VIEW_MODE="cover_then_closed"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Stats snapshot PR #123 closed without merging"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]
    [ "$(cat "$FAKE_GIT_STATE/pr_close_count")" -eq 1 ]
    grep -qF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/gh.log"
    ! grep -qF "bot/stats-snapshot-876123-1-attempt-2" "$FAKE_GIT_STATE/gh.log"
    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
}

@test "commit-stats-snapshot tolerates a transient PR view failure during a healthy wait" {
    export FAKE_GH_PR_VIEW_MODE="fail_once_then_merged"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Could not inspect stats snapshot PR #123 merge state (attempt 1/3); continuing within the remaining wait budget"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]
    [ "$(grep -cF "pr create --base master --head bot/stats-snapshot-876123-1-attempt-1" "$FAKE_GIT_STATE/gh.log")" -eq 1 ]
    [ "$(grep -cF "pr view 123 --json state,mergedAt" "$FAKE_GIT_STATE/gh.log")" -eq 2 ]
    ! grep -qF "bot/stats-snapshot-876123-1-attempt-2" "$FAKE_GIT_STATE/gh.log"
    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot waits until the stats PR is actually merged" {
    export FAKE_GH_PR_VIEW_MODE="open_then_merged"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    [ "$(cat "$FAKE_GIT_STATE/pr_view_count")" -eq 2 ]
    grep -qF "2" "$FAKE_GIT_STATE/sleep.log"
    grep -qF "10" "$FAKE_GIT_STATE/sleep.log"
    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot fails closed and closes PR when merge polling times out" {
    export FAKE_GH_PR_VIEW_MODE="always_open"
    export STATS_PR_MERGE_TIMEOUT_SECONDS="10"
    export STATS_PR_MERGE_POLL_SECONDS="10"
    export STATS_PR_MIN_MERGE_WAIT_SECONDS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Timed out waiting for stats snapshot PR #123 to merge"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    [ -e "$FAKE_GIT_STATE/pr_close_called" ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
    [ ! -s "$FAKE_GIT_STATE/head_stats" ]
}

@test "commit-stats-snapshot fails closed and closes PR when GitHub reports it closed unmerged" {
    export FAKE_GH_PR_VIEW_MODE="closed"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Stats snapshot PR #123 closed without merging"* ]]

    [ -e "$FAKE_GIT_STATE/pr_close_called" ]
    [ ! -s "$FAKE_GIT_STATE/head_stats" ]
}

@test "commit-stats-snapshot deletes pushed branch when PR creation fails" {
    export FAKE_GH_PR_CREATE_FAIL="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not create stats snapshot PR from bot/stats-snapshot-876123-1-attempt-1"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 3 ]
    [ "$(cat "$FAKE_GIT_STATE/delete_branch_count")" -eq 3 ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
    [ ! -s "$FAKE_GIT_STATE/head_stats" ]
}

@test "commit-stats-snapshot reports no reconciled missing rows when current stats is complete despite incomplete candidate" {
    today="$(date -u +%Y-%m-%d)"
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"%sT06:00:00Z","date":"%s","container":"alpha","pull_count":41,"star_count":1,"source":"dockerhub"}\n' "$today" "$today" \
        > "$candidate_file"
    printf '{"ts":"%sT07:00:00Z","date":"%s","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n{"ts":"%sT08:00:00Z","date":"%s","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' "$today" "$today" "$today" "$today" \
        > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [ "$(get_output still_missing_after_reconcile)" = "false" ]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]
}

@test "commit-stats-snapshot reports reconciled missing rows when an allowlisted container is absent today" {
    today="$(date -u +%Y-%m-%d)"
    candidate_file="$TEST_TEMP_DIR/candidate.jsonl"
    printf '{"ts":"%sT07:00:00Z","date":"%s","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}\n' "$today" "$today" \
        > "$candidate_file"
    cp "$candidate_file" "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    cp "$TEST_REPO/stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/head_stats"
    export CANDIDATE_SOURCE_FILE="$candidate_file"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [ "$(get_output still_missing_after_reconcile)" = "true" ]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]
}

@test "commit-stats-snapshot reports not persisted when the PR branch push fails" {
    export FAKE_GIT_PUSH_MODE="always_fail"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not push stats snapshot branch bot/stats-snapshot-876123-1-attempt-1"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 3 ]
    [ ! -e "$FAKE_GIT_STATE/gh.log" ]
    [ ! -s "$FAKE_GIT_STATE/head_stats" ]
}

@test "commit-stats-snapshot fails closed when upfront candidate merge fails" {
    export FAKE_JQ_FAIL_MERGE="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not merge collected stats candidate into the worktree"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    [ ! -e "$FAKE_GIT_STATE/push_count" ]
}

@test "commit-stats-snapshot fails closed and closes PR when auto-merge setup fails" {
    export FAKE_GH_PR_MERGE_FAIL="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Failed to enable auto-merge for stats snapshot PR #123"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 3 ]
    [ "$(cat "$FAKE_GIT_STATE/pr_merge_count")" -eq 3 ]
    [ -e "$FAKE_GIT_STATE/pr_close_called" ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
}

@test "commit-stats-snapshot refuses to stage when final JSONL validation catches post-merge corruption" {
    export FAKE_GIT_CORRUPT_ON_DIFF="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Refusing to commit stats snapshot because stats/dockerhub-pull-history.jsonl has invalid JSON at line 2"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    [ ! -e "$FAKE_GIT_STATE/index_stats" ]
    [ ! -e "$FAKE_GIT_STATE/commit_count" ]
    [ ! -e "$FAKE_GIT_STATE/push_count" ]
}

@test "commit-stats-snapshot warns but keeps primary failure when stale PR cleanup fails" {
    export FAKE_GH_PR_MERGE_FAIL="1"
    export FAKE_GH_PR_CLOSE_FAIL="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not close stale stats snapshot PR #123 or delete branch bot/stats-snapshot-876123-1-attempt-1 after failure"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    [ "$(cat "$FAKE_GIT_STATE/delete_branch_count")" -eq 3 ]
    [ ! -e "$FAKE_GIT_STATE/branch_bot_stats-snapshot-876123-1-attempt-1_stats" ]
}

@test "commit-stats-snapshot retries after a one-shot git add failure" {
    export FAKE_GIT_FAIL_ADD_ONCE="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Could not stage stats snapshot on attempt 1"* ]]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 1 ]
    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]
    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot reports not persisted when git add always fails" {
    export FAKE_GIT_FAIL_ADD_ALWAYS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    [ ! -e "$FAKE_GIT_STATE/commit_count" ]
}

@test "commit-stats-snapshot reports not persisted when commit fails" {
    export FAKE_GIT_FAIL_COMMIT_ALWAYS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not commit stats snapshot"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    [ ! -e "$FAKE_GIT_STATE/commit_count" ]
    # The worktree still holds the never-committed candidate row — proving
    # this scenario actually exercised the divergence — while origin
    # (head_stats) never advanced.
    jq -e 'select(.container == "alpha")' "$TEST_REPO/stats/dockerhub-pull-history.jsonl" >/dev/null
    [ ! -s "$FAKE_GIT_STATE/head_stats" ]
}

@test "commit-stats-snapshot uses STATS_PUSH_TOKEN, not a generic GITHUB_TOKEN name" {
    # Comment lines are excluded — the script's header prose explains why a
    # generic GITHUB_TOKEN categorically cannot authenticate this push, which
    # itself contains the substring being checked for absence in real code.
    grep -q 'STATS_PUSH_TOKEN' "$SCRIPTS_DIR/commit-stats-snapshot.sh"
    non_comment_lines="$(grep -v '^\s*#' "$SCRIPTS_DIR/commit-stats-snapshot.sh")"
    [[ "$non_comment_lines" != *'GITHUB_TOKEN'* ]]
}
