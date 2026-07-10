#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    TEST_TEMP_DIR="$(mktemp -d)"
    HELPER="${PROJECT_ROOT}/helpers/latest-gitlab-tag"
    export GITLAB_API_URL="https://gitlab.example/api/v4"
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
    unset GITLAB_API_URL
    unset GITLAB_TOKEN
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
        --connect-timeout|--max-time|--proto|--proto-redir)
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

if [[ -n "${FAKE_CURL_URL_LOG:-}" ]]; then
    printf '%s\n' "$url" >> "$FAKE_CURL_URL_LOG"
fi
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

emit_headers() {
    printf '%s\n' "$1" > "$header_file"
}

case "$mode" in
    happy)
        emit_headers "HTTP/2 200"
        printf '[{"name":"tor-0.4.9.10"},{"name":"tor-0.4.9.11"}]\n'
        ;;
    prerelease)
        emit_headers "HTTP/2 200"
        printf '[{"name":"tor-0.5.0.0-alpha-dev"},{"name":"tor-0.4.9.11"}]\n'
        ;;
    legacy)
        emit_headers "HTTP/2 200"
        printf '[{"name":"obfs4proxy-0.0.14"},{"name":"lyrebird-0.8.0"},{"name":"lyrebird-0.8.1"}]\n'
        ;;
    flag_pattern)
        emit_headers "HTTP/2 200"
        printf '[{"name":"tor-0.4.9.12-rc"},{"name":"tor-0.4.9.11"}]\n'
        ;;
    unsafe_version)
        emit_headers "HTTP/2 200"
        printf '[{"name":"tor-0.4.9|11"}]\n'
        ;;
    paginate)
        if [[ "$url" == *"page=2"* ]]; then
            emit_headers "HTTP/2 200"
            printf '[{"name":"tor-0.4.9.11"}]\n'
        else
            emit_headers 'HTTP/2 200
Link: <https://gitlab.example/api/v4/projects/tpo%2Fcore%2Ftor/repository/tags?page=2>; rel="next"'
            printf '[{"name":"tor-0.5.0.0-alpha-dev"}]\n'
        fi
        ;;
    cross_origin_paginate)
        emit_headers 'HTTP/2 200
Link: <https://evil.example/api/v4/projects/tpo%2Fcore%2Ftor/repository/tags?page=2>; rel="next"'
        printf '[{"name":"tor-0.5.0.0-alpha-dev"}]\n'
        ;;
    terminate)
        kill -TERM "$PPID"
        exit 143
        ;;
    fail)
        exit 22
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
    env PATH="$PATH" GITLAB_API_URL="$GITLAB_API_URL" FAKE_CURL_MODE="${FAKE_CURL_MODE:-}" FAKE_CURL_URL_LOG="${FAKE_CURL_URL_LOG:-}" FAKE_CURL_CONFIG_LOG="${FAKE_CURL_CONFIG_LOG:-}" FAKE_CURL_CONFIG_PATH_LOG="${FAKE_CURL_CONFIG_PATH_LOG:-}" \
        "$HELPER" "$@"
}

last_output_line() {
    printf '%s' "${lines[$((${#lines[@]} - 1))]}"
}

@test "happy path returns latest normalized version and raw tag" {
    write_fake_curl happy

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$' \
        --output both

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = $'0.4.9.11\ttor-0.4.9.11' ]
}

@test "plain project path is encoded in the GitLab API URL" {
    write_fake_curl happy
    FAKE_CURL_URL_LOG="${TEST_TEMP_DIR}/urls.log"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$FAKE_CURL_URL_LOG")" = "https://gitlab.example/api/v4/projects/tpo%2Fcore%2Ftor/repository/tags?order_by=version&sort=desc&per_page=100" ]
}

@test "pre-encoded project path is passed through in the GitLab API URL" {
    write_fake_curl happy
    FAKE_CURL_URL_LOG="${TEST_TEMP_DIR}/urls.log"

    run run_helper "tpo%2Fcore%2Ftor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$FAKE_CURL_URL_LOG")" = "https://gitlab.example/api/v4/projects/tpo%2Fcore%2Ftor/repository/tags?order_by=version&sort=desc&per_page=100" ]
}

@test "pre-encoded project path rejects raw slash mixed with %2F" {
    write_fake_curl happy
    FAKE_CURL_URL_LOG="${TEST_TEMP_DIR}/urls.log"

    run run_helper "tpo%2Fcore/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"encoded project path may contain only"* ]]
    [ ! -s "$FAKE_CURL_URL_LOG" ]
}

@test "prerelease tags are excluded by default" {
    write_fake_curl prerelease

    run run_helper "tpo%2Fcore%2Ftor" \
        --tag-filter '^tor-.*' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?).*$'

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = "0.4.9.11" ]
}

@test "legacy obfs4proxy-prefixed tags are excluded by lyrebird filter" {
    write_fake_curl legacy

    run run_helper "tpo/anti-censorship/pluggable-transports/lyrebird" \
        --tag-filter '^lyrebird-[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^lyrebird-([0-9]+\.[0-9]+\.[0-9]+)$' \
        --output raw

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = "lyrebird-0.8.1" ]
}

@test "tag_filter starting with dash is treated as a regex pattern" {
    write_fake_curl flag_pattern

    run run_helper "tpo/core/tor" \
        --tag-filter '-rc$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)-rc$' \
        --include-prerelease

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = "0.4.9.12" ]
}

@test "malformed tag_filter regex fails loudly instead of no-match fallback" {
    write_fake_curl happy

    run run_helper "tpo/core/tor" \
        --tag-filter '[' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"tag_filter regex '[' failed"* ]]
    [[ "$output" != *"No tags match tag_filter"* ]]
}

@test "unsafe extracted version is rejected before output" {
    write_fake_curl unsafe_version

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-' \
        --version-extract '^tor-(.*)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"Extracted version '0.4.9|11' is not a safe normalized version"* ]]
}

@test "pagination follows GitLab Link header until a matching stable tag is found" {
    write_fake_curl paginate

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = "0.4.9.11" ]
}

@test "pagination rejects cross-origin Link header before following it" {
    write_fake_curl cross_origin_paginate
    export GITLAB_TOKEN="secret"
    FAKE_CURL_URL_LOG="${TEST_TEMP_DIR}/urls.log"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing cross-origin GitLab pagination URL"* ]]
    [ "$(wc -l < "$FAKE_CURL_URL_LOG")" -eq 1 ]
    run grep -q 'evil.example' "$FAKE_CURL_URL_LOG"
    [ "$status" -ne 0 ]
}

@test "GitLab token is attached only for the default allowed API host" {
    write_fake_curl happy
    export GITLAB_TOKEN="secret"
    FAKE_CURL_CONFIG_LOG="${TEST_TEMP_DIR}/curl-config.log"
    GITLAB_API_URL="https://gitlab.torproject.org/api/v4"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 0 ]
    [[ "$output" != *"unbound variable"* ]]
    grep -q 'CONFIG:header = "PRIVATE-TOKEN: secret";' "$FAKE_CURL_CONFIG_LOG"
}

@test "GitLab token curl config is cleaned on interruption" {
    write_fake_curl terminate
    export GITLAB_TOKEN="secret"
    FAKE_CURL_CONFIG_PATH_LOG="${TEST_TEMP_DIR}/curl-config-path.log"
    GITLAB_API_URL="https://gitlab.torproject.org/api/v4"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -ne 0 ]
    config_path="$(head -n 1 "$FAKE_CURL_CONFIG_PATH_LOG")"
    [ -n "$config_path" ]
    [ ! -e "$config_path" ]
}

@test "GitLab token rejects curl config quote injection before curl" {
    write_fake_curl happy
    export GITLAB_TOKEN='bad"token'
    FAKE_CURL_URL_LOG="${TEST_TEMP_DIR}/urls.log"
    GITLAB_API_URL="https://gitlab.torproject.org/api/v4"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"GITLAB_TOKEN must not contain double quotes or control characters"* ]]
    [ ! -e "$FAKE_CURL_URL_LOG" ]
}

@test "GitLab token rejects control characters before curl" {
    write_fake_curl happy
    export GITLAB_TOKEN=$'bad\ntoken'
    FAKE_CURL_URL_LOG="${TEST_TEMP_DIR}/urls.log"
    GITLAB_API_URL="https://gitlab.torproject.org/api/v4"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"GITLAB_TOKEN must not contain double quotes or control characters"* ]]
    [ ! -e "$FAKE_CURL_URL_LOG" ]
}

@test "GitLab token is withheld for custom API hosts" {
    write_fake_curl happy
    export GITLAB_TOKEN="secret"
    FAKE_CURL_CONFIG_LOG="${TEST_TEMP_DIR}/curl-config.log"
    GITLAB_API_URL="https://gitlab.example/api/v4"

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 0 ]
    grep -qx 'CONFIG:' "$FAKE_CURL_CONFIG_LOG"
}

@test "missing tag_filter fails closed" {
    write_fake_curl happy

    run run_helper "tpo/core/tor" \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"--tag-filter is required"* ]]
}

@test "missing version_extract fails closed" {
    write_fake_curl happy

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"--version-extract is required"* ]]
}

@test "missing option values fail with usage errors" {
    run "$HELPER" "tpo/core/tor" --tag-filter
    [ "$status" -eq 1 ]
    [[ "$output" == *"--tag-filter requires a value"* ]]
    [[ "$output" == *"Usage: latest-gitlab-tag"* ]]

    run "$HELPER" "tpo/core/tor" --tag-filter '^tor-' --version-extract
    [ "$status" -eq 1 ]
    [[ "$output" == *"--version-extract requires a value"* ]]
    [[ "$output" == *"Usage: latest-gitlab-tag"* ]]

    run "$HELPER" "tpo/core/tor" --tag-filter '^tor-' --version-extract '^tor-(.*)$' --output
    [ "$status" -eq 1 ]
    [[ "$output" == *"--output requires a value"* ]]
    [[ "$output" == *"Usage: latest-gitlab-tag"* ]]
}

@test "logged dynamic values escape embedded newlines" {
    write_fake_curl happy

    run run_helper "tpo/core/tor" \
        --tag-filter $'does-not-match\n::error::forged' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"does-not-match%0A::error::forged"* ]]
    [[ "$output" != *$'does-not-match\n::error::forged'* ]]
}

@test "GitLab API failure exits 1" {
    write_fake_curl fail

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to fetch GitLab tags"* ]]
}
