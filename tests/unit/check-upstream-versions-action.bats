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
    # GitHub expands an input before Bash parses `run:`. Render the one input
    # expression only for this hermetic extraction so a regression that puts it
    # back in the body is tested in the same execution shape as a real runner.
    yq -r '.runs.steps[] | select(.id == "check-versions") | .run' \
        .github/actions/check-upstream-versions/action.yaml |
        sed "s#\${{ inputs.container }}#$requested_container#g" > run-check-versions.sh
    chmod +x run-check-versions.sh
    : > "$output_file"
    REQUESTED_CONTAINER="$requested_container" \
        EXPECTED_CONTAINER="$requested_container" \
        GITHUB_OUTPUT="$output_file" bash ./run-check-versions.sh
    local action_status=$?
    cat "$output_file"
    return "$action_status"
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
    local marker="$TEST_DIR/executed"
    local hostile_container hostile_version result
    hostile_container='victim'\''$(touch '"$marker"')'\''x`:`'
    hostile_version='v1'\''$(touch '"$marker"')'\''x`:`'
    result=$(jq -cn \
        --arg container "$hostile_container" \
        --arg version "$hostile_version" \
        '[{container: $container, current_version: "1.0.0", latest_version: $version, update_available: true, actionable: true, registry_lookup: "matched", status: "update-available"}]')
    write_make_result "$result"

    run run_action "$hostile_container"
    [ "$status" -eq 0 ]
    [[ "$output" == *"update_count=1"* ]]
    [ ! -e "$marker" ]
}

@test "composite action excludes an entry whose registry lookup failed" {
    write_make_result '[{"container":"sslh","current_version":"","latest_version":"v2.3.1-alpine","update_available":false,"actionable":false,"registry_lookup":"failed","status":"registry-lookup-failed"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"Registry lookup did not conclude"* ]]
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
