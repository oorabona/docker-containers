#!/usr/bin/env bats

load "../test_helper"

UPDATE_DASHBOARD_YAML="${PROJECT_ROOT}/.github/workflows/update-dashboard.yaml"

setup() {
    setup_temp_dir
    TEST_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$TEST_REPO/scripts"
}

teardown() {
    teardown_temp_dir
}

extract_step_block() {
    local step_name="$1"

    awk -v step_name="$step_name" '
        $0 == "      - name: " step_name {
            in_step = 1
            print
            next
        }
        in_step && $0 ~ /^      - name: / {
            exit
        }
        in_step {
            print
        }
    ' "$UPDATE_DASHBOARD_YAML"
}

extract_job_block() {
    local job_name="$1"

    awk -v job_name="$job_name" '
        $0 == "  " job_name ":" {
            in_job = 1
            print
            next
        }
        in_job && $0 ~ /^  [A-Za-z0-9_-]+:/ {
            exit
        }
        in_job {
            print
        }
    ' "$UPDATE_DASHBOARD_YAML"
}

extract_job_if() {
    local job_name="$1"

    extract_job_block "$job_name" | awk '
        $0 ~ /^    if: \|[[:space:]]*$/ {
            in_if = 1
            next
        }
        in_if && $0 ~ /^      / {
            sub(/^      /, "")
            print
            next
        }
        in_if {
            exit
        }
    '
}

extract_step_run() {
    local step_name="$1"

    extract_step_block "$step_name" | awk '
        $0 ~ /^        run: \|[[:space:]]*$/ {
            in_run = 1
            next
        }
        in_run && $0 ~ /^          / {
            sub(/^          /, "")
            print
            next
        }
        in_run {
            exit
        }
    '
}

@test "update-dashboard build job does not run an inline stats snapshot" {
    # Regression lock (#876 hardening): the build job used to call
    # snapshot-stats.sh locally, feeding a NEVER-committed row into that
    # job's own render of the trend sparkline. Since commit-stats-snapshot
    # independently re-fetches and pushes the same day's data, the two could
    # diverge (two independent Docker Hub fetches, no ordering guarantee) —
    # the deployed trend could show a different pull_count for today than
    # what actually landed in git. The build job must rely solely on
    # whatever is already committed as of its checkout.
    step_block="$(extract_step_block "Snapshot pull/star counts (non-blocking)")"
    [ -z "$step_block" ]

    build_job="$(extract_job_block "build")"
    [[ "$build_job" != *"snapshot-stats.sh"* ]]
}

@test "update-dashboard commit stats job still calls commit wrapper directly" {
    step_block="$(extract_step_block "Commit stats snapshot (non-blocking)")"

    [[ "$step_block" == *"./scripts/commit-stats-snapshot.sh"* ]]
    [[ "$step_block" != *"./scripts/snapshot-stats.sh"* ]]
    [[ "$step_block" != *"|| true"* ]]
    [[ "$step_block" != *"continue-on-error: true"* ]]
}

@test "update-dashboard commit stats job gates workflow_dispatch to master" {
    job_if="$(extract_job_if "commit-stats-snapshot")"
    normalized_if="$(printf '%s' "$job_if" | tr '\n' ' ' | tr -s ' ')"

    [[ "$normalized_if" == *"(github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/master')"* ]]
    [[ "$normalized_if" != *"github.event_name == 'workflow_dispatch' ||"* ]]
}

@test "update-dashboard commit stats job has actions:write for its follow-up dispatch" {
    job_block="$(extract_job_block "commit-stats-snapshot")"

    [[ "$job_block" == *"actions: write"* ]]
    [[ "$job_block" == *"contents: write"* ]]
}

@test "update-dashboard build and deploy use separate, non-workflow-level concurrency groups" {
    # A single workflow-level "pages" group would cancel commit-stats-snapshot's
    # whole run whenever an unrelated trigger superseded it. A single
    # job-level group shared by build+deploy has its own bug — an unrelated
    # newer build can cancel an already in-flight deploy. Both must be
    # distinct, job-scoped groups.
    full_yaml="$(cat "$UPDATE_DASHBOARD_YAML")"
    [[ "$full_yaml" != *$'\nconcurrency:\n  group: "pages"'* ]]

    build_job="$(extract_job_block "build")"
    [[ "$build_job" == *'group: "pages-build"'* ]]
    [[ "$build_job" == *"cancel-in-progress: true"* ]]

    deploy_job="$(extract_job_block "deploy")"
    [[ "$deploy_job" == *'group: "pages-deploy"'* ]]
    [[ "$deploy_job" == *"cancel-in-progress: false"* ]]

    commit_job="$(extract_job_block "commit-stats-snapshot")"
    [[ "$commit_job" == *"group: commit-stats-snapshot"* ]]
}

@test "update-dashboard never interpolates trigger_reason directly into a run: script" {
    # trigger_reason is caller-supplied free text (workflow_dispatch /
    # workflow_call input) — interpolating the raw ${{ }} expression into a
    # run: block lets it break out of quoting and execute commands on the
    # runner. It must always cross via env: first.
    full_yaml="$(cat "$UPDATE_DASHBOARD_YAML")"
    [[ "$full_yaml" != *'"${{ github.event.inputs.trigger_reason'* ]]

    generate_step="$(extract_step_block "Generate dashboard data")"
    [[ "$generate_step" == *"TRIGGER_REASON:"* ]]
    [[ "$generate_step" == *'"$TRIGGER_REASON"'* ]]
}
