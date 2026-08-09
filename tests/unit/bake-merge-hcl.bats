#!/usr/bin/env bats
# Unit tests for scripts/bake-merge-hcl.sh.

load "../test_helper"

setup() {
    export PROJECT_ROOT
    setup_temp_dir
    export MERGE_HCL="${PROJECT_ROOT}/scripts/bake-merge-hcl.sh"
}

teardown() {
    teardown_temp_dir
}

_write_doc() {
    local path="$1"
    local targets="$2"
    local defaults="$3"
    jq -cn --argjson targets "$targets" --argjson defaults "$defaults" \
        '{variable: {}, target: $targets, group: {default: {targets: $defaults}}}' > "$path"
}

@test "merge refuses a shared target key with a different definition" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" \
        "$(jq -cn '{shared: {context: "one"}}')" \
        "$(jq -cn '["shared"]')"
    _write_doc "$retained" \
        "$(jq -cn '{shared: {context: "two"}}')" \
        "$(jq -cn '["shared"]')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 1 ]
    [[ "$output" == *"shared"* ]]
}

@test "merge keeps all targets and ordered unique default targets when shared definitions agree" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" \
        "$(jq -cn '{shared: {context: "same"}, latest_only: {context: "latest"}}')" \
        "$(jq -cn '["shared", "latest_only"]')"
    _write_doc "$retained" \
        "$(jq -cn '{shared: {context: "same"}, retained_only: {context: "retained"}}')" \
        "$(jq -cn '["shared", "retained_only"]')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
        (.target | keys | sort) == ["latest_only", "retained_only", "shared"]
        and .group.default.targets == ["shared", "latest_only", "retained_only"]
    ' >/dev/null
}
