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

# Template whose first output is a passthrough line, for stdout write failures.
_make_template_passthrough_first() {
    local file="$1"
    python3 -c "
with open('$file', 'w') as f:
    f.write('ARG VERSION\n# @@BLOCK_A@@\n')
"
}

# Template whose first output is replacement content, for marker write failures.
_make_template_marker_first() {
    local file="$1"
    python3 -c "
with open('$file', 'w') as f:
    f.write('# @@BLOCK_A@@\n# @@BLOCK_B@@\n')
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
# GREEN after fix: the final compound `if` has no failure branch to run, so
# the function falls through with status 0.
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

@test "expand_template: succeeds with cat on restricted PATH" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local restricted_path="$TEST_TEMP_DIR/restricted-path"
    local tool
    _make_template_marker_last "$tpl"
    mkdir -p "$restricted_path"

    for tool in bash sh jq yq git sed grep sort tail tr paste cut awk dirname pwd realpath wc find cat; do
        ln -s "$(command -v "$tool")" "$restricted_path/$tool"
    done

    run env PATH="$restricted_path" bash -c 'source "$1"; expand_template "$2" BLOCK_A content BLOCK_B ""' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -eq 0 ]
    [[ "$output" == *"content"* ]]
}

@test "expand_template: preserves an unterminated final passthrough line byte-for-byte" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local generated="$TEST_TEMP_DIR/generated"
    local expected="$TEST_TEMP_DIR/expected"
    printf '%s' $'ARG VERSION\n# @@BLOCK_A@@\nunterminated final line' > "$tpl"

    expand_template "$tpl" "BLOCK_A" $'expanded marker\n' > "$generated"
    printf '%s' $'ARG VERSION\nexpanded marker\nunterminated final line' > "$expected"

    cmp -s "$expected" "$generated"
}

@test "expand_template: marker on unterminated final line uses replacement bytes" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local generated="$TEST_TEMP_DIR/generated"
    local expected="$TEST_TEMP_DIR/expected"
    printf '%s' $'ARG VERSION\n# @@BLOCK_A@@' > "$tpl"

    expand_template "$tpl" "BLOCK_A" "replacement without newline" > "$generated"
    printf '%s' $'ARG VERSION\nreplacement without newline' > "$expected"

    cmp -s "$expected" "$generated"
}

@test "expand_template: preserves terminated blank passthrough records" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local generated="$TEST_TEMP_DIR/generated"
    local expected="$TEST_TEMP_DIR/expected"

    printf '%s' $'# @@BLOCK_A@@\na\n\n' > "$tpl"
    expand_template "$tpl" "BLOCK_A" "" > "$generated"
    printf '%s' $'a\n\n' > "$expected"
    cmp -s "$expected" "$generated"

    printf '%s' $'# @@BLOCK_A@@\n\n' > "$tpl"
    expand_template "$tpl" "BLOCK_A" "" > "$generated"
    printf '%s' $'\n' > "$expected"
    cmp -s "$expected" "$generated"
}

# ---------------------------------------------------------------------------
# (e) stdout write failures must be returned explicitly.  These calls use
# /dev/full rather than a mocked printf because callers redirect the function's
# stdout to generated Dockerfiles.
# ---------------------------------------------------------------------------
@test "expand_template: marker write to /dev/full returns non-zero directly" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_marker_first "$tpl"

    run bash -c 'source "$1"; expand_template "$2" BLOCK_A content BLOCK_B "" > /dev/full' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -ne 0 ]
    [[ "$output" == *"@@BLOCK_A@@"* ]]
    [[ "$output" == *"$tpl"* ]]
    [[ "$output" != *"failed to read template"* ]]
}

@test "expand_template: marker write to /dev/full returns non-zero under if" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_marker_first "$tpl"

    run bash -c 'source "$1"; if expand_template "$2" BLOCK_A content BLOCK_B "" > /dev/full; then exit 0; else exit 1; fi' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -ne 0 ]
    [[ "$output" == *"@@BLOCK_A@@"* ]]
}

@test "expand_template: marker write to /dev/full returns non-zero on left of ||" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_marker_first "$tpl"

    run bash -c 'source "$1"; expand_template "$2" BLOCK_A content BLOCK_B "" > /dev/full || exit 1' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -ne 0 ]
    [[ "$output" == *"@@BLOCK_A@@"* ]]
}

@test "expand_template: marker write failure returns non-zero and emits no later content" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local generated="$TEST_TEMP_DIR/generated"
    local marker_content=$'A_CONTENT\n'
    local second_content=$'B_CONTENT\n'
    local position expected

    for position in first middle last; do
        expected="$TEST_TEMP_DIR/expected-$position"
        case "$position" in
            first)
                printf '%s' $'# @@BLOCK_A@@\n# @@BLOCK_B@@\nafter\n' > "$tpl"
                printf '%s' 'MARKER_PREFIX' > "$expected"
                ;;
            middle)
                printf '%s' $'before\n# @@BLOCK_A@@\n# @@BLOCK_B@@\nafter\n' > "$tpl"
                printf '%s' $'before\nMARKER_PREFIX' > "$expected"
                ;;
            last)
                printf '%s' $'before\n# @@BLOCK_B@@\n# @@BLOCK_A@@\n' > "$tpl"
                printf '%s' $'before\nB_CONTENT\nMARKER_PREFIX' > "$expected"
                ;;
        esac

        run bash -c '
            source "$1"
            marker_content="$4"
            printf() {
                if [[ "$1" == "%s" && "$2" == "$marker_content" ]]; then
                    builtin printf "%s" "MARKER_PREFIX"
                    return 1
                fi
                builtin printf "$@"
            }
            if expand_template "$2" BLOCK_A "$4" BLOCK_B "$5" > "$3"; then
                exit 0
            fi
            exit 1
        ' bash "$HELPERS_DIR/template-utils.sh" "$tpl" "$generated" "$marker_content" "$second_content"

        [ "$status" -eq 1 ]
        cmp -s "$expected" "$generated"
        ! grep -Fq 'after' "$generated"
        [[ "$output" == *"failed to write marker @@BLOCK_A@@"* ]]
        [[ "$output" != *"failed to read template"* ]]
    done
}

@test "expand_template: passthrough write failure returns non-zero and emits no later content" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local generated="$TEST_TEMP_DIR/generated"
    local expected="$TEST_TEMP_DIR/expected"

    printf '%s' $'# @@BLOCK_A@@\nfailed\nafter\n' > "$tpl"

    run bash -c '
        source "$1"
        printf() {
            if [[ "$1" == "%s\\n" && "$2" == "failed" ]]; then
                builtin printf "%s" "PASSTHROUGH_PREFIX"
                return 1
            fi
            builtin printf "$@"
        }
        if expand_template "$2" BLOCK_A "" > "$3"; then
            exit 0
        fi
        exit 1
    ' bash "$HELPERS_DIR/template-utils.sh" "$tpl" "$generated"

    [ "$status" -eq 1 ]
    printf '%s' 'PASSTHROUGH_PREFIX' > "$expected"
    cmp -s "$expected" "$generated"
    ! grep -Fq 'after' "$generated"
    [[ "$output" == *"failed to write passthrough line (no marker)"* ]]
    [[ "$output" != *"failed to read template"* ]]
}

@test "expand_template: empty marker content succeeds and emits later lines" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"

    printf '%s' $'before\n# @@BLOCK_A@@\nafter\n' > "$tpl"

    run expand_template "$tpl" BLOCK_A ""

    [ "$status" -eq 0 ]
    [ "$output" = $'before\nafter' ]
}

@test "expand_template: passthrough write to /dev/full returns non-zero" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    _make_template_passthrough_first "$tpl"

    run bash -c 'source "$1"; expand_template "$2" BLOCK_A "" > /dev/full' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -ne 0 ]
    [[ "$output" == *"passthrough line (no marker)"* ]]
    [[ "$output" == *"$tpl"* ]]
    [[ "$output" != *"failed to read template"* ]]
}

@test "expand_template: template redirection failure returns non-zero" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local fake_bin="$TEST_TEMP_DIR/fake-bin"
    local real_grep
    _make_template_marker_first "$tpl"
    mkdir -p "$fake_bin"
    real_grep="$(command -v grep)"
    python3 -c '
import os
import sys
path = sys.argv[1]
with open(path, "w") as f:
    f.write("""#!/usr/bin/env bash
"$REAL_GREP" "$@"
status=$?
rm -f -- "$TEMPLATE_TO_REMOVE"
exit "$status"
""")
os.chmod(path, 0o755)
' "$fake_bin/grep"

    run env PATH="$fake_bin:$PATH" REAL_GREP="$real_grep" TEMPLATE_TO_REMOVE="$tpl" bash -c 'source "$1"; expand_template "$2" BLOCK_A content' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to read template: $tpl"* ]]
}

@test "expand_template: reader failure returns non-zero" {
    local tpl="$TEST_TEMP_DIR/Dockerfile.template"
    local fake_bin="$TEST_TEMP_DIR/fake-bin"
    _make_template_marker_first "$tpl"
    mkdir -p "$fake_bin"
    printf '%s\n' '#!/usr/bin/env bash' 'IFS= read -r line < "$2"' 'printf "%s\\n" "$line"' 'exit 1' > "$fake_bin/cat"
    chmod +x "$fake_bin/cat"

    run env PATH="$fake_bin:$PATH" bash -c 'source "$1"; expand_template "$2" BLOCK_A content BLOCK_B ""' \
        bash "$HELPERS_DIR/template-utils.sh" "$tpl"

    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to read template: $tpl"* ]]
}
