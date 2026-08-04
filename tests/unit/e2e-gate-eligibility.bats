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
    local workflow="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    E2E_IF=$(yq -r '.jobs["e2e-test"]["if"]' "$workflow")
    E2E_NEEDS=$(yq -o=json '.jobs["e2e-test"].needs' "$workflow")
    BUILD_EXTENSIONS_IF=$(yq -r '.jobs["build-extensions"]["if"]' "$workflow")
    E2E_PR_TAG_SUFFIX=$(yq -r '.jobs["e2e-test"].env.PR_TAG_SUFFIX' "$workflow")
    PRODUCTION_PR_TAG_SUFFIX=$(yq -r '.jobs["build-and-push"].env.PR_TAG_SUFFIX' "$workflow")
}

teardown() {
    unset E2E_IF E2E_NEEDS BUILD_EXTENSIONS_IF E2E_PR_TAG_SUFFIX PRODUCTION_PR_TAG_SUFFIX
    teardown_temp_dir
}

@test "e2e waits for the extension pipeline and base-image sync" {
    [ "$E2E_NEEDS" = '[
  "detect-containers",
  "build-extensions",
  "merge-extension-manifests",
  "sync-base-images"
]' ]
}

@test "a skipped extension pipeline still permits e2e" {
    # `build-extensions` itself skips for extension_builds == '[]'. Since a
    # `needs` dependency otherwise skips its dependent job before its condition
    # runs, e2e must use the production guard's always() and success|skipped
    # result allowance for every new upstream dependency.
    [[ "$BUILD_EXTENSIONS_IF" == *"needs.detect-containers.outputs.extension_builds != '[]'"* ]]
    [[ "$E2E_IF" == *"always()"* ]]
    [[ "$E2E_IF" == *"(needs.build-extensions.result == 'success' || needs.build-extensions.result == 'skipped')"* ]]
    [[ "$E2E_IF" == *"(needs.merge-extension-manifests.result == 'success' || needs.merge-extension-manifests.result == 'skipped')"* ]]
    [[ "$E2E_IF" == *"(needs.sync-base-images.result == 'success' || needs.sync-base-images.result == 'skipped')"* ]]
}

@test "e2e and production builds use the identical PR extension tag suffix" {
    [ "$E2E_PR_TAG_SUFFIX" = "$PRODUCTION_PR_TAG_SUFFIX" ]
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
