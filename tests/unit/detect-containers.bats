#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    export CONTAINER_SCOPES_INPUT=""
}

teardown() {
    unset BASELINE_FAILED BASELINE_VALID CONTAINER_SCOPES_INPUT GITHUB_ACTION_PATH GITHUB_OUTPUT GITHUB_WORKSPACE RUNNER_TEMP TEST_BASE_SHA TEST_HEAD_SHA TEST_CHANGED_FILES
    teardown_temp_dir
}

make_classifier_workspace() {
    CLASSIFIER_WORKSPACE="$TEST_TEMP_DIR/workspace"
    local workspace="$CLASSIFIER_WORKSPACE"
    mkdir -p "$workspace"
    cp "$PROJECT_ROOT/make" "$workspace/"
    cp -a "$PROJECT_ROOT/helpers" "$PROJECT_ROOT/scripts" "$workspace/"
    mkdir -p "$workspace/postgres/extensions"
    cp "$PROJECT_ROOT/postgres/Dockerfile" "$workspace/postgres/"
    cp "$PROJECT_ROOT/postgres/variants.yaml" "$workspace/postgres/"
    cp -a "$PROJECT_ROOT/postgres/extensions/config.yaml" "$workspace/postgres/extensions/"

    git -C "$workspace" init -q
    git -C "$workspace" config user.email tests@example.invalid
    git -C "$workspace" config user.name tests
    git -C "$workspace" add .
    git -C "$workspace" commit -qm baseline
    export TEST_BASE_SHA
    TEST_BASE_SHA=$(git -C "$workspace" rev-parse HEAD)
    export TEST_HEAD_SHA="$TEST_BASE_SHA"
}

run_find_containers_step() {
    local changed_files="$1"
    local workspace="$2"
    local script="$TEST_TEMP_DIR/find-containers.sh"

    yq -r '.runs.steps[] | select(.id == "find-containers") | .run' \
        "$PROJECT_ROOT/.github/actions/detect-containers/action.yaml" > "$script"

    # Render the pull-request context and substitute the diff provider with the
    # changed-files fixture.  The temporary workspace is a real git repository,
    # so the classifier compares its baseline config with the working-tree one.
    perl -0pi -e '
        s/\$\{\{ github\.event_name \}\}/pull_request/g;
        s/\$\{\{ github\.event\.pull_request\.base\.sha \}\}/\$TEST_BASE_SHA/g;
        s/\$\{\{ github\.event\.pull_request\.head\.sha \}\}/\$TEST_HEAD_SHA/g;
        s/\$\{\{ inputs\.container \}\}//g;
        s|(source "\$\{GITHUB_ACTION_PATH\}/\.\./\.\./\.\./helpers/pr-changed-files\.sh")|$1\npr_changed_files() { printf "%s\\n" "\${TEST_CHANGED_FILES}"; }|;
    ' "$script"

    # Used only for the requested discrimination proof: the production source
    # remains untouched while this generated classifier script has attribution
    # removed, making its refusal assertions fail.
    if [[ "${DISABLE_EXTENSION_ATTRIBUTION:-false}" == "true" ]]; then
        perl -0pi -e 's/extension_scope=\$\(extension_scope_for_changes \\\n+\s+"\$changed_files" \\\n+\s+"\$extension_config_base_file" \\\n+\s+"\$GITHUB_WORKSPACE\/postgres\/extensions\/config\.yaml"\)/extension_scope=""/g' "$script"
    fi

    export BASELINE_FAILED="[]"
    export BASELINE_VALID="false"
    export GITHUB_ACTION_PATH="$PROJECT_ROOT/.github/actions/detect-containers"
    export GITHUB_OUTPUT="$TEST_TEMP_DIR/github-output"
    export GITHUB_WORKSPACE="$workspace"
    export RUNNER_TEMP="$TEST_TEMP_DIR"
    export TEST_CHANGED_FILES="$changed_files"

    run bash -c 'cd "$1" || exit 1; exec bash "$2"' _ "$workspace" "$script"
}

output_value() {
    local name="$1"
    sed -n "s/^${name}=//p" "$GITHUB_OUTPUT" | tail -1
}

assert_extension_scope() {
    local changed_files="$1"
    local expected_scope="$2"
    local expected_force="$3"
    local workspace="${4:-}"
    if [[ -z "$workspace" ]]; then
        make_classifier_workspace
        workspace="$CLASSIFIER_WORKSPACE"
    fi

    run_find_containers_step "$changed_files" "$workspace"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = '["postgres"]' ]
    [ "$(output_value force_extension_builds)" = "$expected_force" ]
    if [[ "$expected_scope" == "all" ]]; then
        [ "$(output_value container_scopes)" = '{"postgres":{}}' ]
    else
        [ "$(output_value container_scopes | jq -r '.postgres.extensions // ""')" = "$expected_scope" ]
    fi
}

@test "changed extension recipe emits hypopg scope and forces compilation" {
    assert_extension_scope "postgres/extensions/build/hypopg.Dockerfile" "hypopg" "true"
}

@test "changed declared extension version scopes and forces that extension" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    yq -i '.extensions.hypopg.version = "1.4.4"' "$workspace/postgres/extensions/config.yaml"
    run_find_containers_step "postgres/extensions/config.yaml" "$workspace"

    [ "$status" -eq 0 ]
    [ "$(output_value container_scopes | jq -r '.postgres.extensions')" = "hypopg" ]
    [ "$(output_value force_extension_builds)" = "true" ]
}

@test "changed declared rust version scopes and forces that extension" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    yq -i '.extensions.paradedb.rust_version = "1.96.1"' "$workspace/postgres/extensions/config.yaml"
    run_find_containers_step "postgres/extensions/config.yaml" "$workspace"

    [ "$status" -eq 0 ]
    [ "$(output_value container_scopes | jq -r '.postgres.extensions')" = "paradedb" ]
    [ "$(output_value force_extension_builds)" = "true" ]
}

@test "changed shared extension config fans out and forces every extension" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    yq -i '.base_variant = "debian"' "$workspace/postgres/extensions/config.yaml"
    assert_extension_scope "postgres/extensions/config.yaml" "all" "true" "$workspace"
}

@test "changed resolver fans out and forces every extension" {
    assert_extension_scope "scripts/resolvers/timescaledb-ha.sh" "all" "true"
}

@test "changed extension helper fans out and forces every extension" {
    assert_extension_scope "helpers/extension-utils.sh" "all" "true"
}

@test "flavor-only extension config change rebuilds postgres without forced compilation" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    yq -i '.flavors.vector += ["hypopg"]' "$workspace/postgres/extensions/config.yaml"
    run_find_containers_step "postgres/extensions/config.yaml" "$workspace"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = '["postgres"]' ]
    [ -z "$(output_value container_scopes)" ]
    [ "$(output_value force_extension_builds)" = "false" ]
}

@test "unparseable extension config fails closed to every extension" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    printf '\ninvalid: [\n' >> "$workspace/postgres/extensions/config.yaml"
    assert_extension_scope "postgres/extensions/config.yaml" "all" "true" "$workspace"
}

@test "unexpected extension config shape fails closed to every extension" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    yq -i '.extensions = []' "$workspace/postgres/extensions/config.yaml"
    assert_extension_scope "postgres/extensions/config.yaml" "all" "true" "$workspace"
}

@test "unknown extension recipe fails closed to every extension" {
    assert_extension_scope "postgres/extensions/build/not-a-known-extension.Dockerfile" "all" "true"
}

@test "unrelated postgres README emits neither extension scope nor force signal" {
    make_classifier_workspace
    workspace="$CLASSIFIER_WORKSPACE"
    run_find_containers_step "postgres/README.md" "$workspace"

    [ "$status" -eq 0 ]
    [ "$(output_value containers)" = "[]" ]
    [ -z "$(output_value container_scopes)" ]
    [ "$(output_value force_extension_builds)" = "false" ]
}
