#!/usr/bin/env bash

# Write a command's newline-delimited output to a file without losing the
# command's exit status to process substitution.
#
# collect_lines <output-file> -- <command> [argument ...]
#
# The output path is replaced only when the producer succeeds, so callers which
# read it only after success cannot observe partial output or a stale result.
# The caller owns the output path and removes it when finished.
#
# Bash 4.0 compatibility is deliberate: do not use local/declare -n namerefs
# (they require Bash 4.3).  This covers array collection through mapfile/readarray
# from process substitution.  It does not cover while-read process-substitution
# consumers: 61 non-test sites remain and are tracked separately in #1117.
# GHCR tag enumeration before a deletion decision is handled explicitly by its
# caller.  The helper is intentionally a library function: it returns status and
# never exits its caller.
collect_lines() {
    [[ "$#" -ge 3 && "$2" == "--" ]] || return 2

    local _collect_lines_output="$1"
    local _collect_lines_tmp
    local _collect_lines_status

    [[ -n "$_collect_lines_output" && ! -d "$_collect_lines_output" && -d "$(dirname "$_collect_lines_output")" ]] || return 2

    shift 2
    # The sibling temporary makes mv atomic on the caller's filesystem.
    _collect_lines_tmp=$(mktemp "${_collect_lines_output}.tmp.XXXXXX") || return 1

    if "$@" >"$_collect_lines_tmp"; then
        if mv -f "$_collect_lines_tmp" "$_collect_lines_output"; then
            return 0
        else
            _collect_lines_status=$?
        fi
    else
        _collect_lines_status=$?
    fi

    rm -f "$_collect_lines_tmp"
    return "$_collect_lines_status"
}
