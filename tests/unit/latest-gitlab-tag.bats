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
}

write_fake_curl() {
    local mode="$1"

    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${FAKE_CURL_MODE:?}"
header_file=""
url=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -D)
            header_file="$2"
            shift 2
            ;;
        --connect-timeout|--max-time|--proto|--proto-redir|--config)
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
    env PATH="$PATH" GITLAB_API_URL="$GITLAB_API_URL" FAKE_CURL_MODE="${FAKE_CURL_MODE:-}" \
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

@test "pagination follows GitLab Link header until a matching stable tag is found" {
    write_fake_curl paginate

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 0 ]
    [ "$(last_output_line)" = "0.4.9.11" ]
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

@test "GitLab API failure exits 1" {
    write_fake_curl fail

    run run_helper "tpo/core/tor" \
        --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$'

    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to fetch GitLab tags"* ]]
}
