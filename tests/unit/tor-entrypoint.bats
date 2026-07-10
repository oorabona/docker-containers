#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    TEST_TEMP_DIR="$(mktemp -d /tmp/tor-entrypoint-bats.XXXXXX)"
    ENTRYPOINT="${PROJECT_ROOT}/tor/entrypoint.sh"
    INTERNAL_GENERATED_DIR="/tmp/tor"
    INTERNAL_GENERATED_MARKER="${INTERNAL_GENERATED_DIR}/.tor-entrypoint-bats"
    SLEEP_PID=""

    if [[ -e "$INTERNAL_GENERATED_DIR" && ! -f "$INTERNAL_GENERATED_MARKER" ]]; then
        skip "${INTERNAL_GENERATED_DIR} exists and is not owned by this test"
    fi
    rm -rf "$INTERNAL_GENERATED_DIR"
    mkdir -p "$INTERNAL_GENERATED_DIR"
    touch "$INTERNAL_GENERATED_MARKER"
}

teardown() {
    if [[ -n "${SLEEP_PID:-}" ]]; then
        kill "$SLEEP_PID" 2>/dev/null || true
        wait "$SLEEP_PID" 2>/dev/null || true
    fi
    if [[ -f "${INTERNAL_GENERATED_MARKER:-}" ]]; then
        rm -rf "$INTERNAL_GENERATED_DIR"
    fi
    rm -rf "$TEST_TEMP_DIR"
}

write_fake_runtime_commands() {
    mkdir -p "${TEST_TEMP_DIR}/bin"

    cat > "${TEST_TEMP_DIR}/bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -u)
        printf '1000\n'
        ;;
    -un)
        printf 'bats\n'
        ;;
    *)
        command id "$@"
        ;;
esac
EOF

    cat > "${TEST_TEMP_DIR}/bin/tor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--hash-password" ]]; then
    if [[ -n "${FAKE_TOR_HASH_LOG:-}" ]]; then
        printf '%s\n' "$*" >> "$FAKE_TOR_HASH_LOG"
    fi
    printf '16:FAKE_HASH\n'
    exit 0
fi

torrc=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f)
            torrc="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

printf 'TOR_STUB_CONFIG=%s\n' "$torrc"
if [[ -n "$torrc" && -f "$torrc" ]] && grep -qx 'CookieAuthentication 0' "$torrc"; then
    printf 'INJECTION_CANARY_COOKIEAUTH_0\n'
fi
EOF

    chmod +x "${TEST_TEMP_DIR}/bin/id" "${TEST_TEMP_DIR}/bin/tor"
    export PATH="${TEST_TEMP_DIR}/bin:$PATH"
}

run_entrypoint() {
    env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        "$ENTRYPOINT" "$@"
}

dockerfile_healthcheck_command() {
    awk '
        /^HEALTHCHECK / { capture = 1; next }
        capture && /^ENTRYPOINT / { exit }
        capture {
            sub(/^[[:space:]]*CMD /, "")
            sub(/[[:space:]]*\\$/, "")
            print
        }
    ' "${PROJECT_ROOT}/tor/Dockerfile" | tr '\n' ' '
}

write_fake_healthcheck_commands() {
    mkdir -p "${TEST_TEMP_DIR}/bin"

    cat > "${TEST_TEMP_DIR}/bin/nc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'nc %s\n' "$*" >> "${FAKE_NC_LOG:?}"
exit "${FAKE_NC_STATUS:-0}"
EOF

    cat > "${TEST_TEMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'curl %s\n' "$*" >> "${FAKE_CURL_LOG:?}"
printf '{"IsTor":true}\n'
EOF

    chmod +x "${TEST_TEMP_DIR}/bin/nc" "${TEST_TEMP_DIR}/bin/curl"
    export PATH="${TEST_TEMP_DIR}/bin:$PATH"
}

write_healthcheck_pid_file() {
    mkdir -p "${TEST_TEMP_DIR}/data"
    sleep 60 &
    SLEEP_PID="$!"
    printf '%s\n' "$SLEEP_PID" > "${TEST_TEMP_DIR}/data/tor.pid"
}

@test "entrypoint rejects exact SOCKS_PORT newline injection payload before torrc generation" {
    write_fake_runtime_commands

    # Regression contract:
    # - Fixed code must fail before execing tor and must name SOCKS_PORT validation.
    # - Original raw interpolation would write a standalone "CookieAuthentication 0"
    #   line from this payload; the tor stub would emit INJECTION_CANARY_COOKIEAUTH_0
    #   and exit 0, making these assertions fail.
    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        SOCKS_PORT=$'9050\nControlPort 0.0.0.0:9051\nCookieAuthentication 0' \
        "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"SOCKS_PORT must not contain control characters"* ]]
    [[ "$output" != *"INJECTION_CANARY_COOKIEAUTH_0"* ]]
}

@test "whitespace-only mounted torrc is treated as inactive and secure simple torrc is generated" {
    write_fake_runtime_commands
    printf ' \n\t\n  # comment only\n' > "${TEST_TEMP_DIR}/torrc"

    run run_entrypoint

    [ "$status" -eq 0 ]
    [[ "$output" == *"TOR_STUB_CONFIG=${INTERNAL_GENERATED_DIR}/torrc"* ]]
    grep -qx 'SocksPort 0.0.0.0:9050' "${INTERNAL_GENERATED_DIR}/torrc"
    grep -qx 'ControlPort 127.0.0.1:9051' "${INTERNAL_GENERATED_DIR}/torrc"
    grep -qx 'CookieAuthentication 1' "${INTERNAL_GENERATED_DIR}/torrc"
}

@test "custom torrc ignores invalid simple-env SOCKS_PORT" {
    write_fake_runtime_commands
    printf 'SocksPort 127.0.0.1:19050\n' > "${TEST_TEMP_DIR}/torrc"

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        SOCKS_PORT="not-a-port" \
        "$ENTRYPOINT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"custom ${TEST_TEMP_DIR}/torrc is active"* ]]
    [[ "$output" == *"TOR_STUB_CONFIG=${TEST_TEMP_DIR}/torrc"* ]]
    grep -qx 'DataDirectory '"${TEST_TEMP_DIR}"'/data' "${INTERNAL_GENERATED_DIR}/defaults-torrc"
}

@test "runtime path validation rejects sensitive DATA_DIR paths before directory ownership changes" {
    write_fake_runtime_commands

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="/" \
        "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"DATA_DIR must not be the filesystem root"* ]]

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="/etc" \
        "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"DATA_DIR must not be a sensitive system path: /etc"* ]]
}

@test "runtime path validation rejects sensitive descendants but allows tor data descendants" {
    local rejected

    for rejected in /etc/ssl /root/.ssh /var/lib; do
        run bash -c 'source "$1"; DATA_DIR="$2"; validate_runtime_paths' _ "$ENTRYPOINT" "$rejected"
        [ "$status" -ne 0 ]
        [[ "$output" == *"DATA_DIR must not be a sensitive system path"* ]]
    done

    run bash -c 'source "$1"; DATA_DIR="/var/lib/tor/custom"; validate_runtime_paths' _ "$ENTRYPOINT"

    [ "$status" -eq 0 ]
}

@test "generated torrc path is internal and written with restrictive permissions" {
    write_fake_runtime_commands
    printf 'secret\n' > "${TEST_TEMP_DIR}/control-password"

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        GENERATED_DIR="/" \
        GENERATED_TORRC="/etc/torrc" \
        DEFAULTS_TORRC="/etc/defaults-torrc" \
        PASSWORD_FILE="${TEST_TEMP_DIR}/control-password" \
        "$ENTRYPOINT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"TOR_STUB_CONFIG=${INTERNAL_GENERATED_DIR}/torrc"* ]]
    grep -qx 'HashedControlPassword 16:FAKE_HASH' "${INTERNAL_GENERATED_DIR}/torrc"
    [ "$(stat -c '%a' "${INTERNAL_GENERATED_DIR}/torrc")" = "600" ]
    [ "$(stat -c '%a' "${INTERNAL_GENERATED_DIR}")" = "700" ]
}

@test "pre-hashed PASSWORD_FILE is used directly without invoking hash helper" {
    write_fake_runtime_commands
    local hashed_password="16:0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    printf '%s\n' "$hashed_password" > "${TEST_TEMP_DIR}/control-password"
    export FAKE_TOR_HASH_LOG="${TEST_TEMP_DIR}/hash.log"

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        PASSWORD_FILE="${TEST_TEMP_DIR}/control-password" \
        FAKE_TOR_HASH_LOG="$FAKE_TOR_HASH_LOG" \
        "$ENTRYPOINT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"TOR_STUB_CONFIG=${INTERNAL_GENERATED_DIR}/torrc"* ]]
    grep -qx "HashedControlPassword ${hashed_password}" "${INTERNAL_GENERATED_DIR}/torrc"
    [ ! -e "$FAKE_TOR_HASH_LOG" ]
}

@test "unreadable custom torrc fails loudly instead of falling back to generated defaults" {
    write_fake_runtime_commands
    printf 'SocksPort 127.0.0.1:19050\n' > "${TEST_TEMP_DIR}/torrc"
    chmod 000 "${TEST_TEMP_DIR}/torrc"

    run run_entrypoint

    [ "$status" -ne 0 ]
    [[ "$output" == *"could not read TORRC_PATH: ${TEST_TEMP_DIR}/torrc"* ]]
    [[ "$output" != *"TOR_STUB_CONFIG=${INTERNAL_GENERATED_DIR}/torrc"* ]]
}

@test "validate_bind_address accepts IPv4-mapped IPv6 address" {
    run bash -c 'source "$1"; validate_bind_address SOCKS_BIND "::ffff:192.0.2.1"' _ "$ENTRYPOINT"

    [ "$status" -eq 0 ]
}

@test "healthcheck accepts custom torrc with SocksPort disabled without probing SOCKS" {
    write_fake_healthcheck_commands
    write_healthcheck_pid_file
    printf 'SocksPort 0\n' > "${TEST_TEMP_DIR}/torrc"
    local healthcheck
    healthcheck="$(dockerfile_healthcheck_command)"
    export FAKE_NC_LOG="${TEST_TEMP_DIR}/nc.log"
    export FAKE_NC_STATUS=99
    export FAKE_CURL_LOG="${TEST_TEMP_DIR}/curl.log"

    run env \
        PATH="$PATH" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        CHECK=false \
        sh -c "$healthcheck"

    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_NC_LOG" ]
}

@test "healthcheck probes SOCKS for simple env-driven configuration" {
    write_fake_healthcheck_commands
    write_healthcheck_pid_file
    local healthcheck
    healthcheck="$(dockerfile_healthcheck_command)"
    export FAKE_NC_LOG="${TEST_TEMP_DIR}/nc.log"
    export FAKE_NC_STATUS=0
    export FAKE_CURL_LOG="${TEST_TEMP_DIR}/curl.log"

    run env \
        PATH="$PATH" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        TORRC_PATH="${TEST_TEMP_DIR}/missing-torrc" \
        SOCKS_PORT=19050 \
        CHECK=false \
        sh -c "$healthcheck"

    [ "$status" -eq 0 ]
    grep -qx 'nc -z 127.0.0.1 19050' "$FAKE_NC_LOG"
}

@test "healthcheck probes IPv6 loopback for IPv6 wildcard SOCKS bind" {
    write_fake_healthcheck_commands
    write_healthcheck_pid_file
    local healthcheck
    healthcheck="$(dockerfile_healthcheck_command)"
    export FAKE_NC_LOG="${TEST_TEMP_DIR}/nc.log"
    export FAKE_NC_STATUS=0
    export FAKE_CURL_LOG="${TEST_TEMP_DIR}/curl.log"

    run env \
        PATH="$PATH" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        TORRC_PATH="${TEST_TEMP_DIR}/missing-torrc" \
        SOCKS_BIND="::" \
        SOCKS_PORT=19050 \
        CHECK=false \
        sh -c "$healthcheck"

    [ "$status" -eq 0 ]
    grep -qx 'nc -z ::1 19050' "$FAKE_NC_LOG"
}
