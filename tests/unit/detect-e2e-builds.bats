#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    export IS_FORK_PR="false"
}

teardown() {
    unset BUILDS VERIFICATION_BUILDS EVENT_NAME BUILD_ALL_RETAINED RUN_TESTS IS_FORK_PR GITHUB_ACTION_PATH GITHUB_OUTPUT
    teardown_temp_dir
}

run_split_build_engine_step() {
    local builds="$1"
    local verification_builds="${2:-[]}"
    local script="$TEST_TEMP_DIR/split-build-engine.sh"
    yq -r '.runs.steps[] | select(.id == "split-build-engine") | .run' \
        "$PROJECT_ROOT/.github/actions/detect-containers/action.yaml" > "$script"

    export BUILDS="$builds"
    export VERIFICATION_BUILDS="$verification_builds"
    export EVENT_NAME="pull_request"
    export BUILD_ALL_RETAINED="false"
    export RUN_TESTS="false"
    export GITHUB_ACTION_PATH="$PROJECT_ROOT/.github/actions/detect-containers"
    export GITHUB_OUTPUT="$TEST_TEMP_DIR/github-output"

    run bash "$script"
}

output_value() {
    local name="$1"
    sed -n "s/^${name}=//p" "$GITHUB_OUTPUT" | tail -1
}

@test "deleting e2e filtering would stop an enabled changed container from running its latest Linux suite" {
    builds=$(jq -cn '
      [
        {"container":"sslh","version":"v2.3.1","tag":"v2.3.1-alpine","is_default":true,"is_latest_version":true,"os":"linux","runner":"ubuntu-latest"},
        {"container":"sslh","version":"v2.3.0","tag":"v2.3.0-alpine","is_default":false,"is_latest_version":false,"os":"linux","runner":"ubuntu-latest"},
        {"container":"sslh","version":"v2.3.1","tag":"v2.3.1-windows","is_default":false,"is_latest_version":true,"os":"windows","runner":"windows-latest"}
      ]')

    run_split_build_engine_step "$builds"

    [ "$status" -eq 0 ]
    e2e_builds=$(output_value e2e_builds)
    [ "$(echo "$e2e_builds" | jq 'length')" -eq 1 ]
    [ "$(echo "$e2e_builds" | jq -r '.[0].container')" = "sslh" ]
    [ "$(echo "$e2e_builds" | jq -r '.[0].tag')" = "v2.3.1-alpine" ]
}

@test "deleting the e2e opt-in check would run a non-enabled container's suite" {
    builds=$(jq -cn '
      [
        {"container":"github-runner","version":"2.330.0","tag":"latest-2.330.0","is_default":true,"is_latest_version":true,"os":"linux","runner":"ubuntu-latest"}
      ]')

    run_split_build_engine_step "$builds"

    [ "$status" -eq 0 ]
    e2e_builds=$(output_value e2e_builds)
    [ "$e2e_builds" = "[]" ]
}

@test "deleting the cell dedupe would run the same e2e variant twice for mixed source and test changes" {
    build=$(jq -cn '
      {"container":"sslh","version":"v2.3.1","tag":"v2.3.1-alpine","is_default":true,"is_latest_version":true,"os":"linux","runner":"ubuntu-latest"}')

    run_split_build_engine_step "[$build]" "[$build]"

    [ "$status" -eq 0 ]
    [ "$(output_value bake_builds)" != "[]" ]
    [ "$(output_value matrix_builds)" = "[]" ]
    e2e_builds=$(output_value e2e_builds)
    [ "$(echo "$e2e_builds" | jq 'length')" -eq 1 ]
    [ "$(echo "$e2e_builds" | jq -r '.[0].container + ":" + .[0].tag')" = "sslh:v2.3.1-alpine" ]
}

@test "deleting production isolation would schedule bake or matrix builds for a verification-only change" {
    verification_builds=$(jq -cn '
      [
        {"container":"sslh","version":"v2.3.1","tag":"v2.3.1-alpine","is_default":true,"is_latest_version":true,"os":"linux","runner":"ubuntu-latest"}
      ]')

    run_split_build_engine_step "[]" "$verification_builds"

    [ "$status" -eq 0 ]
    [ "$(output_value bake_builds)" = "[]" ]
    [ "$(output_value matrix_builds)" = "[]" ]
    [ "$(echo "$(output_value e2e_builds)" | jq 'length')" -eq 1 ]
}

@test "deleting the e2e opt-in check would run a verification-only non-enabled container" {
    verification_builds=$(jq -cn '
      [
        {"container":"github-runner","version":"2.330.0","tag":"latest-2.330.0","is_default":true,"is_latest_version":true,"os":"linux","runner":"ubuntu-latest"}
      ]')

    run_split_build_engine_step "[]" "$verification_builds"

    [ "$status" -eq 0 ]
    [ "$(output_value bake_builds)" = "[]" ]
    [ "$(output_value matrix_builds)" = "[]" ]
    [ "$(output_value e2e_builds)" = "[]" ]
}
