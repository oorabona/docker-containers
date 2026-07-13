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
precommit_head_stats="$state/precommit_head_stats"
commit_stats="$state/commit_stats"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/git.log"

ensure_local_head() {
  if [[ ! -f "$local_head_stats" ]]; then
    if [[ -f "$head_stats" ]]; then
      cp "$head_stats" "$local_head_stats"
    else
      : > "$local_head_stats"
    fi
  fi
}

reset_worktree_to_local_head() {
  ensure_local_head
  mkdir -p stats
  cp "$local_head_stats" "$stats_file"
}

reset_worktree_to_origin() {
  mkdir -p stats
  if [[ -f "$head_stats" ]]; then
    cp "$head_stats" "$local_head_stats"
  else
    : > "$local_head_stats"
  fi
  cp "$local_head_stats" "$stats_file"
}

reset_worktree_to_parent() {
  mkdir -p stats
  if [[ -f "$precommit_head_stats" ]]; then
    cp "$precommit_head_stats" "$local_head_stats"
    cp "$local_head_stats" "$stats_file"
  else
    reset_worktree_to_origin
  fi
}

case "${1:-}" in
  config)
    exit 0
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
    cp "$local_head_stats" "$precommit_head_stats"
    cp "$state/index_stats" "$commit_stats"
    cp "$commit_stats" "$local_head_stats"
    commits=$(cat "$state/commit_count" 2>/dev/null || echo 0)
    echo $((commits + 1)) > "$state/commit_count"
    exit 0
    ;;
  push)
    pushes=$(cat "$state/push_count" 2>/dev/null || echo 0)
    pushes=$((pushes + 1))
    echo "$pushes" > "$state/push_count"
    mode="${FAKE_GIT_PUSH_MODE:-always_success}"
    if [[ "$mode" == "always_fail" ]]; then
      exit 1
    fi
    if [[ "$mode" == "success_on_retry" ]]; then
      if [[ "$pushes" -eq 1 ]]; then
        exit 1
      fi
      cp "$commit_stats" "$head_stats"
      exit 0
    fi
    if [[ "$mode" == "ambiguous_fail_once" ]]; then
      # Simulates a network partition where the remote accepts the push but
      # the client never sees the ack: origin (head_stats) DOES advance, yet
      # the command still reports failure to the caller.
      if [[ "$pushes" -eq 1 ]]; then
        cp "$commit_stats" "$head_stats"
        exit 1
      fi
      cp "$commit_stats" "$head_stats"
      exit 0
    fi
    if [[ "$mode" == "concurrent_update_then_success" ]]; then
      # Simulates another run landing a DIFFERENT container's row on origin
      # in between this run's first (lost) push attempt and its retry — the
      # candidate-merge must preserve that concurrent addition, not clobber
      # it with only this run's own alpha row.
      if [[ "$pushes" -eq 1 ]]; then
        printf '{"ts":"2026-07-12T08:00:00Z","date":"2026-07-12","container":"gamma","pull_count":99,"star_count":9,"source":"dockerhub"}\n' \
          > "$head_stats"
        cp "$head_stats" "$state/first_failed_head_stats"
        exit 1
      fi
      cp "$commit_stats" "$head_stats"
      exit 0
    fi
    if [[ "$mode" == "concurrent_malformed_then_success" ]]; then
      if [[ "$pushes" -eq 1 ]]; then
        printf 'not-json\n{ "ts" : "2026-07-12T08:00:00Z", "date" : "2026-07-12", "container" : "gamma", "pull_count" : 99, "star_count" : 9, "source" : "dockerhub" }\n' \
          > "$head_stats"
        exit 1
      fi
      cp "$commit_stats" "$head_stats"
      exit 0
    fi
    cp "$commit_stats" "$head_stats"
    exit 0
    ;;
  reset)
    if [[ "${FAKE_GIT_FAIL_RESET_ALWAYS:-}" == "1" ]]; then
      exit 1
    fi
    if [[ "$*" == *"HEAD~1"* ]]; then
      reset_worktree_to_parent
      exit 0
    fi
    if [[ "$*" == *"origin/master"* ]]; then
      reset_worktree_to_origin
      exit 0
    fi
    reset_worktree_to_local_head
    exit 0
    ;;
  fetch)
    exit 0
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
echo "$*" >> "${FAKE_GIT_STATE:?}/sleep.log"
EOF
    chmod +x "$TEST_REPO/bin/sleep"

    hash -r
    real_jq="$(command -v jq)"
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

    export FAKE_GIT_STATE
    export PATH="$TEST_REPO/bin:$PATH"
    export GITHUB_ACTIONS="true"
    export STATS_PUSH_TOKEN="test-app-token"
    export GITHUB_REPOSITORY="owner/repo"
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

@test "commit-stats-snapshot commits and pushes new candidate data in one attempt" {
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
    grep -qF "commit -m chore(stats): daily Docker Hub pull-count snapshot -- stats/dockerhub-pull-history.jsonl" "$FAKE_GIT_STATE/git.log"
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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]
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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]
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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]

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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]

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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]

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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]

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
    [[ "$output" == *"::warning::Dropping nonconforming candidate-only stats line before signed push"* ]]

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

@test "commit-stats-snapshot retries after a lost push race and persists cleanly" {
    export FAKE_GIT_PUSH_MODE="success_on_retry"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 2 ]
    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 2 ]

    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot re-merges its candidate after a reset, preserving a concurrent run's own addition" {
    # Regression lock for the whole point of the candidate-file design: this
    # run's own collected row (alpha) must survive a reset-and-retry, AND a
    # different row a concurrent run pushed in the meantime (gamma) must NOT
    # be clobbered by blindly restoring the pre-reset candidate wholesale.
    export FAKE_GIT_PUSH_MODE="concurrent_update_then_success"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    # Origin only gained gamma on the lost first attempt, so the reset+merge
    # reconstructs alpha+gamma and a second real push is required.
    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 2 ]

    jq -s -e '
        length == 1
        and .[0].container == "gamma"
    ' "$FAKE_GIT_STATE/first_failed_head_stats" >/dev/null

    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot retry merge preserves malformed and raw formatted origin lines" {
    export FAKE_GIT_PUSH_MODE="concurrent_malformed_then_success"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Refusing to commit stats snapshot because stats/dockerhub-pull-history.jsonl has invalid JSON at line 1"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    mapfile -t merged_lines < "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    [ "${#merged_lines[@]}" -eq 3 ]
    [ "${merged_lines[0]}" = "not-json" ]
    [ "${merged_lines[1]}" = '{ "ts" : "2026-07-12T08:00:00Z", "date" : "2026-07-12", "container" : "gamma", "pull_count" : 99, "star_count" : 9, "source" : "dockerhub" }' ]
    [ "${merged_lines[2]}" = '{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}' ]
}

@test "commit-stats-snapshot recovers from an ambiguous push that actually landed" {
    # `git push` can report failure (network drop after the remote already
    # accepted it) even though origin genuinely advanced. The next attempt's
    # HEAD diff check goes clean (worktree now matches the already-landed
    # data after the reset), correctly converging without a real 2nd push.
    export FAKE_GIT_PUSH_MODE="ambiguous_fail_once"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    jq -e 'select(.container == "alpha" and .pull_count == 42)' "$FAKE_GIT_STATE/head_stats" >/dev/null
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

@test "commit-stats-snapshot reports not persisted after exhausted push retries" {
    export FAKE_GIT_PUSH_MODE="always_fail"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 3 ]
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

@test "commit-stats-snapshot fails closed when retry merge fails" {
    export FAKE_GIT_PUSH_MODE="always_fail"
    export FAKE_JQ_FAIL_MERGE_ON_CALL="3"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not merge collected stats candidate into the worktree"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]
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

@test "commit-stats-snapshot fails closed when cleanup reset fails after an unpushed commit" {
    export FAKE_GIT_PUSH_MODE="always_fail"
    export FAKE_GIT_FAIL_RESET_ALWAYS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
    [[ "$output" == *"::warning::Could not discard failed stats commit on attempt 1"* ]]
    [[ "$output" == *"::warning::Could not reset stats snapshot worktree after attempt 1"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]
}

@test "commit-stats-snapshot retries after a one-shot git add failure" {
    export FAKE_GIT_FAIL_ADD_ONCE="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [ "$(get_output persisted)" = "true" ]
    [[ "$output" == *"::warning::Could not stage stats snapshot on attempt 1"* ]]

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

@test "commit-stats-snapshot reports not persisted when commit and reset never succeed" {
    export FAKE_GIT_FAIL_COMMIT_ALWAYS="1"
    export FAKE_GIT_FAIL_RESET_ALWAYS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [ "$(get_output persisted)" = "false" ]
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
