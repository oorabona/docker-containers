#!/usr/bin/env bash

# Collect a command's newline-delimited output into an array without losing the
# command's exit status to process substitution.
#
# collect_lines <array-name> -- <command> [argument ...]
#
# The destination is updated only when the command succeeds.  An empty output
# file produces an empty array; a file containing one blank line produces one
# empty element.  The helper is intentionally a library function: it returns
# status and never exits its caller.
collect_lines() {
    [[ "$#" -ge 3 && "$2" == "--" ]] || return 2

    local _collect_lines_destination_name="$1"
    local _collect_lines_tmp
    local _collect_lines_status

    # A nameref resolves names in this function's dynamic scope.  Refuse names
    # owned by the helper so a caller cannot accidentally collect into one of
    # these locals instead of its own array.
    case "$_collect_lines_destination_name" in
        _collect_lines_destination|_collect_lines_destination_name|_collect_lines_tmp|_collect_lines_status)
            return 2
            ;;
    esac
    [[ "$_collect_lines_destination_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
    local -n _collect_lines_destination="$_collect_lines_destination_name"

    shift 2
    _collect_lines_tmp=$(mktemp "${TMPDIR:-/tmp}/collect-lines.XXXXXX") || return 1

    if "$@" >"$_collect_lines_tmp"; then
        # Reading after, rather than alongside, the producer is what makes a
        # failed enumeration unable to alter the destination array.
        mapfile -t _collect_lines_destination <"$_collect_lines_tmp"
        _collect_lines_status=$?
    else
        _collect_lines_status=$?
    fi

    rm -f "$_collect_lines_tmp"
    return "$_collect_lines_status"
}
