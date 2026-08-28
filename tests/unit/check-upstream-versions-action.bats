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

    # GitHub evaluates inputs before Bash sees the run block. In this hermetic
    # invocation, replace the optional container expression with an empty value
    # and execute the composite action's otherwise-unmodified script.
    yq -r '.runs.steps[] | select(.id == "check-versions") | .run' \
        .github/actions/check-upstream-versions/action.yaml |
        sed 's#${{ inputs.container }}##g' > run-check-versions.sh
    chmod +x run-check-versions.sh
}

teardown() {
    cd "$ORIG_DIR" || true
    rm -rf "$TEST_DIR"
}

write_make_result() {
    local result="$1"
    cat > make <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "check-updates" ]]; then
  printf '%s\\n' '$result'
fi
EOF
    chmod +x make
}

run_action() {
    local output_file="$TEST_DIR/github-output"
    : > "$output_file"
    GITHUB_OUTPUT="$output_file" bash ./run-check-versions.sh
    cat "$output_file"
}

@test "composite action excludes declared non-actionable updates" {
    write_make_result '[{"container":"postgres","current_version":"","latest_version":"18.6-alpine","update_available":true,"actionable":false,"registry_lookup":"no-match","status":"new-container"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"update_count=0"* ]]
}

@test "composite action fails closed when actionable is absent" {
    write_make_result '[{"container":"future-container","current_version":"1.0.0","latest_version":"1.1.0","update_available":true,"status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"update_count=0"* ]]
}

@test "composite action fails closed when actionable is the string true" {
    write_make_result '[{"container":"string-actionable","current_version":"1.0.0","latest_version":"1.1.0","update_available":true,"actionable":"true","registry_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"update_count=0"* ]]
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

@test "composite action excludes an entry whose registry lookup failed" {
    write_make_result '[{"container":"sslh","current_version":"","latest_version":"v2.3.1-alpine","update_available":false,"actionable":false,"registry_lookup":"failed","status":"registry-lookup-failed"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *"containers_with_updates=[]"* ]]
    [[ "$output" == *"Registry lookup did not conclude"* ]]
}
