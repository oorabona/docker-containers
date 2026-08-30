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

assert_action_rejected() {
    local assertion="$1"

    [ "$status" -ne 0 ] || {
        printf 'ASSERTION FAILED: %s\nExpected: non-zero action status\nActual: %s\n' \
            "$assertion" "$status" >&2
        return 1
    }
    [[ "$output" == *"invalid or unauthorized version_info entry"* ]] || {
        printf 'ASSERTION FAILED: %s\nExpected invalid-entry diagnostic\nActual: %s\n' \
            "$assertion" "$output" >&2
        return 1
    }
    [[ "$output" != *"update_count="* ]] || {
        printf 'ASSERTION FAILED: %s\nMalformed record published outputs: %s\n' \
            "$assertion" "$output" >&2
        return 1
    }
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
    write_make_result '[{"container":"terraform","current_version":"1.15.9-alpine","latest_version":"1.16.0-alpine","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *'containers_with_updates=["terraform"]'* ]]
    [[ "$output" == *"update_count=1"* ]]
}

@test "composite action selects an actionable new container with a missing registry version" {
    write_make_result '[{"container":"new-postgres","current_version":"","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"no-match","upstream_lookup":"matched","status":"new-container"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *'containers_with_updates=["new-postgres"]'* ]]
    [[ "$output" == *"update_count=1"* ]]
}

@test "composite action rejects an actionable new container with a matched registry version" {
    write_make_result '[{"container":"postgres","current_version":"16.0","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"new-container"}]'

    run run_action
    assert_action_rejected "new-container must have no registry match and no current version"
}

@test "composite action rejects an actionable update with no registry version" {
    write_make_result '[{"container":"postgres","current_version":"","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"no-match","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    assert_action_rejected "update-available must have a registry match and a current version"
}

@test "composite action rejects an actionable record without versions" {
    write_make_result '[{"container":"postgres","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    assert_action_rejected "actionable records without current and latest versions must fail before the monitor can classify null"
}

@test "composite action rejects an actionable record without a current version" {
    write_make_result '[{"container":"postgres","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    assert_action_rejected "actionable records require a string current_version"
}

@test "composite action rejects an actionable record with an empty latest version" {
    write_make_result '[{"container":"postgres","current_version":"16.0","latest_version":"","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    assert_action_rejected "actionable records require a non-empty latest_version"
}

@test "composite action rejects unusable or unchanged actionable update versions" {
    local name latest_version
    local -a cases=(
        'null-sentinel|null'
        'unchanged|1.0'
        'unknown-sentinel|unknown'
        'latest-sentinel|latest'
    )

    for case_data in "${cases[@]}"; do
        IFS='|' read -r name latest_version <<< "$case_data"
        write_make_result "[{\"container\":\"postgres\",\"current_version\":\"1.0\",\"latest_version\":\"$latest_version\",\"update_available\":true,\"actionable\":true,\"registry_lookup\":\"matched\",\"upstream_lookup\":\"matched\",\"status\":\"update-available\"}]"

        run run_action
        assert_action_rejected "$name update versions must be usable and distinct"
    done
}

@test "composite action selects an actionable update with distinct usable versions" {
    write_make_result '[{"container":"postgres","current_version":"1.0","latest_version":"1.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *'containers_with_updates=["postgres"]'* ]]
    [[ "$output" == *"update_count=1"* ]]
}

@test "composite action rejects an actionable record whose status disagrees with authorization" {
    write_make_result '[{"container":"postgres","current_version":"16.0","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"up_to_date"}]'

    run run_action
    assert_action_rejected "an actionable record must use a monitor-actionable status"
}

@test "composite action rejects duplicate downstream operation identities" {
    write_make_result '[{"container":"postgres","current_version":"16.0","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"},{"container":"postgres:","current_version":"16.0","latest_version":"16.2","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    assert_action_rejected "keys resolving to the same downstream operation must fail before two monitor PR operations race"
}

@test "composite action permits distinct downstream major-line identities" {
    write_make_result '[{"container":"postgres:16","current_version":"16.0","latest_version":"16.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"},{"container":"postgres:17","current_version":"17.0","latest_version":"17.1","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *'containers_with_updates=["postgres:16","postgres:17"]'* ]]
    [[ "$output" == *"update_count=2"* ]]
}

@test "composite action treats a hostile container name as data" {
    local hostile_container result
    hostile_container='victim'\''$(touch container-expression-executed)'\''`touch container-backtick-executed`; && | $IFS'
    result=$(jq -cn \
        --arg container "$hostile_container" \
        '[{container: $container, current_version: "1.0.0", latest_version: "2.0.0-alpine", update_available: true, actionable: true, registry_lookup: "matched", upstream_lookup: "matched", status: "update-available"}]')
    write_make_result "$result"

    run run_action "$hostile_container"
    [ "$status" -eq 0 ]
    [[ "$output" == *"update_count=1"* ]]
    assert_byte_for_byte "$result" "$(version_info_output)" "version_info must preserve the hostile record byte-for-byte"
    [ ! -e "$TEST_DIR/container-expression-executed" ]
    [ ! -e "$TEST_DIR/container-backtick-executed" ]
}

@test "composite action rejects actionable latest versions outside the Docker tag grammar" {
    local description latest_version result

    while IFS= read -r description; do
        case "$description" in
            newline) latest_version=$'2.0.0\nchange_type=minor' ;;
            carriage-return) latest_version=$'2.0.0\rchange_type=minor' ;;
            non-ascii) latest_version='é2.0' ;;
            whitespace) latest_version='2.0.0 alpine' ;;
            invalid-tag-character) latest_version='2.0.0+build' ;;
            too-long) latest_version=$(printf 'v%.0s' {1..129}) ;;
        esac
        result=$(jq -cn \
            --arg version "$latest_version" \
            '[{container: "postgres", current_version: "1.0.0", latest_version: $version, update_available: true, actionable: true, registry_lookup: "matched", upstream_lookup: "matched", status: "update-available"}]')
        write_make_result "$result"

        run run_action
        assert_action_rejected "$description latest_version must be a one-line Docker tag"
    done <<'CASES'
newline
carriage-return
non-ascii
whitespace
invalid-tag-character
too-long
CASES
}

@test "composite action rejects an actionable current version outside the Docker tag grammar" {
    local result
    result=$(jq -cn \
        --arg version $'1.0.0\nchange_type=minor' \
        '[{container: "postgres", current_version: $version, latest_version: "2.0.0-alpine", update_available: true, actionable: true, registry_lookup: "matched", upstream_lookup: "matched", status: "update-available"}]')
    write_make_result "$result"

    run run_action
    assert_action_rejected "current_version must be a one-line Docker tag"
}

@test "composite action accepts an actionable Docker-tag version" {
    write_make_result '[{"container":"postgres","current_version":"1.0.0","latest_version":"2.0.0-alpine","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"matched","status":"update-available"}]'

    run run_action
    [ "$status" -eq 0 ]
    [[ "$output" == *'containers_with_updates=["postgres"]'* ]]
    [[ "$output" == *"update_count=1"* ]]
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

@test "composite action rejects actionable entries whose upstream lookup failed" {
    write_make_result '[{"container":"failed-upstream","update_available":true,"actionable":true,"registry_lookup":"matched","upstream_lookup":"failed","status":"update-available"}]'

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

@test "composite action rejects an unrecognised status" {
    write_make_result '[{"container":"unknown-state","current_version":"1.0.0","latest_version":"1.1.0","update_available":false,"actionable":false,"registry_lookup":"matched","upstream_lookup":"matched","status":"future-failure-status"}]'

    run run_action
    assert_action_rejected "status must remain in make check-updates' closed vocabulary"
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
