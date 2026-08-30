#!/usr/bin/env bats

load "../test_helper"

summary_step() {
    yq -r '.jobs.validate-version-scripts.steps[] | select(.name == "Display test results") | .run' \
        "$PROJECT_ROOT/.github/workflows/validate-version-scripts.yaml"
}

summary_requested_container() {
    yq -r '.jobs.validate-version-scripts.steps[] | select(.name == "Display test results") | .env.REQUESTED_CONTAINER' \
        "$PROJECT_ROOT/.github/workflows/validate-version-scripts.yaml"
}

rendered_summary_step() {
    summary_step | sed \
        -e 's/${{ steps.detect-containers.outputs.count }}/${CONTAINER_COUNT}/g' \
        -e 's/${{ steps.test-upstream.outputs.test_single }}/${TEST_SINGLE}/g' \
        -e 's/${{ steps.test-upstream.outputs.first_container }}/${FIRST_CONTAINER}/g'
}

setup() {
    SUMMARY_FILE=$(mktemp)
}

teardown() {
    rm -f "$SUMMARY_FILE"
}

run_summary() {
    local requested_container="$1"
    local container_count="$2"
    local test_single="$3"
    local first_container="$4"

    : > "$SUMMARY_FILE"
    run env \
        REQUESTED_CONTAINER="$requested_container" \
        CONTAINER_COUNT="$container_count" \
        TEST_SINGLE="$test_single" \
        FIRST_CONTAINER="$first_container" \
        GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
        bash -c "$(rendered_summary_step)"
    SUMMARY_OUTPUT=$(<"$SUMMARY_FILE")
}

assert_summary_contains() {
    local expected="$1"

    [[ "$SUMMARY_OUTPUT" == *"$expected"* ]] || {
        printf 'ASSERTION FAILED: expected summary to contain: %s\nActual summary:\n%s\n' \
            "$expected" "$SUMMARY_OUTPUT" >&2
        return 1
    }
}

assert_summary_omits() {
    local unexpected="$1"

    [[ "$SUMMARY_OUTPUT" != *"$unexpected"* ]] || {
        printf 'ASSERTION FAILED: expected summary to omit: %s\nActual summary:\n%s\n' \
            "$unexpected" "$SUMMARY_OUTPUT" >&2
        return 1
    }
}

@test "validation summary receives the dispatch container" {
    [ "$(summary_requested_container)" == "\${{ github.event.inputs.container || '' }}" ] || {
        echo "ASSERTION FAILED: summary must receive the dispatch container" >&2
        return 1
    }
}

# Rendering-only coverage: the workflow cannot be executed in this fixture.
# Execution coverage for the upstream action belongs in
# check-upstream-versions-action.bats; this test asserts only its summary prose.
@test "validation summary renders dispatch-specific check descriptions" {
    local name requested_container container_count test_single first_container expected omitted
    local -a cases=(
        'scoped-single|postgres|1|true|postgres|The `postgres/version.sh` script passed its validation checks.|All version.sh scripts passed their validation checks.'
        'unscoped-single||1|true|postgres|All version.sh scripts passed their validation checks.|The `postgres/version.sh` script passed its validation checks.'
        'scoped-many|postgres|2|true|postgres|The `postgres/version.sh` script passed its validation checks.|All-container upstream check'
        'unscoped-many||2|true|postgres|All-container upstream check|The `postgres/version.sh` script passed its validation checks.'
        'no-containers||0|false||Skipped (no containers detected)|Upstream monitoring test target:'
        'single-test-skipped||1|false||Single container test skipped (no valid container found)|Upstream monitoring test target:'
    )

    for case_data in "${cases[@]}"; do
        IFS='|' read -r name requested_container container_count test_single first_container expected omitted <<< "$case_data"
        run_summary "$requested_container" "$container_count" "$test_single" "$first_container"
        [ "$status" -eq 0 ] || {
            printf 'ASSERTION FAILED: summary case %s exited %s: %s\n' "$name" "$status" "$output" >&2
            return 1
        }
        assert_summary_contains "$expected"
        assert_summary_omits "$omitted"
        assert_summary_omits "can validate specific versions"
        if [[ -n "$requested_container" ]]; then
            assert_summary_contains "\`$requested_container/version.sh\` was checked for shell syntax, dependencies, upstream version retrieval, and output format"
        else
            assert_summary_contains "Each version.sh script was checked for shell syntax and dependencies"
            assert_summary_contains "Each version.sh script was checked for upstream version retrieval and output format"
        fi
        if [[ "$container_count" -gt 0 && "$test_single" == "true" ]]; then
            assert_summary_contains "Selected-container check completed through make"
            assert_summary_contains "Existing make script infrastructure exercised"
        else
            assert_summary_omits "Selected-container check completed through make"
            assert_summary_omits "Existing make script infrastructure exercised"
        fi
    done
}

@test "validation summary names the checks run by validate-version-scripts" {
    run_summary 'postgres' 1 true postgres
    [ "$status" -eq 0 ]
    assert_summary_contains '`postgres/version.sh` was checked for shell syntax, dependencies, upstream version retrieval, and output format'

    run_summary '' 1 true postgres
    [ "$status" -eq 0 ]
    assert_summary_contains 'Each version.sh script was checked for shell syntax and dependencies'
    assert_summary_contains 'Each version.sh script was checked for upstream version retrieval and output format'
}
