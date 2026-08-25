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

@test "sha256_file: accepts a binary-stdin marker after the digest" {
    local file="$TEST_TEMP_DIR/data.bin"
    local bin_dir="$TEST_TEMP_DIR/bin"
    local expected
    printf 'data\n' > "$file"
    mkdir -p "$bin_dir"
    expected=$(printf '%064d' 0)
    printf '#!/usr/bin/env bash\nprintf "%%064d *-\\n" 0\n' > "$bin_dir/sha256sum"
    chmod +x "$bin_dir/sha256sum"

    PATH="$bin_dir:$PATH" run sha256_file "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

@test "sha256_file: lowercases an uppercase digest" {
    local file="$TEST_TEMP_DIR/data.bin"
    local bin_dir="$TEST_TEMP_DIR/bin"
    local uppercase_digest='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    printf 'data\n' > "$file"
    mkdir -p "$bin_dir"
    [ "${#uppercase_digest}" -eq 64 ]
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$uppercase_digest *-" > "$bin_dir/sha256sum"
    chmod +x "$bin_dir/sha256sum"

    PATH="$bin_dir:$PATH" run sha256_file "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "${uppercase_digest,,}" ]
}

@test "sha256_file: does not change a caller's BASH_REMATCH" {
    local file="$TEST_TEMP_DIR/data.bin"
    local captured="$TEST_TEMP_DIR/captured"
    printf 'data\n' > "$file"

    local caller_input='caller-123'
    [[ "$caller_input" =~ ^([a-z]+)-([0-9]+)$ ]]
    local caller_match="${BASH_REMATCH[1]}"
    local caller_capture="${BASH_REMATCH[2]}"

    if ! sha256_file "$file" > "$captured"; then
        echo "sha256_file unexpectedly failed"
        return 1
    fi
    [ "${BASH_REMATCH[1]}" = "$caller_match" ]
    [ "${BASH_REMATCH[2]}" = "$caller_capture" ]
}

@test "sha256_file: accepts the GNU stdin form and trailing blank lines" {
    local file="$TEST_TEMP_DIR/data.bin"
    local bin_dir="$TEST_TEMP_DIR/bin"
    local digest='0000000000000000000000000000000000000000000000000000000000000000'
    local payload="${digest}  -"$'\n\n'
    local expected="$TEST_TEMP_DIR/expected"
    local actual="$TEST_TEMP_DIR/actual"
    printf 'data\n' > "$file"
    mkdir -p "$bin_dir"
    printf '#!/bin/bash\nprintf "%%s" %q\nexit 0\n' "$payload" > "$bin_dir/sha256sum"
    chmod +x "$bin_dir/sha256sum"

    printf '%s' "$payload" > "$expected"
    if ! "$bin_dir/sha256sum" > "$actual"; then
        echo "generated sha256sum stub failed"
        return 1
    fi
    cmp -s "$expected" "$actual"

    PATH="$bin_dir:$PATH" run sha256_file "$file"
    [ "$status" -eq 0 ]
    [ "$output" = "$digest" ]
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

@test "sha256_file: preserves stdin hashing for a filename containing a backslash and newline" {
    local file="$TEST_TEMP_DIR/foo\\bar"$'\n'"line.bin"
    local expected
    printf 'newline-safe data\n' > "$file"

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

# A broken or incompatible sha256sum must not supply a cache identity.
@test "sha256_file: refuses empty sha256sum output without emitting a digest" {
    local file="$TEST_TEMP_DIR/data.bin"
    local bin_dir="$TEST_TEMP_DIR/bin"
    local captured="$TEST_TEMP_DIR/captured"
    printf 'data\n' > "$file"
    mkdir -p "$bin_dir"
    printf '#!/bin/bash\nexit 0\n' > "$bin_dir/sha256sum"
    chmod +x "$bin_dir/sha256sum"

    PATH="$bin_dir:$PATH"
    if sha256_file "$file" > "$captured"; then
        echo "sha256_file accepted empty sha256sum output"
        return 1
    fi
    [ ! -s "$captured" ]
}

@test "sha256_file: refuses a failing sha256sum without emitting a digest" {
    local file="$TEST_TEMP_DIR/data.bin"
    local bin_dir="$TEST_TEMP_DIR/bin"
    local captured="$TEST_TEMP_DIR/captured"
    printf 'data\n' > "$file"
    mkdir -p "$bin_dir"
    # shellcheck disable=SC2183 # The generated stub, not this test, consumes %064d.
    printf '#!/bin/bash\nprintf "%064d  -\\n" 0\nexit 9\n' > "$bin_dir/sha256sum"
    chmod +x "$bin_dir/sha256sum"

    PATH="$bin_dir:$PATH"
    if sha256_file "$file" > "$captured"; then
        echo "sha256_file accepted a failing sha256sum"
        return 1
    fi
    [ ! -s "$captured" ]
}

@test "sha256_file: refuses malformed sha256sum output without emitting a digest" {
    local file="$TEST_TEMP_DIR/data.bin"
    local bin_dir="$TEST_TEMP_DIR/bin"
    local captured="$TEST_TEMP_DIR/captured"
    local malformed
    printf 'data\n' > "$file"
    mkdir -p "$bin_dir"

    for malformed in \
        'abc  -' \
        '00000000000000000000000000000000000000000000000000000000000000000  -' \
        'gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg  -' \
        $'0000000000000000000000000000000000000000000000000000000000000000  -\n0000000000000000000000000000000000000000000000000000000000000000  -'; do
        local expected="$TEST_TEMP_DIR/expected"
        local actual="$TEST_TEMP_DIR/actual"
        printf '#!/bin/bash\nprintf "%%s" %q\nexit 0\n' "$malformed" > "$bin_dir/sha256sum"
        chmod +x "$bin_dir/sha256sum"
        printf '%s' "$malformed" > "$expected"
        if ! "$bin_dir/sha256sum" > "$actual"; then
            echo "generated sha256sum stub failed for malformed output: $malformed"
            return 1
        fi
        if ! cmp -s "$expected" "$actual"; then
            echo "generated sha256sum stub did not emit the malformed output exactly: $malformed"
            return 1
        fi
        PATH="$bin_dir:$PATH"
        if sha256_file "$file" > "$captured"; then
            printf 'FAIL: sha256_file accepted malformed sha256sum output: %q\n' "$malformed"
            return 1
        fi
        [ ! -s "$captured" ]
    done
}
