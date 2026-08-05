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

# A workspace holding exactly one container, which ships a test.sh and opts into
# nothing. Pointing the step at this instead of at the repository is what stops a
# test about "a container with no e2e" from depending on which containers happen
# to have opted in — a dependency that has already invalidated it once, when the
# real container it named was enabled.
make_scratch_workspace_with_unopted_container() {
    local ws="$TEST_TEMP_DIR/ws"
    mkdir -p "$ws/unopted"
    cp "$PROJECT_ROOT/make" "$ws/"
    cp -r "$PROJECT_ROOT/helpers" "$PROJECT_ROOT/scripts" "$ws/"
    : > "$ws/unopted/Dockerfile"
    printf 'versions:\n  - tag: "1.0"\n' > "$ws/unopted/variants.yaml"
    : > "$ws/unopted/test.sh"
    printf '%s' "$ws"
}

run_find_containers_step() {
    local changed_files="$1"
    local workspace="${2:-$PROJECT_ROOT}"
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
    export GITHUB_WORKSPACE="$workspace"
    export RUNNER_TEMP="$TEST_TEMP_DIR"
    export TEST_CHANGED_FILES="$changed_files"

    # The step reads `$container/variants.yaml` relative to the working
    # directory and uses GITHUB_WORKSPACE only for `./make list`, so the
    # workspace has to be the working directory too. With the default it is the
    # repository root, which is where these tests already ran.
    run bash -c 'cd "$1" || exit 1; exec bash "$2"' _ "$workspace" "$script"
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

@test "deleting entrypoint classification would rebuild an image for a test-script edit" {
    # <container>/test.sh is what the harness actually runs. It sits beside the
    # Dockerfile, which is what used to make it a build input; no image copies it.
    run_find_containers_step "sslh/test.sh"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ "$(output_value containers_to_verify)" = '["sslh"]' ]
}

@test "deleting the one-level guard would cancel the build of a nested script" {
    # A case glob spans slashes, so */test.sh also matches a nested path. That
    # file may well be copied into the image; classing it as verification would
    # suppress the build it needs, silently.
    run_find_containers_step "sslh/scripts/test.sh"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = '["sslh"]' ]
    [ "$(output_value containers_to_verify)" = "[]" ]
}

@test "a test.sh outside any container is neither built nor verified" {
    run_find_containers_step "examples/wordpress-stack/test.sh"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ "$(output_value containers_to_verify)" = "[]" ]
}

@test "deleting the entrypoint opt-in check would verify a container with no e2e" {
    # The fixture is a workspace this test builds, not a container that happens
    # to be off today. Every container in the repository that ships a test.sh
    # now opts in — openresty, vector and postgres were the last three — so
    # naming one of them here was a dependency on a state that no longer exists
    # and would go stale again the moment the next one flipped.
    local ws
    ws=$(make_scratch_workspace_with_unopted_container)
    run_find_containers_step "unopted/test.sh" "$ws"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ "$(output_value containers_to_verify)" = "[]" ]
}

@test "deleting the subtraction would verify a container its own source change already builds" {
    run_find_containers_step $'sslh/Dockerfile\nsslh/test.sh'

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = '["sslh"]' ]
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

@test "deleting assertion-library fanout would let a harness regression pass every suite silently" {
    # Every opted-in suite sources this library and its return code IS their
    # verdict, so a regression here can turn all of them green without touching
    # a container. It must fan out exactly like the shared runner above.
    run_find_containers_step "test-harness/test-harness.sh"

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
