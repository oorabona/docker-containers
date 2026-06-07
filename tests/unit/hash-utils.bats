#!/usr/bin/env bats

# Unit tests for helpers/hash-utils.sh
#
# Regression lock: sha256_file must return a bare 64-hex-char hash even when
# the file path contains backslashes.  GNU sha256sum escapes such filenames by
# prefixing the output line with '\', so the old
#   sha256sum "$f" | awk '{print $1}'
# approach yielded '\<hash>' (with leading backslash), causing hash comparisons
# to always fail on Windows Git Bash where USERPROFILE contains backslashes.
#
# The fix feeds the file via stdin (sha256sum < "$file") so the "filename"
# reported by sha256sum is '-', which is never escaped.

load "../test_helper"

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
    setup_temp_dir

    # shellcheck source=/dev/null
    source "$HELPERS_DIR/hash-utils.sh"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Happy path — normal filename
# ---------------------------------------------------------------------------

@test "sha256_file: returns a bare 64-hex-char hash for a normal-named file" {
    local file="$TEST_TEMP_DIR/normal.bin"
    printf 'hello world\n' > "$file"

    run sha256_file "$file"
    [ "$status" -eq 0 ]
    # Must be exactly 64 lowercase hex characters (no trailing newline counted)
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "sha256_file: matches sha256sum < file | awk for a normal-named file" {
    local file="$TEST_TEMP_DIR/data.bin"
    printf 'test data for sha256\n' > "$file"

    expected=$(sha256sum < "$file" | awk '{print $1}')
    run sha256_file "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Regression lock — backslash in filename
# ---------------------------------------------------------------------------

@test "sha256_file: returns a clean 64-hex hash for a file whose name contains a backslash" {
    # On Linux, '\' is a legal filename character.  This simulates Windows
    # Git Bash paths like C:\Users\runner\... that trigger GNU sha256sum's
    # filename-escaping behaviour.
    local file="$TEST_TEMP_DIR/foo\\bar.exe"
    printf 'buildx binary simulation\n' > "$file"

    run sha256_file "$file"
    [ "$status" -eq 0 ]
    # (a) Exactly 64 hex characters — no leading backslash, no other prefix
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "OLD approach: sha256sum on a backslash-named file DOES produce a leading backslash (documents the bug)" {
    # This test intentionally demonstrates the bug the fix prevents.
    # sha256sum escapes filenames containing backslashes by prefixing the line
    # with '\', so awk '{print $1}' returns '\<hash>' — not a bare hash.
    local file="$TEST_TEMP_DIR/foo\\bar.exe"
    printf 'buildx binary simulation\n' > "$file"

    old_result=$(sha256sum "$file" | awk '{print $1}')
    # The old approach starts with a backslash — this is the bug
    [[ "$old_result" == \\* ]]
}

@test "sha256_file: backslash-named file hash equals sha256sum-stdin hash" {
    local file="$TEST_TEMP_DIR/foo\\bar.exe"
    printf 'consistent data\n' > "$file"

    expected=$(sha256sum < "$file" | awk '{print $1}')
    run sha256_file "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Fail-closed — missing or unreadable file
# ---------------------------------------------------------------------------

@test "sha256_file: returns non-zero for a missing file" {
    run sha256_file "$TEST_TEMP_DIR/does-not-exist.bin"
    [ "$status" -ne 0 ]
}

@test "sha256_file: returns non-zero for an unreadable file" {
    local file="$TEST_TEMP_DIR/unreadable.bin"
    printf 'secret\n' > "$file"
    chmod 000 "$file"

    run sha256_file "$file"
    [ "$status" -ne 0 ]

    # Restore so teardown can clean up
    chmod 644 "$file"
}

@test "sha256_file: returns non-zero when called without arguments" {
    run sha256_file
    [ "$status" -ne 0 ]
}
