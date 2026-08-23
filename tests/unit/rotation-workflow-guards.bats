#!/usr/bin/env bats

# Workflow wiring is declarative. Inspect it as YAML rather than grepping a
# serialization whose indentation and quoting are not part of the contract.

load "../test_helper"

bats_require_minimum_version 1.5.0

_rotation_read_status() {
    # The quarantine runner has downloaded artifacts but no repository checkout.
    # Run the extracted function from an isolated directory so a repository file
    # cannot accidentally make this test pass.
    eval "$ROTATION_READER_SOURCE"
    read_rotation_status "$1"
}

@test "rotation consumer needs no checkout and accepts only exact producer records" {
    mkdir -p "$BATS_TEST_TMPDIR/rotation-artifacts/status"
    pushd "$BATS_TEST_TMPDIR" >/dev/null || return 1

    run yq -r '.jobs.quarantine.steps[] | select(.id == "attribution") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" != *'source '* ]]
    [[ "$output" != *'helpers/'* ]]
    [[ "$output" != *'_escape_gha_command'* ]]

    local function_source cleanup_source
    cleanup_source=$(sed -n '/^remove_canonical_file() {/,/^}$/p' <<< "$output") || return 1
    function_source="$cleanup_source"$'\n'"$(sed -n '/^read_rotation_status() {/,/^}$/p' <<< "$output")" || return 1

    run --separate-stderr env ROTATION_READER_SOURCE="$function_source" bash -c "$(declare -f _rotation_read_status); _rotation_read_status build-amd64"
    [ "$status" -eq 0 ]
    [ "$output" = infra ]

    printf 'not-a-state detail\n' > rotation-artifacts/status/build-amd64
    run --separate-stderr env ROTATION_READER_SOURCE="$function_source" bash -c "$(declare -f _rotation_read_status); _rotation_read_status build-amd64"
    [ "$status" -eq 0 ]
    [ "$output" = infra ]

    printf 'build-failed\n\n' > rotation-artifacts/status/build-amd64
    run --separate-stderr env ROTATION_READER_SOURCE="$function_source" bash -c "$(declare -f _rotation_read_status); _rotation_read_status build-amd64"
    [ "$status" -eq 0 ]
    [ "$output" = infra ]

    printf 'build\0failed\n' > rotation-artifacts/status/build-amd64
    run --separate-stderr env ROTATION_READER_SOURCE="$function_source" bash -c "$(declare -f _rotation_read_status); _rotation_read_status build-amd64"
    [ "$status" -eq 0 ]
    [ "$output" = infra ]

    printf 'build-failed\n' > rotation-artifacts/status/build-amd64
    run --separate-stderr env ROTATION_READER_SOURCE="$function_source" bash -c "$(declare -f _rotation_read_status); _rotation_read_status build-amd64"
    [ "$status" -eq 0 ]
    [ "$output" = build-failed ]

    printf 'success\n' > rotation-artifacts/status/build-amd64
    run --separate-stderr env ROTATION_READER_SOURCE="$function_source" bash -c '
        set -e
        rm() { return 1; }
        eval "$ROTATION_READER_SOURCE"
        read_rotation_status build-amd64 > state
        [ "$(<state)" = success ]
    '
    [ "$status" -eq 0 ]

    popd >/dev/null || return 1
}

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
    # Two upload steps, each run for every architecture: frozen digest and build attribution.
    [ "$count" -eq 2 ]
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

@test "rotation test jobs rethrow each tolerated candidate failure" {
    local job build_condition build_run suite_condition suite_run

    # These names intentionally couple the guard to the steps it rethrows. That
    # is cheaper and clearer than adding workflow-only ids for test addressing.
    for job in test-amd64 test-arm64; do
        run yq -r ".jobs.\"$job\".steps[] | select(.name == \"Fail candidate image build result\") | .if" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"
        [ "$status" -eq 0 ]
        build_condition="$output"
        [ "$build_condition" = "steps.build-e2e-image.outcome == 'failure'" ]

        run yq -r ".jobs.\"$job\".steps[] | select(.name == \"Fail candidate image build result\") | .run" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"
        [ "$status" -eq 0 ]
        build_run="$output"
        [ "$build_run" = "exit 1" ]

        run yq -r ".jobs.\"$job\".steps[] | select(.name == \"Fail e2e suite result\") | .if" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"
        [ "$status" -eq 0 ]
        suite_condition="$output"
        [ "$suite_condition" = "steps.e2e.outcome == 'failure'" ]

        run yq -r ".jobs.\"$job\".steps[] | select(.name == \"Fail e2e suite result\") | .run" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"
        [ "$status" -eq 0 ]
        suite_run="$output"
        [ "$suite_run" = "exit 1" ]
    done
}

@test "rotation cleanup failure makes a build-failed producer infra without hiding its failure exit" {
    local bin_dir="$BATS_TEST_TMPDIR/cleanup-failure-bin"
    local status_file="$BATS_TEST_TMPDIR/cleanup-failure-status"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -rf ]]; then
    exit 75
fi
exec /bin/rm "$@"
EOF
    chmod +x "$bin_dir/rm"

    run env PATH="$bin_dir:$PATH" TMPDIR="$BATS_TEST_TMPDIR" ROTATION_STATUS_FILE="$status_file" \
        bash -c '
            source "$1"
            _ROTATION_BUILD_STATUS=build-failed
            _RESOLVER_CACHE_DIR="$2/resolver-cache"
            _BUILT_THIS_RUN_DIR="$2/built-this-run"
            _rotation_build_exit 1
        ' _ "$PROJECT_ROOT/scripts/build-extensions.sh" "$BATS_TEST_TMPDIR"

    [ "$status" -ne 0 ]
    [ "$(<"$status_file")" = infra ]
}

@test "rotation status rename cannot place a record inside a raced target directory" {
    local status_file="$BATS_TEST_TMPDIR/build-status"

    run env TMPDIR="$BATS_TEST_TMPDIR" ROTATION_STATUS_FILE="$status_file" \
        bash -c '
            source "$1"
            mv() {
                mkdir "$ROTATION_STATUS_FILE"
                command mv "$@"
            }
            if _write_rotation_status infra; then
                exit 1
            fi
            [[ -d "$ROTATION_STATUS_FILE" ]]
            [[ -z "$(find "$ROTATION_STATUS_FILE" -mindepth 1 -print -quit)" ]]
        ' _ "$PROJECT_ROOT/scripts/build-extensions.sh"

    [ "$status" -eq 0 ]
}

@test "rotation status artifacts keep build producer state files" {
    local names build_path attribution issue_body

    run yq -r '
      .jobs[] | .steps[]?
      | select(.uses == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a")
      | select(.with.name | test("^rotation-status-"))
      | .with.name
    ' "$PROJECT_ROOT/.github/workflows/rotation.yaml"

    [ "$status" -eq 0 ]
    names="$output"
    [ "$(printf '%s\n' "$names" | sort -u | wc -l)" -eq 1 ]
    [[ "$names" == *'rotation-status-build-${{ matrix.arch }}'* ]]

    run yq -r '.jobs.build.steps[] | select(.name == "Upload build attribution") | .with.path' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = 'rotation-artifacts/build-${{ matrix.arch }}' ]

    run yq -r '.jobs.quarantine.steps[] | select(.id == "attribution") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    attribution="$output"
    [[ "$attribution" == *'status_names=(build-amd64 build-arm64)'* ]]
    [[ "$attribution" == *'treating it as infra'* ]]
    [[ "$attribution" == *'remove_canonical_file "$canonical_file"'* ]]
    [[ "$attribution" == *'if ! rm -f -- "$canonical_file"; then'* ]]
    [[ "$attribution" != *'_escape_gha_command'* ]]
    [[ "$attribution" == *'"${states[build-amd64]}" == build-failed && "${states[build-arm64]}" == build-failed'* ]]
    [[ "$attribution" == *"A test failure cannot quarantine"* ]]
    [[ "$attribution" == *'state_lines+=("${status_name}=${states[$status_name]}")'* ]]

    run yq -r '.jobs.quarantine.steps[] | select(.name == "Quarantine failing extension pair") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    issue_body="$output"
    [[ "$issue_body" == *"Producer states:"* ]]
    [[ "$issue_body" == *'for producer_state in "${producer_states[@]}"; do'* ]]
}

@test "one build-failed leg does not warrant quarantine" {
    local attribution decision_source

    run yq -r '.jobs.quarantine.steps[] | select(.id == "attribution") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    attribution="$output"
    decision_source=$(sed -n '/^quarantine_evidence_warrants_action() {/,/^}$/p' <<< "$attribution") || return 1

    run env ROTATION_DECISION_SOURCE="$decision_source" bash -c '
        declare -A states=([build-amd64]=build-failed [build-arm64]=infra)
        eval "$ROTATION_DECISION_SOURCE"
        quarantine_evidence_warrants_action
        [[ "$create" == false && ${#reasons[@]} -eq 0 ]]
    '
    [ "$status" -eq 0 ]
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

@test "rotation schedules three daily runs with enough room for a long run" {
    run yq -r '.on.schedule | length' "$PROJECT_ROOT/.github/workflows/rotation.yaml"

    [ "$status" -eq 0 ]
    [ "$output" -eq 3 ]

    run yq -r '.on.schedule[].cron' "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = $'17 1 * * *\n17 9 * * *\n17 17 * * *' ]
}

@test "rotation cleanup retains staging after failed or cancelled promotion" {
    run yq -r '.jobs."cleanup-staging".if' "$PROJECT_ROOT/.github/workflows/rotation.yaml"

    [ "$status" -eq 0 ]
    [[ "$output" == *"needs.promote.result != 'failure'"* ]]
    [[ "$output" == *"needs.promote.result != 'cancelled'"* ]]
    [ "$output" != 'always()' ]

    run yq -r '.jobs."retain-staging-after-promotion-failure".if' "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs.promote.result == 'failure'"* ]]

    run yq -r '.jobs."cleanup-staging".steps[] | select(.name == "Delete staging packages") | ."continue-on-error" // false' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "rotation validates a dispatch pair and rechecks blocks before compiling" {
    local select_run recheck_index compile_index

    run yq -r '.on.workflow_dispatch.inputs | has("version")' "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = false ]

    run yq -r '.jobs.select.steps[] | select(.id == "select") | .run' \
        "$PROJECT_ROOT/.github/workflows/rotation.yaml"
    [ "$status" -eq 0 ]
    select_run="$output"
    [[ "$select_run" == *'.extensions[strenv(DISPATCH_EXTENSION)].version'* ]]
    [[ "$select_run" == *'[[ "$DISPATCH_EXTENSION" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]'* ]]
    [[ "$select_run" == *'[[ "$DISPATCH_MAJOR" =~ ^[0-9]+$ ]]'* ]]
    [[ "$select_run" == *".pg_versions[]"* ]]
    [[ "$select_run" == *'get_flavor_extensions postgres/extensions/config.yaml full "$DISPATCH_MAJOR"'* ]]
    [[ "$select_run" == *"printf 'selected=true\\n'"* ]]

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

@test "rotation test-job push comments do not claim a post-build push" {
    local comment

    for job in test-amd64 test-arm64; do
        run yq -r ".jobs.\"$job\".steps[] | select(.id == \"build-e2e-image\") | .with | to_entries[] | select(.key == \"push\") | (.key | headComment)" \
            "$PROJECT_ROOT/.github/workflows/rotation.yaml"

        [ "$status" -eq 0 ]
        [[ "$output" != *'post-build push'* ]]
    done
}
