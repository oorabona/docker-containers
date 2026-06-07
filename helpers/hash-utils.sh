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
# Prints the lowercase hex SHA-256 of the file at <path>.
# Returns 1 if the file cannot be read.
sha256_file() {
    local file="${1:?sha256_file: file path required}"
    [[ -r "$file" ]] || { echo "sha256_file: cannot read '$file'" >&2; return 1; }
    sha256sum < "$file" | awk '{print $1}'
}
