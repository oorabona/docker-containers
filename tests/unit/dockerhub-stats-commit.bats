#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    TEST_REPO="$TEST_TEMP_DIR/repo"
    FAKE_GIT_STATE="$TEST_TEMP_DIR/git-state"
    mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/stats" "$TEST_REPO/bin" "$TEST_REPO/helpers" "$FAKE_GIT_STATE"

    ln -s "$SCRIPTS_DIR/commit-stats-snapshot.sh" "$TEST_REPO/scripts/commit-stats-snapshot.sh"
    : > "$TEST_REPO/stats/dockerhub-pull-history.jsonl"
    : > "$FAKE_GIT_STATE/head_stats"
    : > "$FAKE_GIT_STATE/index_stats"

    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p stats
stats_file="stats/dockerhub-pull-history.jsonl"
line='{"ts":"2026-07-12T07:00:00Z","date":"2026-07-12","container":"alpha","pull_count":42,"star_count":1,"source":"dockerhub"}'
if [[ ! -f "$stats_file" ]] || ! grep -qF '"date":"2026-07-12","container":"alpha"' "$stats_file"; then
  printf '%s\n' "$line" >> "$stats_file"
fi
echo "snapshot" >> "${FAKE_GIT_STATE:?}/snapshot.log"
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    cat > "$TEST_REPO/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GIT_STATE:?}"
printf '%s\n' "$*" >> "$state/gh.log"
calls=$(cat "$state/gh_call_count" 2>/dev/null || echo 0)
echo $((calls + 1)) > "$state/gh_call_count"
if [[ "${FAKE_GH_FAIL:-}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
    chmod +x "$TEST_REPO/bin/gh"

    cat > "$TEST_REPO/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GIT_STATE:?}"
stats_file="stats/dockerhub-pull-history.jsonl"
head_stats="$state/head_stats"
index_stats="$state/index_stats"
commit_stats="$state/commit_stats"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/git.log"

copy_head_to_worktree() {
  mkdir -p stats
  if [[ -f "$head_stats" ]]; then
    cp "$head_stats" "$stats_file"
    cp "$head_stats" "$index_stats"
  else
    : > "$stats_file"
    : > "$index_stats"
  fi
}

case "${1:-}" in
  config)
    exit 0
    ;;
  remote)
    if [[ "${2:-}" == "set-url" && "${3:-}" == "origin" ]]; then
      printf '%s\n' "${4:-}" > "$state/origin_url"
    fi
    exit 0
    ;;
  diff)
    # `git diff --quiet -- path` (no ref) is worktree-vs-INDEX; `git diff
    # --quiet HEAD -- path` is worktree-vs-HEAD. The production script always
    # passes HEAD (compare_against=head_stats below) — the index_stats branch
    # exists so a dedicated test can demonstrate what the old ref-less form
    # would have wrongly reported.
    compare_against="$index_stats"
    for arg in "$@"; do
      if [[ "$arg" == "HEAD" ]]; then
        compare_against="$head_stats"
        break
      fi
    done
    if cmp -s "$stats_file" "$compare_against"; then
      exit 0
    fi
    exit 1
    ;;
  add)
    if [[ "${FAKE_GIT_FAIL_ADD:-}" == "1" ]]; then
      exit 1
    fi
    cp "$stats_file" "$index_stats"
    exit 0
    ;;
  commit)
    if [[ "${FAKE_GIT_FAIL_COMMIT_ALWAYS:-}" == "1" ]]; then
      exit 1
    fi
    if [[ "${FAKE_GIT_FAIL_COMMIT_ONCE:-}" == "1" ]] && [[ ! -f "$state/commit_failed_once" ]]; then
      : > "$state/commit_failed_once"
      exit 1
    fi
    cp "$index_stats" "$commit_stats"
    commits=$(cat "$state/commit_count" 2>/dev/null || echo 0)
    echo $((commits + 1)) > "$state/commit_count"
    exit 0
    ;;
  push)
    pushes=$(cat "$state/push_count" 2>/dev/null || echo 0)
    pushes=$((pushes + 1))
    echo "$pushes" > "$state/push_count"
    mode="${FAKE_GIT_PUSH_MODE:-success_on_retry}"
    if [[ "$mode" == "always_fail" ]]; then
      exit 1
    fi
    if [[ "$mode" == "always_success" ]]; then
      cp "$commit_stats" "$head_stats"
      cp "$commit_stats" "$index_stats"
      exit 0
    fi
    if [[ "$mode" == "success_once_then_fail" ]]; then
      if [[ "$pushes" -eq 1 ]]; then
        cp "$commit_stats" "$head_stats"
        cp "$commit_stats" "$index_stats"
        exit 0
      fi
      exit 1
    fi
    if [[ "$mode" == "ambiguous_fail_once" ]]; then
      # Simulates a network partition where the remote accepts the push but
      # the client never sees the ack: origin (head_stats) DOES advance, yet
      # the command still reports failure to the caller.
      if [[ "$pushes" -eq 1 ]]; then
        cp "$commit_stats" "$head_stats"
        cp "$commit_stats" "$index_stats"
        exit 1
      fi
      cp "$commit_stats" "$head_stats"
      cp "$commit_stats" "$index_stats"
      exit 0
    fi
    if [[ "$pushes" -eq 1 ]]; then
      exit 1
    fi
    cp "$commit_stats" "$head_stats"
    cp "$commit_stats" "$index_stats"
    exit 0
    ;;
  reset)
    if [[ "$*" == *"origin/master"* ]] && [[ "${FAKE_GIT_FAIL_RESET_ALWAYS:-}" == "1" ]]; then
      exit 1
    fi
    if [[ "$*" == *"origin/master"* ]] && [[ "${FAKE_GIT_FAIL_RESET_ONCE:-}" == "1" ]] && [[ ! -f "$state/reset_failed_once" ]]; then
      : > "$state/reset_failed_once"
      exit 1
    fi
    copy_head_to_worktree
    exit 0
    ;;
  fetch)
    if [[ "${FAKE_GIT_FAIL_FETCH_FOR_HASH:-}" == "1" ]]; then
      exit 1
    fi
    exit 0
    ;;
  show)
    # `git show origin/master:stats/dockerhub-pull-history.jsonl` — models
    # origin's actual content via head_stats (the mock's stand-in for
    # origin/master), regardless of whatever the local worktree currently
    # holds. An absent/empty head_stats prints nothing (real git exits
    # nonzero for a missing path; remote_stats_hash tolerates that the same
    # way it tolerates a fetch failure — empty input, not a script error).
    if [[ -s "$head_stats" ]]; then
      cat "$head_stats"
      exit 0
    fi
    exit 128
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

    export FAKE_GIT_STATE
    export PATH="$TEST_REPO/bin:$PATH"
    export GITHUB_ACTIONS="true"
    export GITHUB_TOKEN="test-token"
    export GITHUB_REPOSITORY="owner/repo"
}

teardown() {
    teardown_temp_dir
}

@test "commit-stats-snapshot refuses to run outside GitHub Actions before touching git state" {
    unset GITHUB_ACTIONS

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::scripts/commit-stats-snapshot.sh is CI-only"* ]]

    [ ! -e "$FAKE_GIT_STATE/git.log" ]
    [ ! -e "$FAKE_GIT_STATE/commit_count" ]
    [ ! -e "$FAKE_GIT_STATE/origin_url" ]
}

@test "commit-stats-snapshot falls back to push-confirmed status when the remote hash check is degraded" {
    # remote_stats_hash does its OWN fetch at both the start and end of the
    # run, independent of retry_cleanup's. If that fetch fails, it returns
    # the REMOTE_HASH_UNKNOWN sentinel (distinct from a CONFIRMED-empty
    # hash) rather than crashing — a raw comparison against an unknown
    # baseline could misfire in either direction, so the dispatch decision
    # instead falls back to whether a `git push` itself reported success.
    # Here it did (always_success), so the fallback correctly dispatches
    # despite never being able to directly verify origin's content.
    export FAKE_GIT_PUSH_MODE="always_success"
    export FAKE_GIT_FAIL_FETCH_FOR_HASH="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Could not fetch origin/master to check remote stats state"* ]]
    [[ "$output" == *"::warning::Remote stats hash check was unavailable this run; falling back to this run's own confirmed push status"* ]]

    # The push itself still succeeded on the very first attempt (always_success),
    # so retry_cleanup is never invoked at all here — only remote_stats_hash's
    # own two fetch calls (before and after the loop) exercise this knob.
    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]
}

@test "commit-stats-snapshot does not dispatch on a degraded remote check without a confirmed push" {
    # Same degraded remote-hash situation as above, but this time NOTHING
    # was ever pushed (persistent add failure) — the fallback must not
    # dispatch just because the remote check happened to be unavailable.
    export FAKE_GIT_FAIL_ADD="1"
    export FAKE_GIT_FAIL_FETCH_FOR_HASH="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::warning::Could not fetch origin/master to check remote stats state"* ]]
    [[ "$output" != *"Remote stats hash check was unavailable this run; falling back"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count" 2>/dev/null || echo 0)
    [ "$pushes" -eq 0 ]

    [ ! -e "$FAKE_GIT_STATE/gh_call_count" ]
}

@test "commit-stats-snapshot dispatches the follow-up build after an ambiguous push that actually landed" {
    # Regression lock: `git push` can report failure (network drop after the
    # remote already accepted it) even though origin genuinely advanced. A
    # push-exit-code flag would miss this — the retry loop's own reset picks
    # up the already-landed data and exits via the "nothing new" path, which
    # looks identical to a true no-op run. remote_stats_hash (a fresh fetch +
    # `git show origin/master:...`, modeled by head_stats in this mock, NOT
    # the local worktree) catches it regardless: origin's content for this
    # file DID change during this run, so the follow-up build must still fire.
    export FAKE_GIT_PUSH_MODE="ambiguous_fail_once"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    # Only one push call was ever attempted by the script itself — the
    # "second" push in the fake (pushes -eq 1 branch) never actually fires;
    # the retry loop's own reset-and-recheck is what discovers the landed data.
    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    jq -e '
        select(.date == "2026-07-12" and .container == "alpha" and .pull_count == 42)
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null

    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]
}

@test "commit-stats-snapshot retries after rejected push and persists one idempotent row" {
    export FAKE_GIT_PUSH_MODE="success_on_retry"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 2 ]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 2 ]

    rows=$(jq -s 'length' "$TEST_REPO/stats/dockerhub-pull-history.jsonl")
    [ "$rows" -eq 1 ]

    duplicate_pairs=$(jq -s '
        group_by(.date + "/" + .container)
        | map(select(length > 1))
        | length
    ' "$TEST_REPO/stats/dockerhub-pull-history.jsonl")
    [ "$duplicate_pairs" -eq 0 ]

    origin_url=$(cat "$FAKE_GIT_STATE/origin_url")
    [ "$origin_url" = "https://github.com/owner/repo.git" ]
    [[ "$origin_url" != *"test-token"* ]]

    grep -q 'reset --hard HEAD~1' "$FAKE_GIT_STATE/git.log"
    grep -q 'reset --hard origin/master' "$FAKE_GIT_STATE/git.log"

    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]
    grep -q 'workflow run update-dashboard.yaml' "$FAKE_GIT_STATE/gh.log"
    grep -q -- '--ref master' "$FAKE_GIT_STATE/gh.log"
}

@test "commit-stats-snapshot retries cleanly after a fully-failed attempt, one commit once progress exists" {
    # Contract: the loop only keeps looping past a successful push when THAT
    # push was itself partial (some containers still missing). Here attempt 1
    # makes zero progress (every container fails, no diff at all) and attempt 2
    # is a FULLY successful fetch, so it breaks immediately on attempt 2 same as
    # a single-attempt success would.
    export FAKE_GIT_PUSH_MODE="always_success"

    rm "$TEST_REPO/scripts/snapshot-stats.sh"
    ln -s "$SCRIPTS_DIR/snapshot-stats.sh" "$TEST_REPO/scripts/snapshot-stats.sh"
    cp "$HELPERS_DIR/logging.sh" "$TEST_REPO/helpers/logging.sh"

    for container in alpha beta gamma; do
        mkdir -p "$TEST_REPO/$container"
        printf 'FROM alpine:3.21\n' > "$TEST_REPO/$container/Dockerfile"
    done

    CURL_LOG="$FAKE_GIT_STATE/curl.log"
    export CURL_LOG
    cat > "$TEST_REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
container="${url%/}"
container="${container##*/}"
echo "$container" >> "$CURL_LOG"

count_file="${FAKE_GIT_STATE:?}/curl-${container}-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$count_file"

if [[ "$count" -eq 1 ]]; then
  exit 22
fi

case "$container" in
  alpha) printf '{"pull_count":600,"star_count":6}\n' ;;
  beta)  printf '{"pull_count":700,"star_count":7}\n' ;;
  gamma) printf '{"pull_count":800,"star_count":8}\n' ;;
  *)     printf '{"pull_count":0,"star_count":0}\n' ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/curl"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 1"* ]]
    [[ "$output" == *"::warning::Stats snapshot collection made no commit-worthy progress on attempt 1"* ]]

    fetches=$(cat "$CURL_LOG")
    [ "$fetches" = $'alpha\nbeta\ngamma\nalpha\nbeta\ngamma' ]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 1 ]

    today="$(date -u +%Y-%m-%d)"
    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today)]
        | length == 3
        and (map(.container) | sort == ["alpha", "beta", "gamma"])
    ' "$TEST_REPO/stats/dockerhub-pull-history.jsonl" >/dev/null

    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today)]
        | length == 3
        and (map(.container) | sort == ["alpha", "beta", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null

    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]
}

@test "commit-stats-snapshot persists successful rows despite persistent partial snapshot failure" {
    export FAKE_GIT_PUSH_MODE="always_success"

    rm "$TEST_REPO/scripts/snapshot-stats.sh"
    ln -s "$SCRIPTS_DIR/snapshot-stats.sh" "$TEST_REPO/scripts/snapshot-stats.sh"
    cp "$HELPERS_DIR/logging.sh" "$TEST_REPO/helpers/logging.sh"

    for container in alpha beta gamma; do
        mkdir -p "$TEST_REPO/$container"
        printf 'FROM alpine:3.21\n' > "$TEST_REPO/$container/Dockerfile"
    done

    CURL_LOG="$FAKE_GIT_STATE/curl-persistent.log"
    export CURL_LOG
    cat > "$TEST_REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
container="${url%/}"
container="${container##*/}"
echo "$container" >> "$CURL_LOG"

case "$container" in
  alpha) printf '{"pull_count":600,"star_count":6}\n' ;;
  beta)  exit 22 ;;
  gamma) printf '{"pull_count":800,"star_count":8}\n' ;;
  *)     printf '{"pull_count":0,"star_count":0}\n' ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/curl"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 1; some containers failed"* ]]
    [[ "$output" == *"::warning::Persisted partial stats snapshot on attempt 1"* ]]
    [[ "$output" == *"::error::Exhausted retries with some containers still missing"* ]]

    # Contract: a partial success keeps retrying with the remaining attempts to
    # top up the still-missing container. alpha/gamma are idempotently skipped
    # (already recorded today) on attempts 2 and 3 — only beta gets re-fetched.
    fetches=$(cat "$CURL_LOG")
    [ "$fetches" = $'alpha\nbeta\ngamma\nbeta\nbeta' ]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 1 ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    # Something DID get pushed (alpha+gamma on attempt 1) even though the run
    # as a whole reports failure — the follow-up dashboard build still fires
    # so that partial progress isn't stuck behind the next independent trigger.
    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]

    today="$(date -u +%Y-%m-%d)"
    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today)]
        | length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
        and all((.pull_count | type) == "number" and (.star_count | type) == "number")
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null

    jq -s -e --arg today "$today" '
        [.[] | select(.date == $today and .container == "beta")]
        | length == 0
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot retries instead of misreading a staged-but-uncommitted index as already persisted" {
    # Regression lock for a double-failure sequence: attempt 1's `git add`
    # succeeds (index now diverges from HEAD) but `git commit` fails, and the
    # cleanup's `git reset --hard origin/master` ALSO fails — so neither the
    # worktree nor the index gets reset back to HEAD. On attempt 2, the
    # snapshot is idempotently skipped (today's row is already in the
    # worktree from attempt 1) and the ref-less `git diff` form would see
    # worktree == index (both still hold the never-committed change) and
    # wrongly report "clean" — exiting with persisted=true having pushed
    # nothing. Comparing against HEAD (real fix) correctly sees the worktree
    # still differs from origin/master's actual state and retries the
    # add+commit+push to completion.
    export FAKE_GIT_PUSH_MODE="always_success"
    export FAKE_GIT_FAIL_COMMIT_ONCE="1"
    export FAKE_GIT_FAIL_RESET_ONCE="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Could not commit stats snapshot on attempt 1"* ]]
    [[ "$output" == *"::warning::Could not reset stats snapshot worktree after attempt 1"* ]]
    [[ "$output" != *"Could not persist stats snapshot this run"* ]]

    commits=$(cat "$FAKE_GIT_STATE/commit_count")
    [ "$commits" -eq 1 ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 1 ]

    jq -e '
        select(.date == "2026-07-12" and .container == "alpha" and .pull_count == 42)
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null

    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]
}

@test "commit-stats-snapshot warns when a later fully-successful fetch never gets pushed" {
    # Regression lock: attempt 1 fetches alpha+gamma (beta fails) and pushes
    # that partial progress — persisted=true. Attempt 2's fetch is FULLY
    # successful (beta recovers), but its push fails, as does attempt 3's.
    # A `still_missing` that only tracks the FETCH outcome of the most recent
    # attempt would be wrongly cleared on attempt 2/3 (fetch succeeded) even
    # though beta's row was never actually confirmed on origin/master — the
    # final "some containers still missing" warning would then never fire,
    # silently losing visibility into recoverable data that just needs
    # another push, not another fetch.
    export FAKE_GIT_PUSH_MODE="success_once_then_fail"

    rm "$TEST_REPO/scripts/snapshot-stats.sh"
    ln -s "$SCRIPTS_DIR/snapshot-stats.sh" "$TEST_REPO/scripts/snapshot-stats.sh"
    cp "$HELPERS_DIR/logging.sh" "$TEST_REPO/helpers/logging.sh"

    for container in alpha beta gamma; do
        mkdir -p "$TEST_REPO/$container"
        printf 'FROM alpine:3.21\n' > "$TEST_REPO/$container/Dockerfile"
    done

    CURL_LOG="$FAKE_GIT_STATE/curl-recover.log"
    export CURL_LOG
    cat > "$TEST_REPO/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
container="${url%/}"
container="${container##*/}"
echo "$container" >> "$CURL_LOG"

if [[ "$container" == "beta" ]]; then
  count_file="${FAKE_GIT_STATE:?}/curl-beta-count"
  count=$(cat "$count_file" 2>/dev/null || echo 0)
  count=$((count + 1))
  echo "$count" > "$count_file"
  if [[ "$count" -eq 1 ]]; then
    exit 22
  fi
fi

case "$container" in
  alpha) printf '{"pull_count":600,"star_count":6}\n' ;;
  beta)  printf '{"pull_count":700,"star_count":7}\n' ;;
  gamma) printf '{"pull_count":800,"star_count":8}\n' ;;
  *)     printf '{"pull_count":0,"star_count":0}\n' ;;
esac
EOF
    chmod +x "$TEST_REPO/bin/curl"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::warning::Persisted partial stats snapshot on attempt 1"* ]]
    [[ "$output" == *"::error::Exhausted retries with some containers still missing"* ]]

    # beta: fails attempt 1, succeeds attempts 2 and 3 (fetch works both times,
    # but its push never lands) — confirms the fetch DID fully succeed on a
    # later attempt while still never reaching origin/master.
    fetches=$(cat "$CURL_LOG")
    [ "$fetches" = $'alpha\nbeta\ngamma\nbeta\nbeta' ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 3 ]

    # attempt 1's push DID land (alpha+gamma) — the follow-up build still fires.
    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]

    jq -s -e '
        [.[] | select(.container == "beta")]
        | length == 0
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null

    jq -s -e '
        length == 2
        and (map(.container) | sort == ["alpha", "gamma"])
    ' "$FAKE_GIT_STATE/head_stats" >/dev/null
}

@test "commit-stats-snapshot never dispatches on a worktree-only divergence that survives to the end of the run" {
    # Regression lock, sharper than the two tests above: commit NEVER
    # succeeds (so retry_cleanup never even attempts the HEAD~1 reset) AND
    # the origin/master reset ALWAYS fails too — so copy_head_to_worktree is
    # never called at all, and the worktree keeps holding alpha's row
    # (staged on attempt 1, never reset) all the way to the final hash check,
    # while origin (head_stats) never advances. A local-worktree-based hash
    # would see initial=empty, final=alpha and WRONGLY dispatch a follow-up
    # build for data that was never actually persisted anywhere — this is
    # exactly codex's "push that never landed can still dispatch" scenario.
    # remote_stats_hash is immune: both ends read origin directly and see
    # the same untouched empty content.
    export FAKE_GIT_FAIL_COMMIT_ALWAYS="1"
    export FAKE_GIT_FAIL_RESET_ALWAYS="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    commits=$(cat "$FAKE_GIT_STATE/commit_count" 2>/dev/null || echo 0)
    [ "$commits" -eq 0 ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count" 2>/dev/null || echo 0)
    [ "$pushes" -eq 0 ]

    # The worktree DOES still hold the never-committed row — proving this
    # test actually exercises the divergence, not a no-op.
    jq -e 'select(.container == "alpha")' "$TEST_REPO/stats/dockerhub-pull-history.jsonl" >/dev/null

    # origin never advanced — no follow-up dispatch, despite the worktree
    # divergence above.
    [ ! -e "$FAKE_GIT_STATE/gh_call_count" ]
}

@test "commit-stats-snapshot fails loudly after exhausted push retries" {
    # Regression lock: a persistence mechanism that NEVER succeeds (e.g. a
    # revoked token, branch protection change) must not report success —
    # this job has no downstream dependents (deploy only needs build), so
    # failing it is isolated and visible rather than silently green forever.
    export FAKE_GIT_PUSH_MODE="always_fail"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count")
    [ "$pushes" -eq 3 ]

    # 3 loop attempts, no extra repopulate call (removed — nothing downstream
    # ever consumed it, the local worktree is thrown away with the ephemeral
    # runner once the job ends, and the call pushed the worst-case runtime
    # too close to the job timeout during a sustained Docker Hub outage).
    # The local file is correctly left EMPTY here (every retry_cleanup resets
    # it to origin/master's actual, never-pushed-to state) — origin/master,
    # not this ephemeral worktree, is the real source of truth.
    snapshots=$(wc -l < "$FAKE_GIT_STATE/snapshot.log")
    [ "$snapshots" -eq 3 ]

    origin_url=$(cat "$FAKE_GIT_STATE/origin_url")
    [ "$origin_url" = "https://github.com/owner/repo.git" ]
    [[ "$origin_url" != *"test-token"* ]]

    # Nothing was ever pushed — no follow-up dashboard build to trigger.
    [ ! -e "$FAKE_GIT_STATE/gh_call_count" ]
}

@test "commit-stats-snapshot fails loudly when git add fails mid-loop" {
    export FAKE_GIT_FAIL_ADD="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::warning::Could not stage stats snapshot on attempt 1"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    pushes=$(cat "$FAKE_GIT_STATE/push_count" 2>/dev/null || echo 0)
    [ "$pushes" -eq 0 ]

    # 3 loop attempts, no extra repopulate call — see the note above.
    snapshots=$(wc -l < "$FAKE_GIT_STATE/snapshot.log")
    [ "$snapshots" -eq 3 ]

    origin_url=$(cat "$FAKE_GIT_STATE/origin_url")
    [ "$origin_url" = "https://github.com/owner/repo.git" ]
    [[ "$origin_url" != *"test-token"* ]]

    # The default fake snapshot-stats.sh still writes a fresh row into the
    # local worktree file on every attempt even though `git add` never lets
    # it get staged — this doubles as a regression lock for remote_stats_hash
    # reading origin (head_stats), never the local worktree: origin was
    # never touched here, so no dispatch, despite the worktree differing.
    [ ! -e "$FAKE_GIT_STATE/gh_call_count" ]
}

@test "commit-stats-snapshot pins SNAPSHOT_DATE_OVERRIDE once and holds it across all retry attempts" {
    # Regression lock: without a pinned date, a run whose retries straddle a
    # UTC midnight rollover would silently start filling a NEW day partway
    # through, abandoning the original day's still-missing rows while
    # reporting success. The wrapper must export the SAME date value to
    # every attempt, not recompute it each time.
    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "${SNAPSHOT_DATE_OVERRIDE:-UNSET}" >> "${FAKE_GIT_STATE:?}/date-override.log"
exit 1
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]

    seen_dates=$(sort -u "$FAKE_GIT_STATE/date-override.log")
    line_count=$(wc -l < "$FAKE_GIT_STATE/date-override.log")
    [ "$line_count" -eq 3 ]
    # Exactly one distinct, non-empty value across all 3 attempts.
    [ "$(printf '%s\n' "$seen_dates" | wc -l)" -eq 1 ]
    [ "$seen_dates" != "UNSET" ]
    [[ "$seen_dates" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "commit-stats-snapshot fails loudly when snapshot collection makes no progress" {
    cat > "$TEST_REPO/scripts/snapshot-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "snapshot" >> "${FAKE_GIT_STATE:?}/snapshot.log"
echo "simulated Docker Hub outage" >&2
exit 1
EOF
    chmod +x "$TEST_REPO/scripts/snapshot-stats.sh"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::warning::Stats snapshot collection failed on attempt 1"* ]]
    [[ "$output" == *"::error::Could not persist stats snapshot this run"* ]]

    commits=$(cat "$FAKE_GIT_STATE/commit_count" 2>/dev/null || echo 0)
    [ "$commits" -eq 0 ]

    pushes=$(cat "$FAKE_GIT_STATE/push_count" 2>/dev/null || echo 0)
    [ "$pushes" -eq 0 ]

    # 3 loop attempts, no extra repopulate call (removed — nothing downstream
    # ever consumed it, and it pushed the worst-case runtime too close to the
    # job timeout during a sustained Docker Hub outage).
    snapshots=$(wc -l < "$FAKE_GIT_STATE/snapshot.log")
    [ "$snapshots" -eq 3 ]

    [ ! -e "$FAKE_GIT_STATE/gh_call_count" ]
}

@test "commit-stats-snapshot tolerates a failed follow-up dashboard dispatch after a full success" {
    # The self-dispatch is best-effort: its own failure must not turn an
    # otherwise fully successful, fully persisted run into a failure — only
    # the persistence outcome itself (still_missing) governs the exit code.
    export FAKE_GIT_PUSH_MODE="success_on_retry"
    export FAKE_GH_FAIL="1"

    run bash -c 'cd "$1" && ./scripts/commit-stats-snapshot.sh' _ "$TEST_REPO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::Could not trigger a follow-up dashboard build"* ]]

    gh_calls=$(cat "$FAKE_GIT_STATE/gh_call_count")
    [ "$gh_calls" -eq 1 ]
}

@test "commit-stats-snapshot uses explicit persisted flag, not loop-exit warning shorthand" {
    grep -q 'persisted=false' "$SCRIPTS_DIR/commit-stats-snapshot.sh"
    grep -q '\[\[ "$persisted" != "true" \]\]' "$SCRIPTS_DIR/commit-stats-snapshot.sh"
    ! grep -q 'done[[:space:]]*||' "$SCRIPTS_DIR/commit-stats-snapshot.sh"
}
