#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    export CONTAINER_SCOPES_INPUT=""
}

teardown() {
    unset BASELINE_FAILED BASELINE_VALID CONTAINER_SCOPES_INPUT GITHUB_ACTION_PATH GITHUB_OUTPUT GITHUB_WORKSPACE RUNNER_TEMP TEST_CHANGED_FILES
    teardown_temp_dir
}

run_find_containers_step() {
    local changed_files="$1"
    local script="$TEST_TEMP_DIR/find-containers.sh"

    yq -r '.runs.steps[] | select(.id == "find-containers") | .run' \
        "$PROJECT_ROOT/.github/actions/detect-containers/action.yaml" > "$script"

    # The extracted composite-action script still contains GitHub expressions.
    # Render just enough pull-request context to exercise its classifier while
    # replacing the git helper with the controlled changed-file fixture.
    perl -0pi -e '
        s/\$\{\{ github\.event_name \}\}/pull_request/g;
        s/\$\{\{ github\.event\.pull_request\.base\.sha \}\}/base/g;
        s/\$\{\{ github\.event\.pull_request\.head\.sha \}\}/head/g;
        s/\$\{\{ inputs\.container \}\}//g;
        s|(source "\$\{GITHUB_ACTION_PATH\}/\.\./\.\./\.\./helpers/pr-changed-files\.sh")|$1\npr_changed_files() { printf "%s\\n" "\${TEST_CHANGED_FILES}"; }|;
    ' "$script"

    export BASELINE_FAILED="[]"
    export BASELINE_VALID="false"
    export GITHUB_ACTION_PATH="$PROJECT_ROOT/.github/actions/detect-containers"
    export GITHUB_OUTPUT="$TEST_TEMP_DIR/github-output"
    export GITHUB_WORKSPACE="$PROJECT_ROOT"
    export RUNNER_TEMP="$TEST_TEMP_DIR"
    export TEST_CHANGED_FILES="$changed_files"

    run bash "$script"
}

output_value() {
    local name="$1"
    sed -n "s/^${name}=//p" "$GITHUB_OUTPUT" | tail -1
}

@test "deleting container-test classification would make a changed e2e script run neither verification nor a build" {
    run_find_containers_step "sslh/tests/e2e.sh"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ "$(output_value containers_to_verify)" = '["sslh"]' ]
}

@test "deleting nested-test e2e opt-in classification would verify a non-enabled container" {
    run_find_containers_step "github-runner/tests/unit.bats"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ "$(output_value containers_to_verify)" = "[]" ]
}

@test "deleting shared-harness fanout would leave opted-in e2e suites unverified" {
    run_find_containers_step "tests/e2e-test.sh"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    actual=$(output_value containers_to_verify | jq -c 'sort')
    expected=$(for file in "$PROJECT_ROOT"/*/variants.yaml; do
        if [[ "$(yq -r '.tests.e2e.enabled // false' "$file")" == "true" ]]; then
            basename "$(dirname "$file")"
        fi
    done | jq -R . | jq -sc 'sort')
    [ "$actual" = "$expected" ]
}

@test "deleting verification subtraction would duplicate a container changed in both source and tests" {
    run_find_containers_step $'sslh/Dockerfile\nsslh/tests/e2e.sh'

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = '["sslh"]' ]
    [ "$(output_value containers_to_verify)" = "[]" ]
}

@test "deleting metadata exclusions would turn markdown and docs edits into builds or verification" {
    run_find_containers_step $'sslh/README.md\nsslh/docs/usage.md'

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ "$(output_value containers_to_verify)" = "[]" ]
}
