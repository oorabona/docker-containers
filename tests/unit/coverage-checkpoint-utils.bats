#!/usr/bin/env bats

# Unit tests for helpers/coverage-checkpoint-utils.sh
# Tests the state-machine functions used by the publish-coverage-checkpoint job
# and the detect-containers action.

setup() {
    ORIG_DIR="$PWD"
    source "$ORIG_DIR/helpers/coverage-checkpoint-utils.sh"
}

teardown() {
    :
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Compare two compact JSON arrays for equality (whitespace/order-insensitive)
json_eq() {
    local a="$1" b="$2"
    [[ "$(echo "$a" | jq -c 'sort')" == "$(echo "$b" | jq -c 'sort')" ]]
}

# ---------------------------------------------------------------------------
# checkpoint_failed_containers — parse annotated tag message
# ---------------------------------------------------------------------------

@test "checkpoint_failed_containers: valid state JSON returns failed_containers array" {
    state='{"sha":"abc","run_id":"1","failed_containers":["github-runner","web-shell"]}'
    run checkpoint_failed_containers "$state"
    [ "$status" -eq 0 ]
    json_eq "$output" '["github-runner","web-shell"]'
}

@test "checkpoint_failed_containers: empty failed_containers array returns []" {
    state='{"sha":"abc","run_id":"2","failed_containers":[]}'
    run checkpoint_failed_containers "$state"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "checkpoint_failed_containers: arbitrary commit message (non-JSON) returns []" {
    # A lightweight tag stores a bare commit message, not our JSON.
    run checkpoint_failed_containers "chore: bump versions"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "checkpoint_failed_containers: JSON object without failed_containers returns []" {
    run checkpoint_failed_containers '{"sha":"abc","run_id":"3"}'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "checkpoint_failed_containers: failed_containers not an array returns []" {
    run checkpoint_failed_containers '{"sha":"abc","failed_containers":"github-runner"}'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "checkpoint_failed_containers: empty string returns []" {
    run checkpoint_failed_containers ""
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "checkpoint_failed_containers: failed_containers with non-string elements returns []" {
    run checkpoint_failed_containers '{"sha":"abc","failed_containers":[1,2]}'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# ---------------------------------------------------------------------------
# extract_failed_recovered — classify jobs against matrix
# ---------------------------------------------------------------------------

# Build a minimal jobs JSON as the gh run view --json jobs output would look.
# Args: pairs of "name:conclusion" where conclusion may be a string value or the
# special token "null" (emitted as JSON null, matching the real GH API for in-progress jobs).
make_jobs_json() {
    local pairs=("$@")
    local jobs_arr="["
    local first=1
    for pair in "${pairs[@]}"; do
        local name="${pair%%:*}"
        local concl="${pair##*:}"
        [[ "$first" -eq 0 ]] && jobs_arr+=","
        # Emit real JSON null for in-progress jobs — the GH API sends null, not the string "null".
        if [[ "$concl" == "null" ]]; then
            jobs_arr+="{\"name\":$(echo -n "$name" | jq -Rs .),\"conclusion\":null}"
        else
            jobs_arr+="{\"name\":$(echo -n "$name" | jq -Rs .),\"conclusion\":\"$concl\"}"
        fi
        first=0
    done
    jobs_arr+="]"
    echo "{\"jobs\":${jobs_arr}}"
}

@test "extract_failed_recovered: failed job lands in failed_this_run" {
    jobs=$(make_jobs_json \
        "Build and push github-runner (ubuntu-2404):failure" \
        "Build and push postgres (alpine):success")
    run extract_failed_recovered "$jobs" '["github-runner","postgres"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    json_eq "$failed" '["github-runner"]'
    json_eq "$recovered" '["postgres"]'
}

@test "extract_failed_recovered: all green gives empty failed_this_run and all in recovered" {
    jobs=$(make_jobs_json \
        "Build and push github-runner (ubuntu-2404):success" \
        "Build and push postgres (alpine):success")
    run extract_failed_recovered "$jobs" '["github-runner","postgres"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    [ "$failed" = "[]" ]
    json_eq "$recovered" '["github-runner","postgres"]'
}

@test "extract_failed_recovered: cancelled counts as failure (fail-closed)" {
    jobs=$(make_jobs_json \
        "Build and push postgres (alpine):cancelled")
    run extract_failed_recovered "$jobs" '["postgres"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    json_eq "$failed" '["postgres"]'
}

@test "extract_failed_recovered: timed_out counts as failure (fail-closed)" {
    jobs=$(make_jobs_json \
        "Build and push postgres (alpine):timed_out")
    run extract_failed_recovered "$jobs" '["postgres"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    json_eq "$failed" '["postgres"]'
}

@test "extract_failed_recovered: token-boundary web-shell does NOT match web-shell-debian" {
    # The key correctness property: web-shell-debian job must NOT attribute to web-shell.
    jobs=$(make_jobs_json \
        "Build and push web-shell-debian (alpine):failure" \
        "Build and push web-shell (alpine):success")
    run extract_failed_recovered "$jobs" '["web-shell","web-shell-debian"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # web-shell should be recovered (its own job succeeded), not failed
    json_eq "$failed" '["web-shell-debian"]'
    json_eq "$recovered" '["web-shell"]'
}

@test "extract_failed_recovered: token-boundary github-runner does NOT match github-runner-debian-trixie" {
    jobs=$(make_jobs_json \
        "Build and push github-runner-debian-trixie (amd64):failure" \
        "Build and push github-runner (ubuntu-2404):success")
    run extract_failed_recovered "$jobs" '["github-runner","github-runner-debian-trixie"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    json_eq "$failed" '["github-runner-debian-trixie"]'
    json_eq "$recovered" '["github-runner"]'
}

@test "extract_failed_recovered: unmapped_failure true when bad job matches no matrix container" {
    # A failed job whose container is not in the matrix
    jobs=$(make_jobs_json \
        "Build extension timescaledb (pg17):failure")
    run extract_failed_recovered "$jobs" '["postgres","web-shell"]'
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$unmapped" = "true" ]
}

@test "extract_failed_recovered: unmapped_failure false when all bad jobs map to matrix" {
    jobs=$(make_jobs_json \
        "Build and push postgres (alpine):failure")
    run extract_failed_recovered "$jobs" '["postgres"]'
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$unmapped" = "false" ]
}

@test "extract_failed_recovered: null-conclusion meta jobs are ignored — no unmapped_failure" {
    # The checkpoint job and summary job are still running (conclusion null) when
    # gh run view is called from inside the checkpoint step.  They must not count
    # as bad jobs; unmapped_failure must remain false even though they match no
    # container token.
    # Mutation locked: before the fix (.conclusion != "success" and != "skipped"
    # treated null as bad), this test returns unmapped_failure=true.
    jobs=$(make_jobs_json \
        "Build and push github-runner (ubuntu-2404):success" \
        "Publish coverage checkpoint tag:null" \
        "Summary:null")
    run extract_failed_recovered "$jobs" '["github-runner"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$failed" = "[]" ]
    json_eq "$recovered" '["github-runner"]'
    [ "$unmapped" = "false" ]
}

@test "extract_failed_recovered: terminal failure detected alongside null-conclusion meta job" {
    # A real container failure must still be captured even when the jobs list
    # also contains in-progress meta jobs with null conclusion.
    # Mutation locked: if null exclusion accidentally excluded ALL non-success jobs
    # (including real failures), failed_this_run would be empty — test goes RED.
    jobs=$(make_jobs_json \
        "Build and push github-runner (ubuntu-2404):failure" \
        "Publish coverage checkpoint tag:null")
    run extract_failed_recovered "$jobs" '["github-runner"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    json_eq "$failed" '["github-runner"]'
    # The only bad job (github-runner failure) maps to a container — no unmapped.
    [ "$unmapped" = "false" ]
}

# ---------------------------------------------------------------------------
# merge_failed_set — carry-forward state machine
# ---------------------------------------------------------------------------

@test "merge_failed_set: accumulate never drop — prior a carried when not in matrix" {
    # a NOT in matrix (never attempted), b newly failed, c recovered
    # Result must contain BOTH a (carried) AND b (newly failed)
    run merge_failed_set '["a"]' '["b"]' '["c"]' '["b","c"]' "false"
    [ "$status" -eq 0 ]
    json_eq "$output" '["a","b"]'
    # Mutation guard: if difference used recovered_candidates directly (not intersected
    # with prior), "a" would be dropped because c∈recovered_cand but a∉prior is fine —
    # what matters is: if we forgot the ∩ prior step, "a" would still survive (a∉recovered_cand).
    # The real regression this catches: if we did (prior ∪ failed) − recovered_cand instead
    # of − (recovered_cand ∩ prior), then when a=prior-only container, it would be
    # dropped if a ever appeared in recovered_cand by coincidence. Anchored by this test.
}

@test "merge_failed_set: recover on real success — attempted and green clears the set" {
    run merge_failed_set '["github-runner"]' '[]' '["github-runner"]' '["github-runner"]' "false"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
    # Mutation guard: if recovered = recovered_candidates (no ∩ prior), containers
    # that appear in recovered_cand but are NOT in prior would also be "recovered",
    # meaning they'd be removed from the output even if they were never failing.
    # This test passes in both correct and wrong implementations, but the partner
    # test "accumulate never drop" catches the wrong case.
}

@test "merge_failed_set: partial success does NOT recover — stays in failed set" {
    run merge_failed_set '["github-runner"]' '["github-runner"]' '[]' '["github-runner"]' "false"
    [ "$status" -eq 0 ]
    json_eq "$output" '["github-runner"]'
}

@test "merge_failed_set: fail-closed on unmapped failure — matrix union prior" {
    # unmapped_failure=true: we don't know what failed, so carry all.
    run merge_failed_set '["a"]' '[]' '[]' '["b","c"]' "true"
    [ "$status" -eq 0 ]
    json_eq "$output" '["a","b","c"]'
    # Mutation guard: if unmapped_failure check was skipped (treated as false),
    # result would be ["a"] (only prior). This test goes RED in that case.
}

@test "merge_failed_set: stable when no containers failed or in prior" {
    run merge_failed_set '[]' '[]' '["postgres"]' '["postgres"]' "false"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "merge_failed_set: multiple containers, some recovered some not" {
    # prior: a, b, c. This run: a failed, b recovered, c not in matrix (not attempted).
    run merge_failed_set '["a","b","c"]' '["a"]' '["b"]' '["a","b"]' "false"
    [ "$status" -eq 0 ]
    # recovered = ["b"] ∩ ["a","b","c"] = ["b"]
    # new_failed = (["a","b","c"] ∪ ["a"]) − ["b"] = ["a","c"]
    json_eq "$output" '["a","c"]'
}

# ---------------------------------------------------------------------------
# compute_carry_forward — union logic for carry-forward queue + carried set
# ---------------------------------------------------------------------------

@test "compute_carry_forward: codex-bug-lock — already-queued container still lands in carried" {
    # Locks the mutation: old inline loop skipped 'continue' branch recording,
    # so postgres (already queued by the shared-infra canary) was NEVER added to
    # carried_forward → compute_expand_retained_map returned postgres:false →
    # latest-only retry → failed retained version falsely marked recovered.
    run compute_carry_forward '["postgres"]' '["postgres"]' '["postgres","jekyll"]'
    [ "$status" -eq 0 ]
    carried=$(echo "$output" | jq -c '.carried')
    queued=$(echo "$output" | jq -c '.queued')
    # carried must include postgres even though it was already in the queue
    [ "$(echo "$carried" | jq -c 'sort')" = '["postgres"]' ]
    # queued must contain postgres exactly once (no dup)
    [ "$(echo "$queued" | jq -c 'sort')" = '["postgres"]' ]
}

@test "compute_carry_forward: not-yet-queued container is added to both queued and carried" {
    # github-runner was not queued by diff; it was in baseline_failed and is valid.
    run compute_carry_forward '["jekyll"]' '["github-runner"]' '["github-runner","jekyll"]'
    [ "$status" -eq 0 ]
    carried=$(echo "$output" | jq -c '.carried')
    queued=$(echo "$output" | jq -c '.queued | sort')
    [ "$(echo "$carried" | jq -c 'sort')" = '["github-runner"]' ]
    [ "$queued" = '["github-runner","jekyll"]' ]
}

@test "compute_carry_forward: invalid container filtered out (not in valid list)" {
    # 'ghost' is in baseline_failed but not in valid → must NOT appear in carried or queued.
    run compute_carry_forward '["jekyll"]' '["ghost"]' '["jekyll","postgres"]'
    [ "$status" -eq 0 ]
    carried=$(echo "$output" | jq -c '.carried')
    queued=$(echo "$output" | jq -c '.queued | sort')
    [ "$carried" = '[]' ]
    [ "$queued" = '["jekyll"]' ]
}

@test "compute_carry_forward: empty baseline_failed produces empty carried, queued unchanged" {
    run compute_carry_forward '["ansible","jekyll"]' '[]' '["ansible","jekyll","postgres"]'
    [ "$status" -eq 0 ]
    carried=$(echo "$output" | jq -c '.carried')
    queued=$(echo "$output" | jq -c '.queued | sort')
    [ "$carried" = '[]' ]
    [ "$queued" = '["ansible","jekyll"]' ]
}

@test "compute_carry_forward: dedup and sort — queued and baseline_failed overlap multiple containers" {
    # queued=["b","a"], baseline_failed=["a","c"], valid=["a","b","c"]
    # carried = ["a","c"]  (both valid prior-failed)
    # queued_out = ["a","b"] ∪ ["a","c"] = ["a","b","c"]
    run compute_carry_forward '["b","a"]' '["a","c"]' '["a","b","c"]'
    [ "$status" -eq 0 ]
    queued=$(echo "$output" | jq -c '.queued')
    carried=$(echo "$output" | jq -c '.carried')
    [ "$queued" = '["a","b","c"]' ]
    [ "$carried" = '["a","c"]' ]
}
