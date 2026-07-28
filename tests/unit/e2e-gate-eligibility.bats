#!/usr/bin/env bats
#
# The e2e job's own eligibility expression. It is asserted separately from the
# gate's decision table because the two are coupled: the gate now fails a pull
# request whose eligible e2e job was skipped, so an eligibility expression that
# skips the wrong pull requests turns into a blocked merge rather than a silent
# omission.

load "../test_helper"

setup() {
    setup_temp_dir
    E2E_IF=$(yq -r '.jobs["e2e-test"]["if"]' \
        "$PROJECT_ROOT/.github/workflows/auto-build.yaml")
}

teardown() {
    unset E2E_IF
    teardown_temp_dir
}

@test "deleting the identity check would skip e2e on a repository that is itself a fork" {
    # `head.repo.fork` is true for every branch of a repository that was forked
    # from somewhere, including its own. The question this job needs answered is
    # whether the pull request comes from elsewhere, which is an identity
    # comparison — the form the rest of this workflow already uses.
    [[ "$E2E_IF" == *"head.repo.full_name == github.repository"* ]]
    [[ "$E2E_IF" != *"head.repo.fork"* ]]
}

@test "deleting the event check would run e2e outside a pull request" {
    [[ "$E2E_IF" == *"github.event_name == 'pull_request'"* ]]
}

@test "deleting the eligibility check would start an e2e job with nothing to test" {
    [[ "$E2E_IF" == *"e2e_builds != '[]'"* ]]
}

@test "the same identity form is used by the sibling that guards cache writes" {
    # One workflow, one way of asking. A second spelling is how the two drift.
    run grep -c "head.repo.full_name == github.repository" \
        "$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    [ "$status" -eq 0 ]
    [ "$output" -ge 2 ]
}
