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
# r25-B / r27-C: idempotent same-day section — content-hash dedupe
#
# Gate r25, Defect B introduced skip-if-present on the section heading.
# Gate r27, Defect C replaces heading-only dedupe with content-hash dedupe:
# the heading alone caused a false negative when a second legitimate drift
# event (different variants) occurred on the same UTC day after the first
# drift PR had already been merged → script skipped → no rebuild trigger.
#
# Fix: embed <!-- drift-content-hash: <16-hex> --> above the heading.
# Same content → same hash → idempotent skip preserved.
# Different content → different hash → both sections appended.
# ---------------------------------------------------------------------------

# Helper: build a hermetic fake project directory for r25-B / r27-C tests.
# Uses _ULR_PROJECT_ROOT_OVERRIDE and _ULR_VALID_CONTAINERS_OVERRIDE test hooks to
# avoid spawning the real ./make or writing into the real project tree.
_setup_r25b_project() {
    local base="$TEST_TEMP_DIR/r25b"
    mkdir -p "$base/mycontainer"

    # Drift JSON for mycontainer with one drifted variant (content-A)
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

# Helper: second distinct drift JSON (content-B) for same container + same day.
# Uses a different variant tag and digests to produce a different content-hash.
_setup_r27c_project_b() {
    local base="$1"
    printf '%s' '[
      {
        "container": "mycontainer",
        "variants": [
          {
            "variant_tag": "2.0",
            "base_image_ref": "alpine:3.21",
            "recorded_digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "current_digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "status": "drift"
          }
        ]
      }
    ]' > "$base/drift-b.json"
}

@test "r25-B1: running script twice same day with IDENTICAL drift produces exactly one section" {
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

    # Second run (simulates workflow retry with same content)
    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift.json" 2>/dev/null

    local target="$fake_project/mycontainer/LAST_REBUILD.md"
    [ -f "$target" ]

    # Count occurrences of the heading — must be exactly 1 (idempotency preserved)
    local count
    count=$(grep -cxF -- "$heading" "$target")
    [ "$count" -eq 1 ]
}

@test "r25-B1-notice: second run with same content emits ::notice:: about skipping" {
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
    # r27-C: skip message changed from "already present" to "already recorded"
    printf '%s' "$stderr_output" | grep -qF "already recorded"
}

# ---------------------------------------------------------------------------
# r27-C: two invocations same day with DIFFERENT drift content → 2 sections
# Regression test for the false-negative path Copilot identified:
# drift A merges in the morning → LAST_REBUILD.md updated → rebuild →
# drift B (different variants) occurs same day → r25 heading-only dedupe
# would skip → no file change → no PR trigger → silent false negative.
# With content-hash dedupe the different-content event appends a new section.
# ---------------------------------------------------------------------------
@test "r27-C1: same day different drift content produces two distinct sections" {
    local fake_project
    fake_project=$(_setup_r25b_project)
    _setup_r27c_project_b "$fake_project"

    local kind="base-digest-drift"
    local today
    today="$(date -u +%Y-%m-%d)"
    local heading="## ${kind} (${today})"

    # First run — drift event A (variant 1.0)
    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift.json" 2>/dev/null

    # Second run — drift event B (variant 2.0, different digests)
    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift-b.json" 2>/dev/null

    local target="$fake_project/mycontainer/LAST_REBUILD.md"
    [ -f "$target" ]

    # Both headings must be present (2 sections for same-day different events)
    local count
    count=$(grep -cxF -- "$heading" "$target")
    [ "$count" -eq 2 ]

    # Two distinct hash markers must be present
    local hash_count
    hash_count=$(grep -c 'drift-content-hash:' "$target")
    [ "$hash_count" -eq 2 ]
}

@test "r27-C2: first section contains hash marker above the heading" {
    local fake_project
    fake_project=$(_setup_r25b_project)

    local kind="base-digest-drift"

    _ULR_PROJECT_ROOT_OVERRIDE="$fake_project" \
    _ULR_VALID_CONTAINERS_OVERRIDE="mycontainer" \
        bash "$UPDATE_SCRIPT" "mycontainer" "$kind" \
        < "$fake_project/drift.json" 2>/dev/null

    local target="$fake_project/mycontainer/LAST_REBUILD.md"
    [ -f "$target" ]

    # File must contain an HTML comment with the hash marker
    grep -qF '<!-- drift-content-hash:' "$target"
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
