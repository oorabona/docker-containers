#!/usr/bin/env bash
# Coverage checkpoint utilities for docker-containers CI
#
# Provides state management for the annotated coverage-checkpoint tag
# (auto-build-coverage-master).  The tag carries a JSON record of which
# containers failed in the last master push so the next run can retry them
# even when other containers did not change.
#
# Requires: jq
#
# Functions (all pure — read args/stdin, write stdout only):
#   checkpoint_failed_containers  <state_str>
#   aggregate_build_results       <results_json> <matrix_json> [jobs_json]  ← PRIMARY attribution (slice 2)
#   extract_failed_recovered      <jobs_json> <matrix_json>      ← FALLBACK (name-matching)
#   merge_failed_set              <prior_json> <failed_this_json> <recovered_cand_json> <matrix_json> <unmapped_failure>
#   compute_carry_forward         <queued_json> <baseline_failed_json> <valid_json>

# checkpoint_failed_containers <state_str>
#
# Parse the annotated tag message (which is a JSON state record) and return
# the .failed_containers array.  Returns [] on any parse/validation failure
# so the caller can always treat the result as a JSON array of strings.
#
# Output: compact JSON array of container names (may be empty: [])
checkpoint_failed_containers() {
    local state_str="${1:-}"

    # Use fromjson? so non-JSON input silently becomes null → falls to [].
    # The // null guard converts empty-stream (parse failure) to null before
    # the as-binding, ensuring the if-else always has a value to test.
    # Validate: must be an object whose .failed_containers is an array of strings.
    jq -cn --arg s "$state_str" \
        '(($s | fromjson?) // null) as $o |
         if ($o | type) == "object"
            and ($o.failed_containers | type) == "array"
            and ([$o.failed_containers[] | type] | all(. == "string"))
         then $o.failed_containers
         else []
         end'
}

# extract_failed_recovered <jobs_json> <matrix_json>
#
# Given the JSON from `gh run view --json jobs` and the JSON array of container
# names attempted this run, classify each matrix container as failed, recovered,
# or neither (never attempted).
#
# Job-to-container matching: job name contains container name as a full token
# bounded by non-identifier characters so that "web-shell" does NOT match
# "web-shell-debian", and "github-runner" does NOT match "github-runner-debian-trixie".
# Token boundary regex: (^|[^A-Za-z0-9_-]) + name + ([^A-Za-z0-9_-]|$)
#
# A job is "bad" iff it has a TERMINAL non-success conclusion.
# In-progress jobs (conclusion null or "") are ignored — at checkpoint runtime
# the checkpoint job itself and the summary job are still running, so their
# null conclusion must not trigger unmapped_failure and poison every run.
# Container build jobs are all terminal by the time the checkpoint job runs
# (they are declared as `needs`), so null-exclusion never hides a real failure.
# Terminal non-success set: failure, cancelled, timed_out, neutral, action_required, stale.
#
# Output compact JSON:
#   { "failed_this_run": [...], "recovered_candidates": [...], "unmapped_failure": bool }
extract_failed_recovered() {
    # Avoid ${var:-{...}} default syntax: bash appends a spurious } to non-empty
    # args that contain } themselves (brace-expansion edge case in param expansion).
    local jobs_json="${1}"
    local matrix_json="${2}"
    [[ -z "$jobs_json" ]] && jobs_json='{"jobs":[]}'
    [[ -z "$matrix_json" ]] && matrix_json='[]'

    printf '%s' "$jobs_json" | jq -c \
        --argjson matrix "$matrix_json" \
        '
        # Normalise: accept both {"jobs":[...]} and a bare array. Jobs JSON arrives
        # on stdin (NOT --argjson) because a build-all run produces a jobs payload
        # larger than the kernel per-arg limit (MAX_ARG_STRLEN, 128 KB) → E2BIG.
        (. | if type == "object" then .jobs // [] else . end) as $job_list |

        # Identify bad jobs: terminal conclusion that is not success or skipped.
        # null/"" conclusions mean in-progress — excluded so meta-jobs running
        # alongside the checkpoint (e.g. summary) never trigger unmapped_failure.
        ($job_list | map(select(
            .conclusion != null and .conclusion != "" and
            .conclusion != "success" and .conclusion != "skipped"
        ))) as $bad_jobs |

        # Build token-boundary regex for a container name.
        # Container names are [a-z0-9-]+ so safe to interpolate directly.
        def token_re(name):
            "(^|[^A-Za-z0-9_-])" + name + "([^A-Za-z0-9_-]|$)";

        # For each matrix container, collect matching jobs from the full list.
        def matching_jobs(c):
            $job_list | map(select(.name | test(token_re(c))));

        # For each matrix container, collect bad matching jobs.
        def bad_matching_jobs(c):
            $bad_jobs | map(select(.name | test(token_re(c))));

        # failed_this_run: matrix containers with >=1 bad matching job.
        [ $matrix[] | . as $c |
          if (bad_matching_jobs($c) | length) > 0 then $c else empty end
        ] | sort | unique as $failed |

        # recovered_candidates: matrix containers with >=1 matching job AND 0 bad.
        [ $matrix[] | . as $c |
          if (matching_jobs($c) | length) > 0
             and (bad_matching_jobs($c) | length) == 0
          then $c else empty end
        ] | sort | unique as $recovered |

        # unmapped_failure: any bad job that matches no matrix container.
        ($bad_jobs | map(.name) | map(. as $jname |
            if ($matrix | map(. as $c | $jname | test(token_re($c))) | any) | not
            then true else false end
        ) | any) as $unmapped |

        {
            failed_this_run: $failed,
            recovered_candidates: $recovered,
            unmapped_failure: $unmapped
        }
        '
}

# compute_carry_forward <queued_json> <baseline_failed_json> <valid_json>
#
# Merge prior-failed containers into the build queue AND compute the carried-forward
# set that must force retained-version expansion. A prior-failed container must be
# carried (expand=true) even if it was already queued by another path (diff, or the
# shared-infra canary), otherwise a latest-only retry can falsely "recover" a failed
# retained version.
#
#   carried = baseline_failed ∩ valid          (every valid prior-failed container)
#   queued' = queued ∪ carried                 (full build list, deduped)
#
# All inputs/outputs are JSON arrays of strings; output is compact JSON:
#   {"queued":[...sorted unique...], "carried":[...sorted unique...]}
#
# Invalid (non-array) inputs are silently treated as [] so the caller never
# needs to guard against parse errors.
compute_carry_forward() {
    local queued_json="${1:-[]}"
    local baseline_failed_json="${2:-[]}"
    local valid_json="${3:-[]}"

    jq -cn \
        --argjson queued "$queued_json" \
        --argjson baseline_failed "$baseline_failed_json" \
        --argjson valid "$valid_json" \
        '
        # Treat any non-array input as [] so the function never hard-fails on
        # malformed data — mirrors the fail-safe style of the other helpers.
        (if ($queued | type) == "array" then $queued else [] end) as $q |
        (if ($baseline_failed | type) == "array" then $baseline_failed else [] end) as $bf |
        (if ($valid | type) == "array" then $valid else [] end) as $v |

        # carried = baseline_failed ∩ valid (all valid prior-failed containers,
        # regardless of whether they are already in the queued list).
        [ $bf[] | . as $x | if ($v | index($x)) != null then $x else empty end ]
        | sort | unique as $carried |

        # queued_out = queued ∪ carried (deduped, sorted)
        (($q + $carried) | sort | unique) as $queued_out |

        { queued: $queued_out, carried: $carried }
        '
}

# aggregate_build_results <results_json> <matrix_json> [jobs_json]
#
# Classify per-matrix containers as failed, recovered, or neither using
# machine-readable build-result artifact records.  jobs_json is used to
# detect completeness gaps via a COUNT-based invariant.
#
# This is the PRIMARY attribution path (slice 2).  It eliminates three bugs:
#   1. Token-collision false positives (e.g. "debian" job matching "web-shell:debian").
#   2. Infra job failures (e.g. "Sync base images") triggering carry-all via
#      unmapped_failure because the job name matched no container token.
#   3. Multi-arch / extension-pipeline stranding: a crashed leg or postgres extension
#      job produces no record; a success record from another leg/job alone would
#      falsely recover a prior failure → crashed leg/pipeline never retried.
#
# Arguments:
#   results_json  – JSON array of objects, each with at least {container, result}
#                   where result ∈ "success" | "failure".  Other fields are ignored.
#                   Invalid / non-array input is treated as [] (fail-safe).
#   matrix_json   – JSON array of container name strings (same format as
#                   extract_failed_recovered's second argument).
#   jobs_json     – (optional) slimmed gh run view output: {jobs:[{name,conclusion}]}
#                   or a bare array.  Used only for the COUNT completeness invariant:
#                   bad_build_job_count vs failure_record_count.  Infra jobs (matching
#                   no matrix container) are NOT counted — no all-13 regression.
#                   If omitted/empty → counts are both 0 → unmapped stays false
#                   (backward-compat for 2-arg callers).
#
# Core algorithm (COUNT-based completeness invariant):
#   fail_rec              = matrix containers with ≥1 record where .result=="failure"
#   succ_rec              = matrix containers with ≥1 record where .result=="success"
#   failure_record_count  = number of records with .result=="failure" AND .container ∈ matrix
#   bad_jobs              = jobs_json jobs with terminal conclusion (not null/""/success/skipped)
#   bad_build_job_count   = number of bad_jobs that map to ≥1 matrix container via
#                           maps_to_container (token-match OR postgres ext/merge alias)
#                           (counted once per job; infra jobs matching nothing → not counted)
#   unmapped_failure      = (bad_build_job_count > failure_record_count)  — gap detected
#                           OR (out-of-matrix failure record exists)       — always fail-closed
#   failed_this_run       = fail_rec  (artifact-precise)
#   recovered_candidates  = succ_rec \ fail_rec
#
# When unmapped_failure=true, merge_failed_set carries (prior ∪ matrix) so no
# container is silently dropped despite incomplete artifact data.
#
# Output compact JSON (same shape as extract_failed_recovered):
#   {
#     "failed_this_run":      [...],   # containers with ≥1 failure record
#     "recovered_candidates": [...],   # success-only containers
#     "unmapped_failure":     bool     # true → gap or out-of-matrix record detected
#   }
# All arrays are sorted and unique.  A container with no records appears in neither list.
#
# Note: results_json and jobs_json are passed via --arg + fromjson? (not --argjson)
# so that malformed JSON is silently treated as [] rather than causing a jq parse error.
# Records are slim (one per build job, ~158 max, <128 KB total) — no ARG_MAX risk.
aggregate_build_results() {
    local results_json="${1:-}"
    local matrix_json="${2:-[]}"
    local jobs_json="${3:-}"
    [[ -z "$results_json" ]] && results_json='[]'
    [[ -z "$jobs_json" ]]    && jobs_json='{"jobs":[]}'

    # Build the bake-managed JSON array for the alias in maps_to_container.
    # Run bake-managed.sh in a subshell to avoid inheriting its set -euo pipefail;
    # fall back to an empty array if it cannot be executed (alias won't fire — no
    # regression on callers that don't have the bake pipeline deployed yet).
    local _bm_script_dir
    _bm_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _bm_script_dir=""
    local bake_managed_json='[]'
    if [[ -n "$_bm_script_dir" && -r "$_bm_script_dir/bake-managed.sh" ]]; then
        # Run in a subshell: source + call bake_managed_containers; convert
        # space-separated output to a compact JSON array.  Any failure → [].
        # shellcheck disable=SC1091
        bake_managed_json="$(
            source "$_bm_script_dir/bake-managed.sh" 2>/dev/null &&
            bake_managed_containers | jq -Rc 'split(" ") | map(select(length>0))'
        )" 2>/dev/null || bake_managed_json='[]'
    fi

    jq -cn \
        --arg results_str "$results_json" \
        --argjson matrix "$matrix_json" \
        --arg jobs_str "$jobs_json" \
        --argjson bake_managed "$bake_managed_json" \
        '
        # Parse results_str; treat any non-array (or parse failure) as [] (fail-safe).
        # fromjson? silently becomes empty on invalid JSON; // [] recovers to empty array.
        (($results_str | fromjson?) // []) as $raw_results |
        (if ($raw_results | type) == "array" then $raw_results else [] end) as $rs |
        (if ($matrix  | type) == "array" then $matrix  else [] end) as $m  |

        # Parse jobs_str; normalise to a flat array of job objects.
        # Accept both {"jobs":[...]} and a bare array.  Invalid JSON → [] (fail-open:
        # if we cannot read jobs we do not inflate the failed set).
        (($jobs_str | fromjson?) // []) as $raw_jobs |
        ($raw_jobs | if type == "object" then .jobs // [] else . end) as $job_list |

        # Terminal-failed jobs: conclusion is set, non-success, non-skipped.
        ($job_list | map(select(
            .conclusion != null and .conclusion != "" and
            .conclusion != "success" and .conclusion != "skipped"
        ))) as $bad_jobs |

        # Token-boundary regex helper (same definition as extract_failed_recovered).
        # Container names are [a-z0-9-]+ so safe to interpolate directly.
        def token_re(name):
            "(^|[^A-Za-z0-9_-])" + name + "([^A-Za-z0-9_-]|$)";

        # maps_to_container: true iff a job display name maps to a matrix container.
        # Used ONLY for the COUNT completeness gate (bad_build_job_count) — NOT for
        # failure attribution (failed_this_run stays artifact-record-based).
        #
        # Postgres alias: the extension pipeline jobs ("Build PostgreSQL Extensions
        # (arm64)", "Merge Extension Manifests (multi-arch)") emit records attributed
        # to "postgres", but their display names contain no lowercase "postgres" token.
        # Without the alias a crashed ext/merge job (no record produced) goes unnoticed
        # by the count gate → bad_build_job_count stays 0 → no gap → postgres is
        # falsely recovered. The alias fixes this: when the matrix contains "postgres",
        # extension/merge job names also count toward the gate.
        #
        # Bake alias: only build-result-PRODUCING bake jobs ("Bake build (amd64)",
        # "Bake build (arm64)", "Bake merge manifests + DockerHub mirror") contain no
        # container token. If a producing leg crashes before its "Emit build-result
        # artifacts" step it produces no failure record, so bad_build_job_count stays 0
        # without the alias and the completeness gate cannot fire → bake-managed
        # containers are falsely recovered. The alias fixes this: a job whose display
        # name starts with "Bake build" or "Bake merge" is counted toward the gate for
        # every bake-managed container.
        #
        # Advisory bake exclusion: "Trivy scan (bake) <container>:<tag> (<arch>)" and
        # "Attest SBOM (bake) <container>:<tag>" embed the container token in their
        # display name. They are best-effort; their failures produce NO build-result
        # artifacts and must NOT count toward the completeness gate for any container.
        # The guard returns false for these jobs BEFORE any token or alias match fires,
        # so even the realistic form "Trivy scan (bake) web-shell:1.7.7 (amd64)" does
        # not inflate bad_build_job_count and does not poison the checkpoint.
        def maps_to_container($jobname; $c):
            if ($jobname | test("^Trivy scan \\(bake\\)|^Attest SBOM \\(bake\\)")) then false
            else
              ($jobname | test(token_re($c)))
              or ($c == "postgres" and ($jobname | test("PostgreSQL Extensions|Extension Manifests")))
              or (($bake_managed | index($c)) != null and ($jobname | test("^Bake build|^Bake merge")))
            end;

        # fail_rec: matrix containers that have >=1 failure RECORD (artifact-precise).
        [ $m[] | . as $c |
          if ([ $rs[] | select(.container == $c and .result == "failure") ] | length) > 0
          then $c else empty end
        ] | sort | unique as $fail_rec |

        # succ_rec: matrix containers that have >=1 success record.
        [ $m[] | . as $c |
          if ([ $rs[] | select(.container == $c and .result == "success") ] | length) > 0
          then $c else empty end
        ] | sort | unique as $succ_rec |

        # failure_record_count: number of failure records whose container is in matrix.
        # (Excludes out-of-matrix failures — those are caught by the unmapped check below.)
        ([ $rs[] | . as $rec | select($rec.result == "failure" and ($m | index($rec.container)) != null) ] | length)
        as $failure_record_count |

        # bad_build_job_count: number of terminal-failed jobs that map to >=1 matrix
        # container via maps_to_container.  Each job counted at most once; infra jobs
        # (matching nothing) contribute 0 — this preserves the Sync-base-images all-13
        # fix.  The postgres extension/merge alias and the bake alias ensure that a
        # crashed ext/merge/bake job is counted even when its display name contains no
        # container token.
        ($bad_jobs | map(
            . as $job |
            if ([ $m[] | . as $c | select(maps_to_container($job.name; $c)) ] | length) > 0
            then 1 else 0 end
        ) | add // 0) as $bad_build_job_count |

        # out_of_matrix: any failure record whose .container is not in matrix.
        ([ $rs[] | select(.result == "failure") ] |
         map(.container) |
         map(. as $cn | ($m | index($cn)) == null) |
         any) as $out_of_matrix |

        # unmapped_failure: gap detected (more failed build jobs than failure records)
        # OR an out-of-matrix failure record exists.
        (($bad_build_job_count > $failure_record_count) or $out_of_matrix) as $unmapped |

        # failed_this_run: artifact-precise (fail_rec only).
        $fail_rec as $failed |

        # recovered_candidates: success-only containers (no failure record).
        [ $succ_rec[] | . as $c |
          if ($fail_rec | index($c)) == null
          then $c else empty end
        ] | sort | unique as $recovered |

        {
            failed_this_run:      $failed,
            recovered_candidates: $recovered,
            unmapped_failure:     $unmapped
        }
        '
}

# merge_failed_set <prior_json> <failed_this_json> <recovered_cand_json> <matrix_json> <unmapped_failure>
#
# Compute the new failed-container set to store in the next checkpoint tag.
#
# Semantics:
#   - If unmapped_failure == "true": output sorted-unique (matrix ∪ prior).
#     Rationale: an unattributed failure means we can't safely say anything
#     was fully covered; expand the retry set conservatively.
#   - Otherwise:
#       recovered  = recovered_candidates ∩ prior   (was failing, now explicitly green)
#       new_failed = (prior ∪ failed_this_run) − recovered
#
# A container in prior that was NOT in this run's matrix is NOT recovered
# (it was never attempted), so it stays in the set.
#
# Output: compact JSON array, sorted and unique.
merge_failed_set() {
    local prior_json="${1:-[]}"
    local failed_this_json="${2:-[]}"
    local recovered_cand_json="${3:-[]}"
    local matrix_json="${4:-[]}"
    local unmapped_failure="${5:-false}"

    jq -cn \
        --argjson prior "$prior_json" \
        --argjson failed "$failed_this_json" \
        --argjson recovered_cand "$recovered_cand_json" \
        --argjson matrix "$matrix_json" \
        --arg unmapped "$unmapped_failure" \
        '
        if $unmapped == "true" then
            # Fail-closed: carry everything — prior + matrix (any unattributed failure
            # means we cannot confirm any subset was safely covered).
            ($prior + $matrix | unique | sort)
        else
            # recovered = recovered_candidates ∩ prior
            # (only drop a container from the failed set if it was previously
            #  failing AND this run completed it successfully)
            [ $recovered_cand[] | . as $x |
              if ($prior | index($x)) != null then $x else empty end
            ] as $recovered |

            # new_failed = (prior ∪ failed_this_run) − recovered
            (($prior + $failed | unique) |
             map(. as $x |
               if ($recovered | index($x)) != null then empty else . end
             ) | sort | unique)
        end
        '
}
