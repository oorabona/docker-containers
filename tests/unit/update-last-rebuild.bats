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

# ---------------------------------------------------------------------------
# r25-B: idempotent same-day section — skip-if-present (gate r25, Defect B)
# Running the script twice for the same container on the same day must not
# produce duplicate ## base-digest-drift sections in LAST_REBUILD.md, because
# compute_build_digest hashes the file and each duplicate would retrigger CI.
# ---------------------------------------------------------------------------

# Helper: build a hermetic fake project directory for r25-B tests.
# Uses _ULR_PROJECT_ROOT_OVERRIDE and _ULR_VALID_CONTAINERS_OVERRIDE test hooks to
# avoid spawning the real ./make or writing into the real project tree.
_setup_r25b_project() {
    local base="$TEST_TEMP_DIR/r25b"
    mkdir -p "$base/mycontainer"

    # Drift JSON for mycontainer with one drifted variant
    printf '%s' '[
      {
        "container": "mycontainer",
        "variants": [
          {
            "variant_tag": "1.0",
            "base_image_ref": "alpine:3.21",
            "recorded_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "current_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "status": "drift"
          }
        ]
      }
    ]' > "$base/drift.json"

    printf '%s' "$base"
}

@test "r25-B1: running script twice same day produces exactly one section in LAST_REBUILD.md" {
    local fake_project
    fake_project=$(_setup_r25b_project)

    local kind="base-digest-drift"
    local today
    today="$(date -u +%Y-%m-%d)"
    local heading="## ${kind} (${today})"

    # First run — uses test hooks to bypass ./make and real PROJECT_ROOT
    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift.json" 2>/dev/null

    # Second run (simulates workflow retry)
    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift.json" 2>/dev/null

    local target="$fake_project/mycontainer/LAST_REBUILD.md"
    [ -f "$target" ]

    # Count occurrences of the heading — must be exactly 1
    local count
    count=$(grep -cxF -- "$heading" "$target")
    [ "$count" -eq 1 ]
}

@test "r25-B1-notice: second run emits ::notice:: about skipping" {
    local fake_project
    fake_project=$(_setup_r25b_project)

    local kind="base-digest-drift"

    # First run (creates section)
    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift.json" 2>/dev/null

    # Second run — capture stderr
    local stderr_output rc=0
    stderr_output=$(
        _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
        _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
            bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
            < "$fake_project/drift.json" 2>&1 >/dev/null
    ) || rc=$?

    [ "$rc" -eq 0 ]
    printf '%s' "$stderr_output" | grep -qF "already present"
}

@test "r25-B2: warning emission for invalid container escapes %0A via _escape_gha_command" {
    # Gate r25, Defect A applied to update-last-rebuild.sh:
    # a container name containing literal %0A must appear as %250A in the
    # warning (% encoded to %25 first, then 0A suffix), not as a raw sequence
    # that injects a new GHA command.
    local stderr_output rc=0
    stderr_output=$(
        _ULR_VALID_CONTAINERS_OVERRIDE="goodcontainer" \
            bash "$UPDATE_SCRIPT" "bad%0Acontainer" "base-digest-drift" \
            < /dev/null 2>&1 >/dev/null
    ) || rc=$?

    [ "$rc" -eq 0 ]

    # The warning line must contain the escaped form %250A (% encoded first)
    printf '%s' "$stderr_output" | grep -qF '%250A'
    # Must NOT contain a line that starts with ::add-mask:: or similar injected command
    ! printf '%s' "$stderr_output" | grep -qE '^::add-mask::|^::set-env::|^::set-output::'
}
