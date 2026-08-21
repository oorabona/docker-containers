#!/usr/bin/env bats

# Workflow wiring is declarative. Inspect it as YAML rather than grepping a
# serialization whose indentation and quoting are not part of the contract.

load "../test_helper"

@test "rotation uploads use visible paths and fail empty matches" {
    local path policy count=0

    run yq -r '
      .jobs[] | .steps[]?
      | select(.uses == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a")
      | [.with.path, .with."if-no-files-found"] | @tsv
    ' "$PROJECT_ROOT/.github/workflows/rotation.yaml"

    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r path policy; do
        [[ "/$path/" != */.*/* ]]
        [ "$policy" = error ]
        count=$((count + 1))
    done <<< "$output"
    [ "$count" -eq 4 ]
}

@test "rotation e2e suites identify the exact full build cell" {
    local job expected

    expected="\${{ format('{0}-full-alpine', needs.select.outputs.major) }}"$'\t'"\${{ needs.select.outputs.major }}"$'\tfull\tfull'
    for job in test-amd64 test-arm64; do
        run yq -r ".jobs.\"$job\".steps[] | select(.id == \"e2e\") | [.env.E2E_BUILD_TAG, .env.E2E_BUILD_VERSION, .env.E2E_BUILD_VARIANT, .env.E2E_BUILD_FLAVOR] | @tsv" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"

        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
    done
}

@test "rotation status artifacts keep producer-specific names" {
    local names build_path

    run yq -r '
      .jobs[] | .steps[]?
      | select(.uses == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a")
      | select(.with.name | test("^rotation-status-"))
      | .with.name
    ' "$PROJECT_ROOT/.github/workflows/rotation.yaml"

    [ "$status" -eq 0 ]
    names="$output"
    [ "$(printf '%s\n' "$names" | sort -u | wc -l)" -eq 3 ]
    [[ "$names" == *'rotation-status-build-${{ matrix.arch }}'* ]]
    [[ "$names" == *'rotation-status-test-amd64'* ]]
    [[ "$names" == *'rotation-status-test-arm64'* ]]

    run yq -r '.jobs.build.steps[] | select(.name == "Upload build attribution") | .with.path' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = 'rotation-artifacts/build-${{ matrix.arch }}' ]

    run yq -r '.jobs.quarantine.steps[] | select(.id == "attribution") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'expected_statuses=(build-amd64 build-arm64)'* ]]
    [[ "$output" == *'Missing failure attribution from completed producer'* ]]
}

@test "build-container accepts only literal boolean push values" {
    local validation

    run yq -r '.runs.steps[] | select(.name == "Validate push input") | .env.PUSH' \
        "$PROJECT_ROOT/.github/actions/build-container/action.yaml"

    [ "$status" -eq 0 ]
    [ "$output" = '${{ inputs.push }}' ]

    run yq -r '.runs.steps[] | select(.name == "Validate push input") | .run' \
        "$PROJECT_ROOT/.github/actions/build-container/action.yaml"
    [ "$status" -eq 0 ]
    validation="$output"
    [[ "$validation" == *$'case "$PUSH" in\n  true|false) ;;'* ]]
    [[ "$validation" == *'_escape_gha_command "$PUSH"'* ]]
    [[ "$validation" == *'Invalid push input'* ]]
}

@test "rotation cleanup retains staging after a failed promotion" {
    run yq -r '.jobs."cleanup-staging".if' "$PROJECT_ROOT/.github/workflows/rotation.yaml"

    [ "$status" -eq 0 ]
    [[ "$output" == *"needs.promote.result != 'failure'"* ]]
    [ "$output" != 'always()' ]

    run yq -r '.jobs."retain-staging-after-promotion-failure".if' "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs.promote.result == 'failure'"* ]]

    run yq -r '.jobs."cleanup-staging".steps[] | select(.name == "Delete staging packages") | ."continue-on-error" // false' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "rotation derives a dispatch version and rechecks blocks before compiling" {
    local select_run recheck_index compile_index

    run yq -r '.on.workflow_dispatch.inputs | has("version")' "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = false ]

    run yq -r '.jobs.select.steps[] | select(.id == "select") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    select_run="$output"
    [[ "$select_run" == *'.extensions[strenv(DISPATCH_EXTENSION)].version'* ]]

    run yq -r '.jobs.build.steps | to_entries[] | select(.value.name == "Recheck rotation block before compiling") | .key' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    recheck_index="$output"
    run yq -r '.jobs.build.steps | to_entries[] | select(.value.id == "compile") | .key' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    compile_index="$output"
    [ "$compile_index" -eq $((recheck_index + 1)) ]
}
