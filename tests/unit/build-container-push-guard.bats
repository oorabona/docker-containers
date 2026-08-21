#!/usr/bin/env bats

# Composite-action wiring is not executable by Bats. Read its YAML shape with
# yq so both registry pushes and both rotation test callers stay covered.

load "../test_helper"

@test "every build-container push step requires the push input" {
    local name condition count=0

    run yq -r '.runs.steps[] | [.name, .if] | @tsv' \
        "$PROJECT_ROOT/.github/actions/build-container/action.yaml"

    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r name condition; do
        [[ "$name" == 'Push to'* ]] || continue
        [[ "$condition" == *"inputs.push == 'true'"* ]]
        count=$((count + 1))
    done <<< "$output"
    [ "$count" -eq 2 ]
}

@test "rotation test jobs disable publishing for their candidate images" {
    local job

    for job in test-amd64 test-arm64; do
        run yq -r ".jobs.\"$job\".steps[] | select(.uses == \"./.github/actions/build-container\") | .with.push" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"

        [ "$status" -eq 0 ]
        [ "$output" = 'false' ]
    done
}
