#!/usr/bin/env bats

# Unit tests for scripts/update-last-rebuild.sh
#
# Focused on the gate r21 regression: container name option injection
# (grep without -- separator) at line 68.

load "../test_helper"

UPDATE_SCRIPT=""

setup() {
    setup_temp_dir
    UPDATE_SCRIPT="${SCRIPTS_DIR}/update-last-rebuild.sh"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# r21-A3: grep option injection — container name '--help' as CLI arg
# update-last-rebuild.sh calls `grep -qxF "$CONTAINER"` at line 68.
# Without `--`, passing '--help' as $1 causes grep to print help and exit 0,
# bypassing the container validation entirely.
# Mutation guard: removing `--` from the grep call → grep treats '--help' as
# option → exits 0 → script proceeds past validation with the poisoned name.
# ---------------------------------------------------------------------------
@test "r21-A3: container name '--help' is rejected as invalid (not a grep option)" {
    # Create a fake ./make script that returns a valid container list
    local fake_project="$TEST_TEMP_DIR/project"
    mkdir -p "$fake_project"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "foo"' 'echo "bar"' > "$fake_project/make"
    chmod +x "$fake_project/make"

    # Run the script with container='--help'; it should reject and exit 0
    local rc=0
    (
        cd "$fake_project"
        printf '[]' | bash "$UPDATE_SCRIPT" "--help" "base-digest-drift"
    ) 2>"$TEST_TEMP_DIR/r21a3-stderr.txt" || rc=$?

    # Exit 0: container not found is a warning (skip), not fatal
    [ "$rc" -eq 0 ]

    # Must emit a warning that the container is invalid
    grep -q "not a valid container" "$TEST_TEMP_DIR/r21a3-stderr.txt"
}

@test "r21-A3b: container name '-n' is rejected as invalid (not a grep option)" {
    local fake_project="$TEST_TEMP_DIR/project"
    mkdir -p "$fake_project"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "foo"' > "$fake_project/make"
    chmod +x "$fake_project/make"

    local rc=0
    (
        cd "$fake_project"
        printf '[]' | bash "$UPDATE_SCRIPT" "-n" "base-digest-drift"
    ) 2>"$TEST_TEMP_DIR/r21a3b-stderr.txt" || rc=$?

    [ "$rc" -eq 0 ]
    grep -q "not a valid container" "$TEST_TEMP_DIR/r21a3b-stderr.txt"
}
