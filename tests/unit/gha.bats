#!/usr/bin/env bats

# Unit tests for helpers/gha.sh.

load "../test_helper"

setup() {
    setup_temp_dir
    source "$HELPERS_DIR/gha.sh"
}

teardown() {
    teardown_temp_dir
}

@test "annotations escape the complete rendered message before emitting" {
    local value
    value=$'before%\r\n##[add-mask]legacy\001\033\b\n::add-mask::forged'

    run gha_error 'untrusted value: %s' "$value"

    [ "$status" -eq 0 ]
    [ "$output" = '::error::untrusted value: before%25%0D%0A##%5Badd-mask]legacy%0A::add-mask::forged' ]
    [[ "$output" != *$'\r'* ]]
    [[ "$output" != *$'\n::'* ]]
    [[ "$output" != *'##['* ]]
}

@test "annotation formatting cannot bypass escaping" {
    local format
    format=$'bad value: %s\n::add-mask::forged'

    run gha_warning "$format" '100%'

    [ "$status" -eq 0 ]
    [ "$output" = '::warning::bad value: 100%25%0A::add-mask::forged' ]
    [[ "$output" != *$'\n::add-mask::'* ]]
}

@test "annotations accept only percent-s and literal-percent formats with matching arguments" {
    run gha_notice 'complete: %% %s' '100%'

    [ "$status" -eq 0 ]
    [ "$output" = '::notice::complete: %25 100%25' ]

    run gha_notice 'missing %s %s' 'detail'

    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run gha_notice 'extra detail' 'detail'

    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run gha_notice '-literal'

    [ "$status" -eq 0 ]
    [ "$output" = '::notice::-literal' ]
}

@test "annotations let strict-shell callers emit and continue" {
    local target="$TEST_TEMP_DIR/annotations"

    run bash -c 'set -euo pipefail
        source "$1"
        {
            gha_error "literal message"
            printf "after literal\\n"
            gha_error "saw %s" value
            printf "after formatted\\n"
        } > "$2"' _ "$HELPERS_DIR/gha.sh" "$target"

    [ "$status" -eq 0 ]
    [ "$(<"$target")" = $'::error::literal message\nafter literal\n::error::saw value\nafter formatted' ]
}

@test "annotations refuse unsafe printf conversions without emitting" {
    run gha_error 'attempt %n' PATH

    [ "$status" -ne 0 ]
    [ -z "$output" ]

    run gha_warning 'attempt %10s' 'width'

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "annotations remove bidi controls before emitting" {
    local value=$'visible\u061Creversed\u202Eisolated\u2066marked\u200Fend'

    run gha_notice '%s' "$value"

    [ "$status" -eq 0 ]
    [ "$output" = '::notice::visiblereversedisolatedmarkedend' ]
}

@test "bidi controls are removed when Bash is running in the C locale" {
    run env LC_ALL=C bash -c 'source "$1"; _escape_gha_command $'"'"'before\xE2\x80\xAEafter'"'"'' _ \
        "$HELPERS_DIR/gha.sh"

    [ "$status" -eq 0 ]
    [ "$output" = 'beforeafter' ]
}

@test "gha_output preserves multiline and CRLF values without a second output" {
    local target="$TEST_TEMP_DIR/github-output"
    local value=$'first line\n\r\nFORGED=value\nlast line'
    local delimiter expected="$TEST_TEMP_DIR/expected-output"
    : > "$target"
    export GITHUB_OUTPUT="$target"

    run gha_output SAFE_VALUE "$value"

    [ "$status" -eq 0 ]
    [[ "$output" == *'SAFE_VALUE uses the GitHub Actions multiline protocol'* ]]
    IFS= read -r delimiter < "$target"
    delimiter=${delimiter#SAFE_VALUE<<}
    delimiter=${delimiter%%$'\n'*}
    printf '%s<<%s\n%s\n%s\n' SAFE_VALUE "$delimiter" "$value" "$delimiter" > "$expected"
    cmp -s "$target" "$expected"
    [ "$(grep -c '^FORGED=value$' "$target")" -eq 1 ]
    [ "$(grep -c '^SAFE_VALUE<<' "$target")" -eq 1 ]
}

@test "gha_env preserves multiline values without a second variable" {
    local target="$TEST_TEMP_DIR/github-env"
    local value=$'line one\nINJECTED=wrong\nline three'
    local delimiter expected="$TEST_TEMP_DIR/expected-env"
    : > "$target"
    export GITHUB_ENV="$target"

    run gha_env TARGET_VALUE "$value"

    [ "$status" -eq 0 ]
    [[ "$output" == *'TARGET_VALUE uses the GitHub Actions multiline protocol'* ]]
    IFS= read -r delimiter < "$target"
    delimiter=${delimiter#TARGET_VALUE<<}
    delimiter=${delimiter%%$'\n'*}
    printf '%s<<%s\n%s\n%s\n' TARGET_VALUE "$delimiter" "$value" "$delimiter" > "$expected"
    cmp -s "$target" "$expected"
    [ "$(grep -c '^INJECTED=wrong$' "$target")" -eq 1 ]
}

@test "a colliding generated delimiter is retried before writing" {
    local target="$TEST_TEMP_DIR/github-output"
    local value=$'before\nc0111de5\nafter'
    local content delimiter
    : > "$target"
    export GITHUB_OUTPUT="$target"
    _gha_generate_delimiter() {
        if [[ ! -f "$TEST_TEMP_DIR/generated-once" ]]; then
            : > "$TEST_TEMP_DIR/generated-once"
            printf '%s' c0111de5
        else
            printf '%s' a11ce123
        fi
    }

    run gha_output SAFE_VALUE "$value"

    [ "$status" -eq 0 ]
    content=$(<"$target")
    delimiter=${content#SAFE_VALUE<<}
    delimiter=${delimiter%%$'\n'*}
    [ "$delimiter" = a11ce123 ]
    [[ "$content" != *$'\nc0111de5\nc0111de5\n'* ]]
}

@test "delimiter collisions that exhaust the bound fail without writing" {
    local target="$TEST_TEMP_DIR/github-output"
    printf 'existing\n' > "$target"
    export GITHUB_OUTPUT="$target"
    _gha_generate_delimiter() {
        printf '%s' c0111de5
    }

    run gha_output SAFE_VALUE $'before\nc0111de5\nafter'

    [ "$status" -ne 0 ]
    [ "$(<"$target")" = existing ]
}

@test "output IDs permit hyphens and reject other invalid characters" {
    local target="$TEST_TEMP_DIR/github-output"
    printf 'existing\n' > "$target"
    export GITHUB_OUTPUT="$target"

    run gha_output 'random-number' 'value'

    [ "$status" -eq 0 ]
    grep -q '^random-number<<' "$target"

    run gha_output 'NOT/VALID' 'value'

    [ "$status" -ne 0 ]
    [ "$(grep -c '^NOT/VALID<<' "$target")" -eq 0 ]
}

@test "environment names reject runner-blocked and output-only names" {
    local target="$TEST_TEMP_DIR/github-env"
    printf 'existing\n' > "$target"
    export GITHUB_ENV="$target"
    local name

    for name in NODE_OPTIONS node_options GITHUB_TOKEN github_token RUNNER_OS runner_os NOT-VALID; do
        run gha_env "$name" 'value'

        [ "$status" -ne 0 ]
        [ "$(<"$target")" = existing ]
    done
}

@test "gha_env preserves a terminal CR on Windows CRLF parsing" {
    local target="$TEST_TEMP_DIR/github-env"
    local value=$'ends with CR\r'
    local delimiter expected="$TEST_TEMP_DIR/expected-env" stored_value
    : > "$target"
    export GITHUB_ENV="$target"

    run gha_env TARGET_VALUE "$value"

    [ "$status" -eq 0 ]
    IFS= read -r delimiter < "$target"
    delimiter=${delimiter#TARGET_VALUE<<}
    printf '%s<<%s\n%s\r\n%s\n' TARGET_VALUE "$delimiter" "$value" "$delimiter" > "$expected"
    cmp -s "$target" "$expected"

    # StreamReader.ReadLine on Windows consumes one CR as part of the record's
    # CRLF terminator, leaving the duplicated CR as the value's final byte.
    IFS= read -r _ < "$target"
    IFS= read -r stored_value < <(sed -n '2p' "$target")
    stored_value=${stored_value%$'\r'}
    [ "$stored_value" = "$value" ]
}

@test "a nonexistent output target fails without creating a file" {
    local target="$TEST_TEMP_DIR/github-output"
    export GITHUB_OUTPUT="$target"

    run gha_output SAFE_VALUE 'value'

    [ "$status" -ne 0 ]
    [ ! -e "$target" ]
}

@test "a nonexistent env target fails without creating a file" {
    local target="$TEST_TEMP_DIR/github-env"
    export GITHUB_ENV="$target"

    run gha_env SAFE_VALUE 'value'

    [ "$status" -ne 0 ]
    [ ! -e "$target" ]
}

@test "environment files are byte-transparent but are not UTF-8 validated" {
    local target="$TEST_TEMP_DIR/github-output"
    local value=$'valid\377byte'
    : > "$target"
    export GITHUB_OUTPUT="$target"

    run gha_output SAFE_VALUE "$value"

    [ "$status" -eq 0 ]
    LC_ALL=C grep -q $'valid\377byte' "$target"
}

@test "logging.sh still exposes _escape_gha_command" {
    run bash -c 'source "$1/helpers/logging.sh"; _escape_gha_command "$2"' _ \
        "$PROJECT_ROOT" $'before%\n##[add-mask]'

    [ "$status" -eq 0 ]
    [ "$output" = 'before%25%0A##%5Badd-mask]' ]
}

@test "gha.sh and logging.sh keep byte-identical command escapers" {
    local gha_escaper="$TEST_TEMP_DIR/gha-escaper"
    local logging_escaper="$TEST_TEMP_DIR/logging-escaper"

    run bash -c 'source "$1"; declare -f _escape_gha_command > "$3"; source "$2"; declare -f _escape_gha_command > "$4"; cmp -s "$3" "$4"' _ \
        "$HELPERS_DIR/gha.sh" "$PROJECT_ROOT/helpers/logging.sh" "$gha_escaper" "$logging_escaper"

    [ "$status" -eq 0 ]
}
