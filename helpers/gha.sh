#!/usr/bin/env bash

# GitHub Actions workflow-command and environment-file emitters.
#
# This file deliberately has no dependencies on the other helpers, no load-time
# output, and does not change shell options. It requires Bash; source it from
# Bash scripts, composite actions, or inline Bash `run:` blocks.
#
# `_escape_gha_command` is defined here AND, for now, still in `logging.sh` —
# byte-identical, so a script sourcing both is unaffected by which wins. That
# duplication is transitional and has a defined end: the eight files that reach
# the escaper through `logging.sh` move to sourcing this file during the call-site
# migration, and `logging.sh`'s copy is deleted with the last of them.
#
# The alternative, having `logging.sh` source this file, was built and reverted:
# six test fixtures stage helpers one file at a time, so `logging.sh` acquiring a
# sibling broke 138 tests on a path inside their own temp roots. Making those
# fixtures stage the whole directory then changed what several of them model,
# because a fixture that copies one helper is asserting the others are absent.
# A slice that adds a capability should not need any of that.
#
# Bash variables cannot contain NUL bytes, so no shell helper can preserve or
# validate them. This helper also does not validate encoding: it writes every
# other byte sequence Bash can hold, while the runner reads environment files
# as UTF-8 text. Callers with non-UTF-8 data must encode it (for example, as
# base64) before emitting it.

# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a `::keyword::value` GitHub Actions
# workflow command. The runner also recognizes the legacy `##[` prefix
# anywhere in a line, so CR/LF escaping alone is not sufficient. Encode `%`
# first, then `##[`, so the `%5B` introduced for that legacy prefix remains
# intact. Drop remaining control bytes because they can rewrite terminal output.
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    # CR and LF are encoded rather than dropped: they are the characters a
    # reader wants to see marked, and encoding them is what stops a value from
    # starting a new line and with it a new `::` command.
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    # Every other control byte goes BEFORE the `##[` check, not after. Deleting
    # characters closes gaps: `##<backspace>[` does not match the marker, and
    # stripping afterwards reassembles it in the output — the escaped value then
    # carries the very command this is here to neutralize.
    s="${s//[[:cntrl:]]/}"
    # These bidi controls are not C0 controls, but can reorder text in a log
    # renderer and thereby change what a reader sees.
    s="${s//$'\xD8\x9C'/}"
    s="${s//$'\xE2\x80\xAA'/}"
    s="${s//$'\xE2\x80\xAB'/}"
    s="${s//$'\xE2\x80\xAC'/}"
    s="${s//$'\xE2\x80\xAD'/}"
    s="${s//$'\xE2\x80\xAE'/}"
    s="${s//$'\xE2\x81\xA6'/}"
    s="${s//$'\xE2\x81\xA7'/}"
    s="${s//$'\xE2\x81\xA8'/}"
    s="${s//$'\xE2\x81\xA9'/}"
    s="${s//$'\xE2\x80\x8E'/}"
    s="${s//$'\xE2\x80\x8F'/}"
    s="${s//##\[/##%5B}"
    printf '%s' "$s"
}

# _gha_generate_delimiter
#
# /dev/urandom is the only entropy source measured to exist in every shell
# environment this repository supports. The caller checks each generated token
# against the complete value; randomness alone is not relied on for safety.
_gha_generate_delimiter() {
    LC_ALL=C od -An -N 16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

# _gha_delimiter_occurs_in_value <delimiter> <value>
#
# A delimiter may not occur alone on a line. Treat a CRLF line ending as a line
# ending too, because GitHub Actions environment files may contain CRLF values.
_gha_delimiter_occurs_in_value() {
    local delimiter="$1"
    local value="$2"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$delimiter" || "$line" == "$delimiter"$'\r' ]] && return 0
    done <<< "$value"

    return 1
}

# _gha_emit_annotation <level> <printf-format> [printf-argument ...]
_gha_emit_annotation() {
    local level="$1"
    shift
    local format
    local message
    local position=0
    local substitutions=0

    [[ "$#" -gt 0 ]] || return 2
    format="$1"
    shift

    # The format is code, not data. Restrict it to the two literal conversions
    # this helper needs so Bash printf cannot write through %n or allocate an
    # arbitrary width. Matching the argument count also avoids silently losing
    # a missing detail to printf's empty-argument behaviour.
    while [[ "$position" -lt "${#format}" ]]; do
        if [[ "${format:position:1}" == '%' ]]; then
            position=$((position + 1))
            [[ "$position" -lt "${#format}" ]] || return 2
            case "${format:position:1}" in
                s)
                    substitutions=$((substitutions + 1))
                    ;;
                %)
                    ;;
                *)
                    return 2
                    ;;
            esac
        fi
        position=$((position + 1))
    done

    [[ "$substitutions" -eq "$#" ]] || return 2
    printf -v message -- "$format" "$@" || return 1
    printf '::%s::%s\n' "$level" "$(_escape_gha_command "$message")"
}

# gha_error <printf-format> [printf-argument ...]
gha_error() {
    _gha_emit_annotation error "$@"
}

# gha_warning <printf-format> [printf-argument ...]
gha_warning() {
    _gha_emit_annotation warning "$@"
}

# gha_notice <printf-format> [printf-argument ...]
gha_notice() {
    _gha_emit_annotation notice "$@"
}

# _gha_emit_file <target-variable-name> <NAME> <VALUE>
_gha_emit_file() {
    local target_variable="$1"
    local name="$2"
    local value="$3"
    local target="${!target_variable:-}"
    local delimiter=""
    local record
    local attempt
    local normalized_name

    [[ -n "$target" ]] || return 2
    [[ -f "$target" ]] || return 2

    case "$target_variable" in
        GITHUB_OUTPUT)
            [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || return 2
            ;;
        GITHUB_ENV)
            [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
            normalized_name="${name^^}"
            [[ "$normalized_name" != NODE_OPTIONS && "$normalized_name" != GITHUB_* && "$normalized_name" != RUNNER_* ]] || return 2
            ;;
        *)
            return 2
            ;;
    esac

    # The bound turns an unavailable entropy source or a deliberately hostile
    # value into a clean failure before the target file is opened for writing.
    attempt=0
    while [[ "$attempt" -lt 16 ]]; do
        delimiter="$(_gha_generate_delimiter)" || return 1
        [[ -n "$delimiter" && "$delimiter" =~ ^[A-Fa-f0-9]+$ ]] || return 1
        if ! _gha_delimiter_occurs_in_value "$delimiter" "$value"; then
            break
        fi
        delimiter=""
        attempt=$((attempt + 1))
    done

    [[ -n "$delimiter" ]] || return 1
    # On Windows, the runner treats CRLF as a structural newline. Duplicate a
    # terminal CR before this record's LF so the value retains its final byte.
    if [[ "$value" == *$'\r' ]]; then
        record="${name}<<${delimiter}"$'\n'"${value}"$'\r\n'"${delimiter}"$'\n'
    else
        record="${name}<<${delimiter}"$'\n'"${value}"$'\n'"${delimiter}"$'\n'
    fi

    if [[ "$value" == *$'\r'* || "$value" == *$'\n'* ]]; then
        printf 'gha: %s uses the GitHub Actions multiline protocol\n' "$name" >&2
    fi

    printf '%s' "$record" >> "$target"
}

# gha_output <NAME> <VALUE>
gha_output() {
    [[ "$#" -eq 2 ]] || return 2
    _gha_emit_file GITHUB_OUTPUT "$1" "$2"
}

# gha_env <NAME> <VALUE>
gha_env() {
    [[ "$#" -eq 2 ]] || return 2
    _gha_emit_file GITHUB_ENV "$1" "$2"
}

# This helper is needed by exported functions in callers that source logging.sh.
export -f _escape_gha_command
