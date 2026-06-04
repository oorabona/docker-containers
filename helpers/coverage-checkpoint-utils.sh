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
#   extract_failed_recovered      <jobs_json> <matrix_json>
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
