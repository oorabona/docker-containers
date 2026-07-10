#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    TEST_TEMP_DIR="$(mktemp -d)"
    HELPER="${PROJECT_ROOT}/helpers/latest-github-tag"
    export GITHUB_API_URL="https://github.example/api/v3"
    unset GITHUB_TOKEN
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
    unset GITHUB_API_URL
    unset GITHUB_TOKEN
}

write_fake_curl() {
    local mode="$1"

    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${FAKE_CURL_MODE:?}"
header_file=""
config_file=""
url=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -D)
            header_file="$2"
            shift 2
            ;;
        --config)
            config_file="$2"
            shift 2
            ;;
        --connect-timeout|--max-time|--proto|--proto-redir|-H)
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

: "${header_file:?missing -D header file}"
: "${url:?missing url}"

if [[ -n "${FAKE_CURL_CONFIG_LOG:-}" ]]; then
    if [[ -n "$config_file" ]]; then
        printf 'CONFIG:%s\n' "$(tr '\n' ';' < "$config_file")" >> "$FAKE_CURL_CONFIG_LOG"
    else
        printf 'CONFIG:\n' >> "$FAKE_CURL_CONFIG_LOG"
    fi
fi
if [[ -n "${FAKE_CURL_CONFIG_PATH_LOG:-}" && -n "$config_file" ]]; then
    printf '%s\n' "$config_file" >> "$FAKE_CURL_CONFIG_PATH_LOG"
fi

printf 'HTTP/2 200\n' > "$header_file"

case "$mode" in
    happy)
        printf '[{"name":"openssl-3.5.0"},{"name":"openssl-3.5.6"}]\n'
        ;;
    space_tag)
        printf '[{"name":"release v1.9.0 with space"},{"name":"release v1.10.0 with space"}]\n'
        ;;
    *)
        exit 99
        ;;
esac
EOF
    chmod +x "${TEST_TEMP_DIR}/bin/curl"
    export PATH="${TEST_TEMP_DIR}/bin:$PATH"
    export FAKE_CURL_MODE="$mode"
}

run_helper() {
    env PATH="$PATH" GITHUB_API_URL="$GITHUB_API_URL" FAKE_CURL_MODE="${FAKE_CURL_MODE:-}" FAKE_CURL_CONFIG_LOG="${FAKE_CURL_CONFIG_LOG:-}" FAKE_CURL_CONFIG_PATH_LOG="${FAKE_CURL_CONFIG_PATH_LOG:-}" \
        "$HELPER" "$@"
}

run_api_tags() {
    env PATH="$PATH" GITHUB_API_URL="$GITHUB_API_URL" GITHUB_TOKEN="${GITHUB_TOKEN:-}" FAKE_CURL_MODE="${FAKE_CURL_MODE:-}" FAKE_CURL_CONFIG_LOG="${FAKE_CURL_CONFIG_LOG:-}" FAKE_CURL_CONFIG_PATH_LOG="${FAKE_CURL_CONFIG_PATH_LOG:-}" \
        bash -c 'source "$1" && _gh_api_tags "$2"' bash "$HELPER" "$1"
}

last_output_line() {
    printf '%s' "${lines[$((${#lines[@]} - 1))]}"
}

@test "tag names with spaces are preserved for raw and both output" {
    write_fake_curl space_tag

    run run_helper "owner/repo" \
        --tag-filter '^release v[0-9]+\.[0-9]+\.[0-9]+ with space$' \
        --version-extract '^release v([0-9]+\.[0-9]+\.[0-9]+) with space$' \
        --output raw

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = "release v1.10.0 with space" ]

    run run_helper "owner/repo" \
        --tag-filter '^release v[0-9]+\.[0-9]+\.[0-9]+ with space$' \
        --version-extract '^release v([0-9]+\.[0-9]+\.[0-9]+) with space$' \
        --output both

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = $'1.10.0\trelease v1.10.0 with space' ]
}

@test "GitHub token rejects literal backslash escapes before curl config is written" {
    write_fake_curl happy
    export GITHUB_TOKEN='bad\ntoken'
    FAKE_CURL_CONFIG_PATH_LOG="${TEST_TEMP_DIR}/curl-config-path.log"
    FAKE_CURL_CONFIG_LOG="${TEST_TEMP_DIR}/curl-config.log"

    run run_api_tags "owner/repo"

    [ "$status" -eq 1 ]
    [[ "$output" == *"GITHUB_TOKEN must not contain double quotes or control characters; backslashes are also rejected"* ]]
    [ ! -e "$FAKE_CURL_CONFIG_PATH_LOG" ]
    [ ! -e "$FAKE_CURL_CONFIG_LOG" ]
}
