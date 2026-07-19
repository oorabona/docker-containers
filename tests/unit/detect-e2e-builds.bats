#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
}

teardown() {
    unset BUILDS EVENT_NAME BUILD_ALL_RETAINED RUN_TESTS GITHUB_ACTION_PATH GITHUB_OUTPUT
    teardown_temp_dir
}

run_split_build_engine_step() {
    local builds="$1"
    local script="$TEST_TEMP_DIR/split-build-engine.sh"
    yq -r '.runs.steps[] | select(.id == "split-build-engine") | .run' \
        "$PROJECT_ROOT/.github/actions/detect-containers/action.yaml" > "$script"

    export BUILDS="$builds"
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

@test "S4: e2e_builds is filtered from the pre-split builds union for changed sslh only" {
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

@test "S5: non-enabled changed container produces empty e2e_builds" {
    builds=$(jq -cn '
      [
        {"container":"wordpress","version":"6.5.0","tag":"latest-6.5.0","is_default":true,"is_latest_version":true,"os":"linux","runner":"ubuntu-latest"}
      ]')

    run_split_build_engine_step "$builds"

    [ "$status" -eq 0 ]
    e2e_builds=$(output_value e2e_builds)
    [ "$e2e_builds" = "[]" ]
}
