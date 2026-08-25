#!/usr/bin/env bash

# Hashing helpers for docker-containers build scripts.
#
# sha256_file is backslash-safe: it feeds the file via stdin so GNU coreutils
# never escapes a filename containing backslashes or newlines (which on Windows
# Git Bash paths like C:\Users\... would otherwise prefix the hash output with
# '\', breaking awk '{print $1}' extraction).
#
# Usage: source this file, then call sha256_file <path>
#
# Do NOT add set -e at file scope; this is a sourced helper.

# sha256_file <path>
# Prints the lowercase SHA-256 digest of the file at <path>.
# Returns 1 if the file cannot be read or sha256sum does not produce a first
# whitespace-delimited 64-hex field without an interior newline.  Text after
# that field is accepted; command substitution discards trailing newlines.
sha256_file() {
    local file="${1:?sha256_file: file path required}"
    local sha256_output digest
    [[ -r "$file" ]] || { echo "sha256_file: cannot read '$file'" >&2; return 1; }
    if ! sha256_output=$(sha256sum < "$file"); then
        echo "sha256_file: sha256sum failed for '$file'" >&2
        return 1
    fi
    digest="${sha256_output%%[[:space:]]*}"
    if [[ "$sha256_output" == *$'\n'* || ${#digest} -ne 64 || "$digest" == *[!0-9A-Fa-f]* ]]; then
        echo "sha256_file: sha256sum returned an invalid digest for '$file'" >&2
        return 1
    fi
    printf '%s\n' "${digest,,}"
}
