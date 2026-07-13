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

extract_job_permissions() {
    local job_name="$1"

    extract_job_block "$job_name" | awk '
        $0 ~ /^    permissions:[[:space:]]*$/ {
            in_permissions = 1
            print
            next
        }
        in_permissions && $0 ~ /^    [A-Za-z0-9_-]+:/ {
            exit
        }
        in_permissions {
            print
        }
    '
}

extract_job_concurrency() {
    local job_name="$1"

    extract_job_block "$job_name" | awk '
        $0 ~ /^    concurrency:[[:space:]]*$/ {
            in_concurrency = 1
            print
            next
        }
        in_concurrency && $0 ~ /^    [A-Za-z0-9_-]+:/ {
            exit
        }
        in_concurrency {
            print
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

@test "update-dashboard passes downloaded stats candidate without overwriting checkout stats file" {
    restore_run="$(extract_step_run "Restore downloaded stats candidate")"
    commit_step="$(extract_step_block "Commit stats snapshot (non-blocking)")"

    [[ "$restore_run" == *"candidate_source_file="* ]]
    [[ "$restore_run" == *'$GITHUB_OUTPUT'* ]]
    [[ "$restore_run" != *"cp \"$candidate_file\" stats/dockerhub-pull-history.jsonl"* ]]
    [[ "$restore_run" != *"mkdir -p stats"* ]]

    [[ "$commit_step" == *"CANDIDATE_SOURCE_FILE:"* ]]
    [[ "$commit_step" == *"steps.stats-candidate.outputs.candidate_source_file"* ]]
}

@test "collect-stats-snapshot comment points at the real commit wrapper" {
    collect_script="$(cat "$SCRIPTS_DIR/collect-stats-snapshot.sh")"

    [[ "$collect_script" == *"scripts/commit-stats-snapshot.sh"* ]]
    [[ "$collect_script" != *"scripts/persist-stats-snapshot.sh"* ]]
}

@test "update-dashboard commit stats job gates workflow_dispatch to master" {
    job_if="$(extract_job_if "commit-stats-snapshot")"
    normalized_if="$(printf '%s' "$job_if" | tr '\n' ' ' | tr -s ' ')"

    [[ "$normalized_if" == *"needs.collect-stats-snapshot.result == 'success' &&"* ]]
    [[ "$normalized_if" == *"(github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/master')"* ]]
    [[ "$normalized_if" != *"github.event_name == 'workflow_dispatch' ||"* ]]
}

@test "update-dashboard commit stats job authenticates with a scoped App token and signs commits" {
    # master's ruleset requires PR-only changes and verified signatures — a
    # direct GITHUB_TOKEN push can satisfy neither, so this job must mint an
    # App token (scoped down to just contents:write) and import a GPG key
    # before the push happens. No actions:write: unlike GITHUB_TOKEN, an
    # App-token push retriggers this same workflow via its own push path
    # filter, so there is no explicit follow-up dispatch to authorize.
    job_block="$(extract_job_block "commit-stats-snapshot")"
    permissions_block="$(extract_job_permissions "commit-stats-snapshot")"

    [[ "$permissions_block" == *"contents: read"* ]]
    [[ "$permissions_block" != *"contents: write"* ]]
    [[ "$permissions_block" == *"actions: read"* ]]
    [[ "$permissions_block" != *"actions: write"* ]]
    [[ "$job_block" == *"create-github-app-token"* ]]
    [[ "$job_block" == *"permission-contents: write"* ]]
    [[ "$job_block" == *"ghaction-import-gpg"* ]]
    [[ "$job_block" == *"git_commit_gpgsign: true"* ]]
}

@test "update-dashboard stats collection and persistence are isolated by separate jobs" {
    # The security boundary is job separation, not step ordering: collect runs
    # on a different runner with a read-only job token, uploads inert data, and
    # never has the App token or GPG key material in scope.
    collect_job="$(extract_job_block "collect-stats-snapshot")"
    commit_job="$(extract_job_block "commit-stats-snapshot")"
    collect_permissions="$(extract_job_permissions "collect-stats-snapshot")"
    commit_permissions="$(extract_job_permissions "commit-stats-snapshot")"

    [[ "$collect_job" == *"collect-stats-snapshot:"* ]]
    [[ "$commit_job" == *"commit-stats-snapshot:"* ]]
    [[ "$collect_job" != "$commit_job" ]]

    [[ "$commit_job" == *"needs: collect-stats-snapshot"* ]]
    [[ "$collect_job" == *"outputs:"* ]]
    [[ "$collect_job" == *"still_missing: \${{ steps.collect.outputs.still_missing }}"* ]]
    [[ "$commit_job" == *"steps.persist.outputs.still_missing_after_reconcile"* ]]

    [[ "$collect_job" == *"actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a  # v4"* ]]
    [[ "$commit_job" == *"actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c  # v4"* ]]
    [[ "$collect_job" == *"name: dockerhub-stats-candidate"* ]]
    [[ "$collect_job" == *"overwrite: true"* ]]
    [[ "$commit_job" == *"name: dockerhub-stats-candidate"* ]]

    [[ "$collect_job" != *"Generate App token"* ]]
    [[ "$collect_job" != *"Import GPG key"* ]]
    [[ "$collect_job" != *"STATS_PUSH_TOKEN"* ]]
    [[ "$collect_job" != *"GPG_PRIVATE_KEY"* ]]

    [[ "$collect_permissions" == *"contents: read"* ]]
    [[ "$collect_permissions" != *"contents: write"* ]]
    [[ "$commit_permissions" == *"contents: read"* ]]
    [[ "$commit_permissions" != *"contents: write"* ]]
    [[ "$commit_permissions" != *"actions: write"* ]]
}

@test "update-dashboard final stats failure gate uses reconciled missing signal" {
    fail_step="$(extract_step_block "Fail if stats snapshot did not fully persist")"
    fail_if="$(printf '%s\n' "$fail_step" | awk '
        $0 ~ /^        if: / {
            sub(/^        if: /, "")
            print
        }
    ')"

    [[ "$fail_step" == *"steps.persist.outputs.still_missing_after_reconcile"* ]]
    [[ "$fail_if" == *"steps.persist.outputs.still_missing_after_reconcile == 'true'"* ]]
    [[ "$fail_if" == *"steps.persist.outputs.persisted != 'true'"* ]]
    [[ "$fail_if" != *"needs.collect-stats-snapshot.outputs.still_missing == 'true'"* ]]
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

    collect_concurrency="$(extract_job_concurrency "collect-stats-snapshot")"
    [[ "$collect_concurrency" == *"group: collect-stats-snapshot"* ]]
    [[ "$collect_concurrency" == *"cancel-in-progress: false"* ]]

    commit_job="$(extract_job_block "commit-stats-snapshot")"
    commit_concurrency="$(extract_job_concurrency "commit-stats-snapshot")"
    [ -z "$commit_concurrency" ]
    [[ "$commit_job" != *"group: commit-stats-snapshot"* ]]
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
