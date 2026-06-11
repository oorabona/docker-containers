#!/usr/bin/env bats

# Unit tests for expand_template() in helpers/template-utils.sh
#
# Covers:
#   (a) Successful expansion — including the case where the LAST marker's
#       replacement is EMPTY AND is the LAST LINE of the template — must
#       return exit 0 (previously returned 1).
#   (b) Genuine error (nonexistent template file) must return non-zero.
#
# RED→GREEN contract:
#   Case (a2) was RED before the fix: expand_template returned 1 when the
#   last line of the template was a marker line with an empty replacement.
#   The `[[ -n "" ]] && printf ...` construct evaluates to 1 (the [[
#   condition is false → && short-circuits → last exit status is 1 from [[).
#   This is triggered by the postgres Dockerfile.template pattern where
#   @@RUNTIME_DEPS@@ is the last line and is empty when no extensions have
#   runtime deps.
#   Case (b) was already GREEN (return 1 on missing file).

load "../test_helper"

# ---------------------------------------------------------------------------
# Source the helper under test
# ---------------------------------------------------------------------------
setup() {
    setup_temp_dir

    # Source template-utils into the test environment
    # shellcheck disable=SC1091
    source "$HELPERS_DIR/template-utils.sh"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helper: write minimal Dockerfile templates
# ---------------------------------------------------------------------------

# Template where the LAST LINE is a marker (triggers the bug when empty)
_make_template_marker_last() {
    local file="$1"
    python3 -c "
with open('$file', 'w') as f:
    f.write('ARG VERSION\n# @@BLOCK_A@@\nFROM postgres:\${VERSION}\n# @@BLOCK_B@@\n')
"
}

# Template where a passthrough line comes AFTER the last marker (bug not triggered)
_make_template_passthrough_last() {
    local file="$1"
    python3 -c "
with open('$file', 'w') as f:
    f.write('ARG VERSION\n# @@BLOCK_A@@\nFROM postgres:\${VERSION}\n# @@BLOCK_B@@\nCMD [\"postgres\"]\n')
"
}

# ---------------------------------------------------------------------------
# (a1) Successful expansion: last marker (last line) replacement NON-EMPTY → 0
# ---------------------------------------------------------------------------
@test "expand_template: success with non-empty last marker on last line → exit 0" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_marker_last "$tpl"

    run expand_template "$tpl" \
        "BLOCK_A" $'FROM builder AS stage1\n' \
        "BLOCK_B" "COPY --from=stage1 /out /app"

    [ "$status" -eq 0 ]
    echo "$output" | grep -Fqx 'FROM builder AS stage1'
    echo "$output" | grep -Fqx 'COPY --from=stage1 /out /app'
}

# ---------------------------------------------------------------------------
# (a2) Successful expansion: last marker is LAST LINE and replacement is EMPTY
#      → must return exit 0.
#
# RED before fix: `[[ -n "" ]] && printf ...` → [[]] exits 1, && short-
# circuits, last exit status of loop body = 1.  Function returned 1.
# GREEN after fix: success path ends with an explicit `return 0`.
# ---------------------------------------------------------------------------
@test "expand_template: EMPTY replacement on last-line marker → exit 0 [was RED]" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_marker_last "$tpl"

    # BLOCK_B is the last line; empty replacement triggers the spurious-1 bug.
    run expand_template "$tpl" \
        "BLOCK_A" $'FROM builder AS stage1\n' \
        "BLOCK_B" ""

    [ "$status" -eq 0 ]
    echo "$output" | grep -Fqx 'FROM builder AS stage1'
    # Marker line is suppressed (empty replacement → nothing printed)
    ! echo "$output" | grep -q "@@BLOCK_B@@"
}

# ---------------------------------------------------------------------------
# (a3) Successful expansion: BOTH markers empty, last line is a marker → exit 0
# ---------------------------------------------------------------------------
@test "expand_template: BOTH markers empty, last line is marker → exit 0 [was RED]" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_marker_last "$tpl"

    run expand_template "$tpl" \
        "BLOCK_A" "" \
        "BLOCK_B" ""

    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q "@@BLOCK_A@@"
    ! echo "$output" | grep -q "@@BLOCK_B@@"
    echo "$output" | grep -Fqx 'ARG VERSION'
}

# ---------------------------------------------------------------------------
# (a4) Passthrough line after last marker: empty replacement → exit 0 (was OK)
# ---------------------------------------------------------------------------
@test "expand_template: empty last marker but passthrough line follows → exit 0" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_passthrough_last "$tpl"

    run expand_template "$tpl" \
        "BLOCK_A" "" \
        "BLOCK_B" ""

    [ "$status" -eq 0 ]
    echo "$output" | grep -Fqx 'ARG VERSION'
    echo "$output" | grep -Fqx 'CMD ["postgres"]'
}

# ---------------------------------------------------------------------------
# (b) Genuine error: nonexistent template file → non-zero exit
# ---------------------------------------------------------------------------
@test "expand_template: nonexistent template file → non-zero exit" {
    run expand_template "$TEST_TEMP_DIR/does-not-exist.template" \
        "BLOCK_A" "some content"

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# (c) Error: no marker pairs provided → non-zero exit
# ---------------------------------------------------------------------------
@test "expand_template: no marker pairs → non-zero exit" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_passthrough_last "$tpl"

    run expand_template "$tpl"

    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# (d) Passthrough: lines without any marker pass through unchanged
# ---------------------------------------------------------------------------
@test "expand_template: lines without markers pass through unchanged" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_passthrough_last "$tpl"

    run expand_template "$tpl" \
        "BLOCK_A" "" \
        "BLOCK_B" ""

    [ "$status" -eq 0 ]
    echo "$output" | grep -Fqx 'ARG VERSION'
    echo "$output" | grep -Fqx 'CMD ["postgres"]'
}
