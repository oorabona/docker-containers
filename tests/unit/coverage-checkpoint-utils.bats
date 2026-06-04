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

# ---------------------------------------------------------------------------
# ARG_MAX regression tests — large jobs payload (>128 KB) must NOT E2BIG
# ---------------------------------------------------------------------------
#
# Production bug (exit 126): on a build-all run (~237 jobs), gh run view returns
# full job objects with steps/URLs/timestamps.  Passing that JSON via
# `jq --argjson jobs "$jobs_json"` exceeds the kernel per-arg limit
# (MAX_ARG_STRLEN, 128 KB) → E2BIG → bash reports exit 126.
# The fix routes jobs_json via stdin (printf '%s' ... | jq -c) instead.
# These tests verify the fix by constructing a payload that genuinely exceeds
# 128 KB and asserting that extract_failed_recovered succeeds AND returns the
# correct classification — making the test vacuous if the payload is too small.

@test "extract_failed_recovered: large jobs payload (>128KB) succeeds without E2BIG — ARG_MAX regression lock" {
    # Mutation locked: if jobs were passed via `jq --argjson jobs` instead of stdin,
    # this >128KB single argument would trigger E2BIG → exit 126 (the production bug);
    # the test would report status=126 instead of 0 and the classification assertions
    # would never be reached.

    # Build one job object ~400 bytes via name padding so 600 copies exceed 128 KB.
    # Two specific jobs carry meaningful conclusions for the assertion:
    #   - "Build github-runner (ubuntu-2404)" → failure  (maps to github-runner)
    #   - "Build jekyll:4.3.4 (amd64)"       → success  (maps to jekyll)
    # The remaining 598 are synthetic padding jobs with success conclusions and
    # names that do not match any matrix container.
    local pad_job
    pad_job=$(jq -cn '
        {
            name: ("padding-job-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"),
            conclusion: "success"
        }
    ')
    local big
    big=$(jq -cn \
        --argjson real_fail '{"name":"Build github-runner (ubuntu-2404)","conclusion":"failure"}' \
        --argjson real_ok   '{"name":"Build jekyll:4.3.4 (amd64)","conclusion":"success"}' \
        --argjson pad "$pad_job" \
        '{jobs: ([$real_fail, $real_ok] + [range(598) | $pad])}')

    # Guard: verify the fixture actually exceeds 128 KB; if it does not, the test is
    # vacuous (it would pass even with the buggy --argjson path because the payload
    # would fit in the kernel per-arg limit and E2BIG would never fire).
    local big_len="${#big}"
    [ "$big_len" -gt 131072 ] || {
        echo "FIXTURE TOO SMALL: ${big_len} bytes — padding insufficient, fix the test" >&2
        return 1
    }

    local matrix='["github-runner","jekyll"]'
    run extract_failed_recovered "$big" "$matrix"
    [ "$status" -eq 0 ]

    local failed recovered
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    json_eq "$failed"    '["github-runner"]'
    json_eq "$recovered" '["jekyll"]'
}

# ---------------------------------------------------------------------------
# aggregate_build_results — machine-readable artifact attribution (slice 2)
# ---------------------------------------------------------------------------

# Build a minimal results JSON array from pairs of "container:result".
make_results_json() {
    local pairs=("$@")
    local arr="["
    local first=1
    for pair in "${pairs[@]}"; do
        local container="${pair%%:*}"
        local result="${pair##*:}"
        [[ "$first" -eq 0 ]] && arr+=","
        arr+="{\"container\":$(echo -n "$container" | jq -Rs .),\"result\":\"$result\"}"
        first=0
    done
    arr+="]"
    echo "$arr"
}

@test "aggregate_build_results: Proof A — web-shell failure does NOT collide with debian success" {
    # Mutation locked: if attribution used token matching (extract_failed_recovered
    # path), "Build web-shell:debian" failure would falsely attribute to "debian"
    # because "debian" is a token in the job name. With exact container field
    # matching, only the record whose .container=="web-shell" is a failure.
    results=$(make_results_json \
        "web-shell:failure" \
        "debian:success" \
        "postgres:success")
    matrix='["web-shell","debian","postgres"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates | sort')
    json_eq "$failed" '["web-shell"]'
    # "debian" must NOT be in failed_this_run
    [ "$(echo "$failed" | jq 'index("debian")')" = "null" ]
    # "debian" must be in recovered_candidates
    [ "$(echo "$recovered" | jq 'index("debian") != null')" = "true" ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: Proof B — infra job absence keeps unmapped_failure false" {
    # Mutation locked: if infra jobs emitted records, a failed "Sync base images"
    # record with no matching matrix container would set unmapped_failure=true,
    # triggering carry-all of all 13 containers. This test verifies that when
    # NO infra record is present (only container records), unmapped_failure stays
    # false even when github-runner fails.
    results=$(make_results_json \
        "github-runner:failure" \
        "ansible:success" \
        "debian:success" \
        "jekyll:success" \
        "openresty:success" \
        "openvpn:success" \
        "php:success" \
        "postgres:success" \
        "sslh:success" \
        "vector:success" \
        "web-shell:success" \
        "web-shell-debian:success" \
        "wordpress:success")
    matrix='["github-runner","ansible","debian","jekyll","openresty","openvpn","php","postgres","sslh","vector","web-shell","web-shell-debian","wordpress"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    json_eq "$failed" '["github-runner"]'
    # Must NOT carry all 13 — only github-runner is in failed_this_run
    [ "$(echo "$failed" | jq 'length')" = "1" ]
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: Proof C — postgres extension record attributes failure to postgres" {
    # Mutation locked: build-extensions and merge-extension-manifests emit records
    # with container:"postgres". A failure must land postgres in failed_this_run
    # with unmapped_failure=false (it IS in the matrix).
    results=$(make_results_json \
        "postgres:failure" \
        "debian:success")
    matrix='["postgres","debian"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    json_eq "$failed" '["postgres"]'
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: multi-record same container — any failure means failed" {
    # Two records for postgres (amd64 and arm64); one failure → postgres in failed.
    results='[{"container":"postgres","arch":"amd64","result":"failure"},{"container":"postgres","arch":"arm64","result":"success"}]'
    matrix='["postgres","debian"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    json_eq "$failed" '["postgres"]'
    # debian has no records — must be in neither list
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    [ "$(echo "$recovered" | jq 'index("debian")')" = "null" ]
}

@test "aggregate_build_results: all-success container goes to recovered_candidates" {
    results=$(make_results_json "ansible:success" "jekyll:success")
    matrix='["ansible","jekyll","postgres"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    [ "$failed" = "[]" ]
    # ansible and jekyll are recovered; postgres had no records → neither list
    json_eq "$recovered" '["ansible","jekyll"]'
    [ "$(echo "$recovered" | jq 'index("postgres")')" = "null" ]
}

@test "aggregate_build_results: container with zero records is in neither list" {
    # postgres appears in matrix but has no artifact records (skipped build).
    # It must not appear in failed_this_run or recovered_candidates.
    results=$(make_results_json "ansible:success")
    matrix='["ansible","postgres"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    [ "$failed" = "[]" ]
    json_eq "$recovered" '["ansible"]'
    [ "$(echo "$recovered" | jq 'index("postgres")')" = "null" ]
}

@test "aggregate_build_results: out-of-matrix failure sets unmapped_failure true" {
    # A failure record for a container NOT in the matrix (defensive fail-closed).
    results='[{"container":"ghost-container","result":"failure"}]'
    matrix='["ansible","debian"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$unmapped" = "true" ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    [ "$failed" = "[]" ]
}

@test "aggregate_build_results: invalid results_json treated as empty (fail-safe)" {
    run aggregate_build_results "not-json" '["ansible"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$failed" = "[]" ]
    [ "$recovered" = "[]" ]
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: empty results_json returns all-empty (no records = nothing attempted)" {
    run aggregate_build_results '[]' '["ansible","debian","postgres"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$failed" = "[]" ]
    [ "$recovered" = "[]" ]
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: multi-arch missing-record false-recovery lock (COUNT invariant)" {
    # Mutation locked: the arm64 leg crashes before the always() emit step — no failure
    # record is written; only the amd64 success record exists.
    # COUNT invariant: bad_build_job_count=1 ("Build postgres:full (arm64)" matches
    # {postgres}), failure_record_count=0 (no failure records in matrix) →
    # 1 > 0 → unmapped_failure=true. merge_failed_set carries (prior ∪ matrix).
    # failed_this_run is artifact-precise: postgres has no failure record → [] .
    # postgres is NOT in recovered_candidates because it also has unmapped=true
    # (merge_failed_set carry-all prevents it from being dropped from prior).
    # Mutation that this locks: if COUNT gap were ignored, postgres would appear in
    # recovered_candidates (success record only) → merge yields [] → arm64 stranded.
    results='[{"container":"postgres","arch":"amd64","result":"success"}]'
    jobs='{"jobs":[{"name":"Build postgres:full (arm64)","conclusion":"failure"}]}'
    matrix='["postgres","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    # unmapped=true: bad_build_job_count(1) > failure_record_count(0)
    [ "$unmapped" = "true" ]
    # failed_this_run is artifact-precise: no failure records → empty
    [ "$failed" = "[]" ]
    # postgres is in recovered_candidates (has a success record, no failure record)
    # but merge_failed_set's carry-all path (unmapped=true) will carry postgres anyway
    [ "$(echo "$recovered" | jq 'index("postgres") != null')" = "true" ]
}

@test "aggregate_build_results: legit multi-arch recovery passes when no failed jobs" {
    # Complement of the false-recovery test: when both arch legs succeed (no
    # terminal-failed job in jobs_json), the success record should still promote
    # the container to recovered_candidates.
    # COUNT invariant: bad_build_job_count=0 (no bad jobs), failure_record_count=0
    # → 0 > 0 = false, out_of_matrix=false → unmapped=false. Recovery passes.
    results='[{"container":"postgres","arch":"amd64","result":"success"}]'
    jobs='{"jobs":[{"name":"Build postgres:full (amd64)","conclusion":"success"},{"name":"Build postgres:full (arm64)","conclusion":"success"}]}'
    matrix='["postgres","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # postgres should be in recovered_candidates (success record, no failed job)
    [ "$(echo "$recovered" | jq 'index("postgres") != null')" = "true" ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    [ "$(echo "$failed" | jq 'index("postgres")')" = "null" ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: 2-arg backward-compat — no jobs_json means no recovery gate" {
    # Existing tests call aggregate_build_results with 2 args. Without jobs_json,
    # the recovery gate must be a no-op (no bad jobs → gate passes every candidate).
    # This test explicitly verifies the 2-arg form still recovers a success record.
    results=$(make_results_json "ansible:success")
    matrix='["ansible","postgres"]'
    run aggregate_build_results "$results" "$matrix"
    [ "$status" -eq 0 ]
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    json_eq "$recovered" '["ansible"]'
    failed=$(echo "$output" | jq -c '.failed_this_run')
    [ "$failed" = "[]" ]
}

@test "aggregate_build_results: collision prevented — web-shell:debian job does NOT add debian to failed" {
    # The "Build web-shell:debian (alpine)" job token-matches both {web-shell, debian}.
    # COUNT invariant: bad_build_job_count=1 (the job matches ≥1 matrix container),
    # failure_record_count=1 (web-shell has a failure record) → 1 > 1 = false →
    # unmapped=false. failed_this_run is artifact-precise: only web-shell.
    # debian has a success record and no failure record → recovered_candidates.
    # Mutation locked: if COUNT comparison were bad_build_job_count > failure_record_count
    # replaced by e.g. "> 0 regardless", unmapped=true → carry-all → debian not recovered.
    results=$(make_results_json "web-shell:failure" "debian:success")
    jobs='{"jobs":[{"name":"Build web-shell:debian (alpine)","conclusion":"failure"}]}'
    matrix='["web-shell","debian","postgres"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    # Only web-shell has a failure RECORD → artifact-precise
    json_eq "$failed" '["web-shell"]'
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    # bad_build_job_count(1) == failure_record_count(1) → unmapped=false
    [ "$unmapped" = "false" ]
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # debian has a success record, no failure record → IS in recovered_candidates
    [ "$(echo "$recovered" | jq 'index("debian") != null')" = "true" ]
    # postgres has no records at all — neither failed nor recovered
    [ "$(echo "$recovered" | jq 'index("postgres")')" = "null" ]
    [ "$(echo "$failed" | jq 'index("postgres")')" = "null" ]
}

@test "aggregate_build_results: stranding lock — COUNT gap reaches merge_failed_set carry-all" {
    # Locks the full stranding scenario end-to-end: postgres amd64 success record,
    # arm64 terminal-failed (no record). prior=["postgres"].
    # COUNT invariant: bad_build_job_count=1, failure_record_count=0 → unmapped=true.
    # merge_failed_set with unmapped=true carries (prior ∪ matrix) = ["debian","postgres"].
    # Mutation: if COUNT gap were not detected → unmapped=false → merge could drop postgres.
    results='[{"container":"postgres","arch":"amd64","result":"success"}]'
    jobs='{"jobs":[{"name":"Build postgres:full (arm64)","conclusion":"failure"}]}'
    matrix='["postgres","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    ftr=$(echo "$output" | jq -c '.failed_this_run')
    rec=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq -r '.unmapped_failure')
    # unmapped=true: gap detected (1 bad build job, 0 failure records)
    [ "$unmapped" = "true" ]
    # merge_failed_set with prior=["postgres"] and unmapped=true must carry all
    run merge_failed_set '["postgres"]' "$ftr" "$rec" "$matrix" "$unmapped"
    [ "$status" -eq 0 ]
    # carry-all: prior(["postgres"]) ∪ matrix(["postgres","debian"]) = ["debian","postgres"]
    json_eq "$output" '["debian","postgres"]'
}

@test "aggregate_build_results: infra job ignored — unmapped stays false, no spurious container added" {
    # A failed "Sync base images (push scope)" job matches no matrix container.
    # COUNT invariant: bad_build_job_count=0 (infra job matches nothing → not counted),
    # failure_record_count=0 → 0 > 0 = false → unmapped=false. All-13 regression fixed.
    # Mutation locked: if infra jobs were counted in bad_build_job_count (even when
    # matching nothing), count would be 1 > 0 → unmapped=true → all-13 regression.
    results=$(make_results_json "ansible:success" "debian:success" "postgres:success")
    jobs='{"jobs":[{"name":"Sync base images (push scope)","conclusion":"failure"},
                   {"name":"Build ansible (amd64)","conclusion":"success"},
                   {"name":"Build debian (amd64)","conclusion":"success"},
                   {"name":"Build postgres (amd64)","conclusion":"success"}]}'
    matrix='["ansible","debian","postgres"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    # No container should be in failed_this_run (infra job matched nothing)
    [ "$failed" = "[]" ]
    [ "$unmapped" = "false" ]
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # All 3 containers have success records and are not unrepresented → all recovered
    json_eq "$recovered" '["ansible","debian","postgres"]'
}

@test "aggregate_build_results: collision stays dead + debian recovers (COUNT path)" {
    # Reproduction of the codex collision scenario: web-shell has a failure record;
    # debian has a success record; a "Build web-shell:debian (arm64)" job is terminal-
    # failed. Token-match: {web-shell, debian}.
    # COUNT invariant: bad_build_job_count=1 (job matches ≥1 matrix container),
    # failure_record_count=1 (web-shell failure record) → 1 > 1 = false → unmapped=false.
    # failed_this_run is artifact-precise: only web-shell. debian recovers normally.
    # Mutation locked: if bad_build_job_count were counted per matched container (2 for
    # this job) instead of per job (1), count would be 2 > 1 → unmapped=true →
    # debian never recovered.
    results=$(make_results_json "web-shell:failure" "debian:success")
    jobs='{"jobs":[{"name":"Build web-shell:debian (arm64)","conclusion":"failure"}]}'
    matrix='["web-shell","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # web-shell failed via artifact; debian must NOT be in failed_this_run
    json_eq "$failed" '["web-shell"]'
    # debian has a success record and no failure record → IS recovered
    json_eq "$recovered" '["debian"]'
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    # bad_build_job_count(1) == failure_record_count(1) → unmapped=false
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: COUNT-normal — two failures, two bad jobs, unmapped=false" {
    # Complete normal run: github-runner and web-shell each have a failure record;
    # debian has a success record. Two bad build jobs, each matching one container.
    # COUNT invariant: bad_build_job_count=2, failure_record_count=2 → 2 > 2 = false
    # → unmapped=false. failed_this_run is artifact-precise.
    # Mutation locked: off-by-one (> vs >=) would set unmapped=true → carry-all →
    # debian never recovered.
    results=$(make_results_json \
        "github-runner:failure" \
        "web-shell:failure" \
        "debian:success")
    jobs=$(make_jobs_json \
        "Build and push github-runner (ubuntu-2404):failure" \
        "Build and push web-shell (alpine):failure" \
        "Build and push debian (amd64):success")
    matrix='["github-runner","web-shell","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run | sort')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    # Two failure records → two entries in failed_this_run
    json_eq "$failed" '["github-runner","web-shell"]'
    # debian has a success record and no failure record → recovered
    [ "$(echo "$recovered" | jq 'index("debian") != null')" = "true" ]
    # COUNT balanced → unmapped=false
    [ "$unmapped" = "false" ]
}

@test "aggregate_build_results: COUNT-multiarch-crash — amd64 success + arm64 terminal → unmapped=true" {
    # Multi-arch stranding via COUNT: postgres amd64 emits a success record; arm64
    # crashes before emit (no record). Terminal-failed job matches {postgres}.
    # bad_build_job_count=1, failure_record_count=0 → 1 > 0 → unmapped=true.
    # merge_failed_set carry-all: prior(["postgres"]) ∪ matrix(["postgres"]) = ["postgres"].
    # Mutation locked: if COUNT gap not detected → unmapped=false → postgres in
    # recovered_candidates → merge yields [] → arm64 stranded forever.
    results='[{"container":"postgres","arch":"amd64","result":"success"}]'
    jobs='{"jobs":[{"name":"Build postgres:full (arm64)","conclusion":"failure"}]}'
    matrix='["postgres"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # COUNT gap → unmapped=true
    [ "$unmapped" = "true" ]
    # failed_this_run artifact-precise: no failure record → empty
    [ "$failed" = "[]" ]
    # merge_failed_set carry-all carries prior ∪ matrix
    run merge_failed_set '["postgres"]' "$failed" "$recovered" "$matrix" "$unmapped"
    [ "$status" -eq 0 ]
    json_eq "$output" '["postgres"]'
}

@test "aggregate_build_results: COUNT-collision-crash — codex adversarial edge → unmapped=true" {
    # Codex adversarial edge: debian has a failure record; web-shell has a success
    # record; "Build web-shell:debian (arm64)" is terminal-failed, matching {web-shell,debian}.
    # A SECOND unrelated bad job "Build web-shell (amd64)" also matches {web-shell}.
    # bad_build_job_count=2 (two jobs each match ≥1 matrix container),
    # failure_record_count=1 (only debian failure record) → 2 > 1 → unmapped=true.
    # web-shell is NOT in recovered_candidates even though it has a success record,
    # because merge_failed_set carry-all overrides everything.
    # Mutation locked: if COUNT gap were ignored → unmapped=false → web-shell appears
    # in recovered_candidates → a crashed web-shell build is silently dropped.
    results=$(make_results_json "debian:failure" "web-shell:success")
    jobs='{"jobs":[
        {"name":"Build web-shell:debian (arm64)","conclusion":"failure"},
        {"name":"Build web-shell (amd64)","conclusion":"failure"}
    ]}'
    matrix='["web-shell","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    failed=$(echo "$output" | jq -c '.failed_this_run')
    # COUNT gap: 2 bad build jobs > 1 failure record → unmapped=true
    [ "$unmapped" = "true" ]
    # failed_this_run is artifact-precise: only debian has a failure record
    json_eq "$failed" '["debian"]'
    # merge_failed_set carry-all: prior ∪ matrix carries everything
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    run merge_failed_set '["web-shell","debian"]' "$failed" "$recovered" "$matrix" "$unmapped"
    [ "$status" -eq 0 ]
    json_eq "$output" '["debian","web-shell"]'
}

@test "aggregate_build_results: COUNT-infra-ignored — infra failure + all-success records → unmapped=false" {
    # Infrastructure failure with all containers succeeding:
    # "Sync base images" fails but matches no matrix container → bad_build_job_count=0.
    # All containers have success records → failure_record_count=0.
    # 0 > 0 = false, out_of_matrix=false → unmapped=false.
    # All containers recover normally — the all-13 regression is definitively blocked.
    # Mutation locked: if infra jobs were included in bad_build_job_count regardless of
    # matrix match, count=1 > 0 → unmapped=true → all containers carried forward forever.
    results=$(make_results_json \
        "ansible:success" \
        "debian:success" \
        "postgres:success" \
        "web-shell:success")
    jobs='{"jobs":[
        {"name":"Sync base images (push scope)","conclusion":"failure"},
        {"name":"Build ansible (amd64)","conclusion":"success"},
        {"name":"Build debian (amd64)","conclusion":"success"},
        {"name":"Build postgres (amd64)","conclusion":"success"},
        {"name":"Build web-shell (alpine)","conclusion":"success"}
    ]}'
    matrix='["ansible","debian","postgres","web-shell"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates | sort')
    # infra job not counted → unmapped=false
    [ "$unmapped" = "false" ]
    [ "$failed" = "[]" ]
    # all 4 containers recover
    json_eq "$recovered" '["ansible","debian","postgres","web-shell"]'
}

@test "aggregate_build_results: crashed PostgreSQL Extensions job triggers unmapped (alias lock)" {
    # Locks the postgres extension-pipeline alias in maps_to_container.
    # Scenario: build-and-push succeeded (record: postgres success); "Build PostgreSQL
    # Extensions (arm64)" crashed before its always() emit → no extension failure record.
    # The job name contains no lowercase "postgres" token, so without the alias it would
    # NOT be counted → bad_build_job_count=0, failure_record_count=0 → 0>0=false →
    # unmapped=false → postgres falsely recovered → arm64 extension retried never.
    # With alias: maps_to_container("Build PostgreSQL Extensions (arm64)"; "postgres")=true
    # → bad_build_job_count=1, failure_record_count=0 → 1>0=true → unmapped=true →
    # merge_failed_set carries postgres forward.
    # Mutation locked: removing the alias from maps_to_container → bad_build_job_count=0
    # → unmapped=false → postgres wrongly recovered.
    results='[{"container":"postgres","variant":"vector","result":"success"}]'
    jobs='{"jobs":[{"name":"Build PostgreSQL Extensions (arm64)","conclusion":"failure"}]}'
    matrix='["postgres","debian"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # alias counts the crashed ext job → 1 bad build job > 0 failure records → unmapped=true
    [ "$unmapped" = "true" ]
    # failed_this_run is artifact-precise: no failure records → empty
    [ "$failed" = "[]" ]
    # postgres is in recovered (success record, no failure record) but merge will carry-all
    [ "$(echo "$recovered" | jq 'index("postgres") != null')" = "true" ]
    # merge_failed_set carry-all: prior ∪ matrix keeps postgres in the retry set
    run merge_failed_set '["postgres"]' "$failed" "$recovered" "$matrix" "$unmapped"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'index("postgres") != null')" = "true" ]
}

@test "aggregate_build_results: crashed Merge Extension Manifests job triggers unmapped (alias lock)" {
    # Same shape as the Extension job test but with "Merge Extension Manifests (multi-arch)".
    # Both display names must be covered by the alias regex "PostgreSQL Extensions|Extension Manifests".
    # Mutation locked: if the alias regex omitted "Extension Manifests", this job would go
    # uncounted → bad_build_job_count=0 → unmapped=false → postgres falsely recovered.
    results='[{"container":"postgres","variant":"full","result":"success"}]'
    jobs='{"jobs":[{"name":"Merge Extension Manifests (multi-arch)","conclusion":"timed_out"}]}'
    matrix='["postgres","web-shell"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    failed=$(echo "$output" | jq -c '.failed_this_run')
    # alias counts the merge job → 1 bad build job > 0 failure records → unmapped=true
    [ "$unmapped" = "true" ]
    [ "$failed" = "[]" ]
    # carry-all keeps postgres in retry set
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    run merge_failed_set '["postgres"]' "$failed" "$recovered" "$matrix" "$unmapped"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'index("postgres") != null')" = "true" ]
}

@test "aggregate_build_results: succeeded PostgreSQL Extensions job is NOT counted — no spurious unmapped" {
    # Negative: when the extension job SUCCEEDS it must not increment bad_build_job_count.
    # All jobs success, all records success → bad_build_job_count=0, failure_record_count=0
    # → unmapped=false → postgres recovers normally.
    # Mutation locked: if successful extension jobs were included in bad_build_job_count
    # (e.g. by counting all extension jobs regardless of conclusion), count=1 > 0 →
    # unmapped=true → postgres carried forward on every green run → never cleared.
    results='[{"container":"postgres","variant":"full","result":"success"}]'
    jobs='{"jobs":[
        {"name":"Build PostgreSQL Extensions (amd64)","conclusion":"success"},
        {"name":"Build PostgreSQL Extensions (arm64)","conclusion":"success"},
        {"name":"Merge Extension Manifests (multi-arch)","conclusion":"success"}
    ]}'
    matrix='["postgres"]'
    run aggregate_build_results "$results" "$matrix" "$jobs"
    [ "$status" -eq 0 ]
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    # No bad jobs → unmapped=false
    [ "$unmapped" = "false" ]
    [ "$failed" = "[]" ]
    # postgres has a success record → recovered normally
    [ "$(echo "$recovered" | jq 'index("postgres") != null')" = "true" ]
}

@test "aggregate_build_results: zero-artifact glob payload degrades safely (FIX-1 regression lock)" {
    # Mutation locked: before FIX-1, a failed gh run download left the bres/ dir
    # empty; the glob "$RUNNER_TEMP/bres/*/*.json" did NOT expand (nullglob off) so
    # jq received the literal un-expanded path string, producing the two-document
    # stream "[]\n[]" (one [] per path segment parsed as empty). That string is
    # non-empty and != "[]", so the PRIMARY branch was taken with effectively empty
    # data — all failures silently dropped. This test feeds the exact malformed
    # string to aggregate_build_results and asserts safe degradation: the helper
    # must return exit 0 with all-empty classification (fromjson? handles it).
    # In production FIX-1 prevents this string from ever reaching the helper by
    # using find+mapfile to count files before calling jq.
    malformed=$'[]\n[]'
    run aggregate_build_results "$malformed" '["postgres","web-shell"]'
    [ "$status" -eq 0 ]
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    unmapped=$(echo "$output" | jq '.unmapped_failure')
    [ "$failed" = "[]" ]
    [ "$recovered" = "[]" ]
    [ "$unmapped" = "false" ]
}

@test "extract_failed_recovered: bare-array form of large payload (>128KB) succeeds — stdin normalisation" {
    # Same as the previous test but the payload is a bare JSON array [...] rather than
    # {"jobs":[...]}.  Verifies that the stdin-path normalisation
    # (`. | if type == "object" then .jobs // [] else . end`) handles both forms
    # even at scale.
    local pad_job
    pad_job=$(jq -cn '
        {
            name: ("padding-job-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"),
            conclusion: "success"
        }
    ')
    local big_bare
    big_bare=$(jq -cn \
        --argjson real_fail '{"name":"Build github-runner (ubuntu-2404)","conclusion":"failure"}' \
        --argjson real_ok   '{"name":"Build jekyll:4.3.4 (amd64)","conclusion":"success"}' \
        --argjson pad "$pad_job" \
        '[$real_fail, $real_ok] + [range(598) | $pad]')

    local big_len="${#big_bare}"
    [ "$big_len" -gt 131072 ] || {
        echo "FIXTURE TOO SMALL: ${big_len} bytes — padding insufficient, fix the test" >&2
        return 1
    }

    local matrix='["github-runner","jekyll"]'
    run extract_failed_recovered "$big_bare" "$matrix"
    [ "$status" -eq 0 ]

    local failed recovered
    failed=$(echo "$output" | jq -c '.failed_this_run')
    recovered=$(echo "$output" | jq -c '.recovered_candidates')
    json_eq "$failed"    '["github-runner"]'
    json_eq "$recovered" '["jekyll"]'
}
