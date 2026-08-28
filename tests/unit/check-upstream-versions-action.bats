#!/usr/bin/env bats

# Exercises the composite action's real check-versions script with a fixture
# make entry point. The registry result is the only external dependency; the
# action's selection logic itself is not mocked.

setup() {
    TEST_DIR=$(mktemp -d)
    ORIG_DIR="$PWD"
    cd "$TEST_DIR" || exit 1

    mkdir -p .github/actions/check-upstream-versions
    cp "$ORIG_DIR/.github/actions/check-upstream-versions/action.yaml" \
        .github/actions/check-upstream-versions/action.yaml

}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

write_make_result() {
    local result="$1"
    MAKE_RESULT="$result"
    export MAKE_RESULT
    cat > make <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "check-updates" ]]; then
  if [[ -n "\${EXPECTED_CONTAINER:-}" && "\${2:-}" != "\$EXPECTED_CONTAINER" ]]; then
    printf 'unexpected requested container: %s\\n' "\${2:-}" >&2
    exit 1
  fi
  printf '%s\\n' "\$MAKE_RESULT"
fi
EOF
    chmod +x make
}

run_action() {
    local requested_container="${1:-}"
    local output_file="$TEST_DIR/github-output"
    yq -r '.runs.steps[] | select(.id == "check-versions") | .run' \
        .github/actions/check-upstream-versions/action.yaml > run-check-versions.sh
    chmod +x run-check-versions.sh
    : > "$output_file"
    REQUESTED_CONTAINER="$requested_container" \
        EXPECTED_CONTAINER="$requested_container" \
        GITHUB_OUTPUT="$output_file" bash ./run-check-versions.sh
    local action_status=$?
    cat "$output_file"
    return "$action_status"
}

version_info_output() {
    sed -n '/^version_info<<EOF$/,/^EOF$/ { /^version_info<<EOF$/d; /^EOF$/d; p; }' \
        "$TEST_DIR/github-output"
}

assert_byte_for_byte() {
    local expected="$1"
    local actual="$2"
    local assertion="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'ASSERTION FAILED: %s\nExpected: %s\nActual: %s\n' \
            "$assertion" "$expected" "$actual" >&2
        return 1
    fi
}

@test "the check-versions step binds REQUESTED_CONTAINER from its container input" {
    local container_binding
    container_binding=$(yq -r '.runs.steps[] | select(.id == "check-versions") | .env.REQUESTED_CONTAINER // ""' \
        .github/actions/check-upstream-versions/action.yaml)

    assert_byte_for_byte '${{ inputs.container }}' "$container_binding" \
        "REQUESTED_CONTAINER must bind from the container input"
}

@test "composite action excludes declared non-actionable updates" {
    write_make_result '[{"container":"postgres","current_version":"","latest_version":"18.6-alpine","update_available":true,"actionable":false,"registry_lookup":"no-match","status":"new-container"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"update_count=0"* ]]
}

@test "composite action rejects an entry when actionable is absent" {
    write_make_result '[{"container":"future-container","current_version":"1.0.0","latest_version":"1.1.0","update_available":true,"status":"update-available"}]'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count="* ]]
}

@test "composite action rejects an entry when actionable is the string true" {
    write_make_result '[{"container":"string-actionable","current_version":"1.0.0","latest_version":"1.1.0","update_available":true,"actionable":"true","registry_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count="* ]]
}

# Positive control for the two exclusion tests above. Without it a mutation that
# emptied containers_with_updates unconditionally would satisfy both of them.
@test "composite action selects an actionable update" {
    write_make_result '[{"container":"terraform","current_version":"1.15.9-alpine","latest_version":"1.16.0-alpine","update_available":true,"actionable":true,"registry_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *'containers_with_updates=["terraform"]'* ]]
    [[ "$output" == *"update_count=1"* ]]
}

@test "composite action treats hostile container and upstream version as data" {
    local hostile_container hostile_version result
    hostile_container='victim'\''$(touch container-expression-executed)'\''`touch container-backtick-executed`; && | $IFS'
    hostile_version='-v1'\''$(touch upstream-expression-executed)'\''`touch upstream-backtick-executed`; && | $IFS'
    result=$(jq -cn \
        --arg container "$hostile_container" \
        --arg version "$hostile_version" \
        '[{container: $container, current_version: "1.0.0", latest_version: $version, update_available: true, actionable: true, registry_lookup: "matched", status: "update-available"}]')
    write_make_result "$result"

    run run_action "$hostile_container"
    [ "$status" -eq 0 ]
    [[ "$output" == *"update_count=1"* ]]
    assert_byte_for_byte "$result" "$(version_info_output)" "version_info must preserve the hostile record byte-for-byte"
    [ ! -e "$TEST_DIR/container-expression-executed" ]
    [ ! -e "$TEST_DIR/container-backtick-executed" ]
    [ ! -e "$TEST_DIR/upstream-expression-executed" ]
    [ ! -e "$TEST_DIR/upstream-backtick-executed" ]
}

@test "composite action excludes an entry whose registry lookup failed" {
    write_make_result '[{"container":"sslh","current_version":"","latest_version":"v2.3.1-alpine","update_available":false,"actionable":false,"registry_lookup":"failed","status":"registry-lookup-failed"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"Registry lookup did not conclude"* ]]
}

@test "composite action reports an upstream lookup failure without claiming it is up to date" {
    write_make_result '[{"container":"ansible","current_version":"1.0.0-ubuntu","latest_version":"","update_available":false,"actionable":false,"registry_lookup":"matched","upstream_lookup":"failed","status":"upstream-lookup-failed"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"Upstream lookup did not conclude"* ]]
    [[ "$output" != *"✅ Up to date"* ]]
}

@test "composite action reports an upstream no-match without claiming it is up to date" {
    write_make_result '[{"container":"ansible","current_version":"1.0.0-ubuntu","latest_version":"","update_available":false,"actionable":false,"registry_lookup":"matched","upstream_lookup":"no-match","status":"upstream-no-match"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"Upstream lookup returned no version"* ]]
    [[ "$output" != *"✅ Up to date"* ]]
}

@test "composite action reports an indeterminate version comparison without claiming it is up to date" {
    write_make_result '[{"container":"debian","current_version":"trixie","latest_version":"bookworm","update_available":false,"actionable":false,"registry_lookup":"matched","status":"downgrade-guard-failed"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"Version comparison did not conclude"* ]]
    [[ "$output" != *"✅ Up to date"* ]]
}

@test "composite action reports a rejected upstream value without claiming it is up to date" {
    write_make_result '[{"container":"ansible","current_version":"","latest_version":"error: rate limited","update_available":false,"actionable":false,"registry_lookup":"no-match","status":"upstream-version-rejected"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not match the declared version pattern"* ]]
    [[ "$output" != *"✅ Up to date"* ]]
}

@test "composite action rejects an entry without a container" {
    write_make_result '[{"actionable":true,"update_available":true,"registry_lookup":"matched"}]'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count="* ]]
}

@test "composite action rejects actionable entries without an available update" {
    write_make_result '[{"container":"contradiction","update_available":false,"actionable":true,"registry_lookup":"matched"}]'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count="* ]]
}

@test "composite action rejects actionable entries whose lookup did not conclude" {
    write_make_result '[{"container":"failed-lookup","update_available":true,"actionable":true,"registry_lookup":"failed"}]'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count="* ]]
}

@test "composite action rejects actionable entries without a concluded lookup" {
    write_make_result '[{"container":"missing-lookup","update_available":true,"actionable":true}]'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count="* ]]
}

@test "composite action reports zero updates for a well-formed empty array" {
    write_make_result '[]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"update_count=0"* ]]
}

@test "composite action fails when check-updates emits truncated JSON" {
    write_make_result '[{"container":"truncated"'

    run run_action
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]]
    [[ "$output" != *"update_count=0"* ]]
}
