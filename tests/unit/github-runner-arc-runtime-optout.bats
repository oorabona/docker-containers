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
