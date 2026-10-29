#!/usr/bin/env bats

load "../test_helper"

@test "ARC runtime opt-out preserves an inherited caller temporary directory" {
    local inherited_temp_dir sentinel

    inherited_temp_dir=$(mktemp -d "$BATS_TEST_TMPDIR/inherited-arc-temp.XXXXXX")
    sentinel="$inherited_temp_dir/caller-sentinel"
    touch "$sentinel"

    run env ARC_RUNTIME_TESTS=0 TEST_TEMP_DIR="$inherited_temp_dir" \
        bats "$PROJECT_ROOT/github-runner/tests/test-runner-arc.bats"

    [ "$status" -eq 0 ]
    [ "$(grep -c '# skip set ARC_RUNTIME_TESTS=1' <<< "$output")" -eq 5 ]
    [ -f "$sentinel" ]
}

@test "ARC runtime rejects a wrong image and preserves an inherited caller sentinel" {
    local inherited_temp_dir sentinel sibling_image

    inherited_temp_dir=$(mktemp -d "$BATS_TEST_TMPDIR/inherited-arc-temp.XXXXXX")
    sentinel="$inherited_temp_dir/caller-sentinel"
    sibling_image='ghcr.io/oorabona/github-runner:2.338.2-dev'
    touch "$sentinel"

    run env ARC_RUNTIME_TESTS=1 ARC_TEST_RUNTIME=podman ARC_TEST_IMAGE="$sibling_image" \
        TEST_TEMP_DIR="$inherited_temp_dir" \
        bats "$PROJECT_ROOT/github-runner/tests/test-runner-arc.bats"

    [ "$status" -ne 0 ]
    [[ "$output" == *"ARC_TEST_IMAGE must equal the ARC sample runner image: expected ghcr.io/oorabona/github-runner:2.338.2@sha256:9df91c26565854fc5966ff98285789787d8e4aad0c2e3f60bc4076432d2a1877, got $sibling_image"* ]]
    [ -f "$sentinel" ]
}
