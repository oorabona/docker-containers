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
    local variables="{}"
    local groups="{}"
    if [[ $# -ge 4 ]]; then
        variables="$4"
    fi
    if [[ $# -ge 5 ]]; then
        groups="$5"
    fi
    jq -cn \
        --argjson targets "$targets" \
        --argjson defaults "$defaults" \
        --argjson variables "$variables" \
        --argjson groups "$groups" \
        '{variable: $variables, target: $targets, group: ({default: {targets: $defaults}} + $groups)}' > "$path"
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

@test "merge keeps shared and retained-only variables" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "{}" "[]" \
        "$(jq -cn '{ARCH_SUFFIX: {default: ""}, NPROC: {default: "4"}}')"
    _write_doc "$retained" "{}" "[]" \
        "$(jq -cn '{ARCH_SUFFIX: {default: ""}, RETAINED_ONLY: {default: "yes"}}')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
        .variable == {
            ARCH_SUFFIX: {default: ""},
            NPROC: {default: "4"},
            RETAINED_ONLY: {default: "yes"}
        }
    ' >/dev/null
}

@test "merge refuses a shared variable key with a different definition" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "{}" "[]" "$(jq -cn '{NPROC: {default: "4"}}')"
    _write_doc "$retained" "{}" "[]" "$(jq -cn '{NPROC: {default: "8"}}')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 1 ]
    [[ "$output" == *"variable"* ]]
    [[ "$output" == *"NPROC"* ]]
}

@test "merge unions a colliding non-default group with latest members first" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "{}" "[]" "{}" \
        "$(jq -cn '{wordpress: {targets: ["latest", "shared"]}}')"
    _write_doc "$retained" "{}" "[]" "{}" \
        "$(jq -cn '{wordpress: {targets: ["shared", "retained"]}}')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.group.wordpress.targets')" = '["latest","shared","retained"]' ]
}

@test "merge refuses a colliding group that differs outside targets" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "{}" "[]" "{}" \
        "$(jq -cn '{wordpress: {targets: ["latest"], description: "one"}}')"
    _write_doc "$retained" "{}" "[]" "{}" \
        "$(jq -cn '{wordpress: {targets: ["retained"], description: "two"}}')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 1 ]
    [[ "$output" == *"group"* ]]
    [[ "$output" == *"wordpress"* ]]
}

@test "merge refuses an input containing two JSON documents" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "{}" "[]"
    _write_doc "$retained" "{}" "[]"
    printf '\n%s\n' '{"variable":{},"target":{},"group":{"default":{"targets":[]}}}' >> "$retained"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$retained"* ]]
}

@test "merge refuses an empty target key even when it would otherwise be a conflict" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "$(jq -cn '{"": {context: "one"}}')" "[]"
    _write_doc "$retained" "$(jq -cn '{"": {context: "two"}}')" "[]"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 1 ]
    [[ "$output" == *"target"* ]]
    [[ "$output" == *'""'* ]]
}

@test "merge accepts a nonblank group key containing a hyphen" {
    local latest retained
    latest="${TEST_TEMP_DIR}/latest.json"
    retained="${TEST_TEMP_DIR}/retained.json"
    _write_doc "$latest" "{}" "[]" "{}" \
        "$(jq -cn '{"web-shell": {targets: ["latest"]}}')"
    _write_doc "$retained" "{}" "[]" "{}" \
        "$(jq -cn '{"web-shell": {targets: ["retained"]}}')"

    run bash "$MERGE_HCL" "$latest" "$retained"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.group["web-shell"].targets')" = '["latest","retained"]' ]
}
