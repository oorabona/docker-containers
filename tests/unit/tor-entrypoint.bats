#!/usr/bin/env bats

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    TEST_TEMP_DIR="$(mktemp -d)"
    ENTRYPOINT="${PROJECT_ROOT}/tor/entrypoint.sh"
}

teardown() {
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
        GENERATED_DIR="${TEST_TEMP_DIR}/generated" \
        GENERATED_TORRC="${TEST_TEMP_DIR}/generated/torrc" \
        DEFAULTS_TORRC="${TEST_TEMP_DIR}/generated/defaults-torrc" \
        "$ENTRYPOINT" "$@"
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
        GENERATED_DIR="${TEST_TEMP_DIR}/generated" \
        GENERATED_TORRC="${TEST_TEMP_DIR}/generated/torrc" \
        DEFAULTS_TORRC="${TEST_TEMP_DIR}/generated/defaults-torrc" \
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
    [[ "$output" == *"TOR_STUB_CONFIG=${TEST_TEMP_DIR}/generated/torrc"* ]]
    grep -qx 'SocksPort 0.0.0.0:9050' "${TEST_TEMP_DIR}/generated/torrc"
    grep -qx 'ControlPort 127.0.0.1:9051' "${TEST_TEMP_DIR}/generated/torrc"
    grep -qx 'CookieAuthentication 1' "${TEST_TEMP_DIR}/generated/torrc"
}

@test "custom torrc ignores invalid simple-env SOCKS_PORT" {
    write_fake_runtime_commands
    printf 'SocksPort 127.0.0.1:19050\n' > "${TEST_TEMP_DIR}/torrc"

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        GENERATED_DIR="${TEST_TEMP_DIR}/generated" \
        GENERATED_TORRC="${TEST_TEMP_DIR}/generated/torrc" \
        DEFAULTS_TORRC="${TEST_TEMP_DIR}/generated/defaults-torrc" \
        SOCKS_PORT="not-a-port" \
        "$ENTRYPOINT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"custom ${TEST_TEMP_DIR}/torrc is active"* ]]
    [[ "$output" == *"TOR_STUB_CONFIG=${TEST_TEMP_DIR}/torrc"* ]]
    grep -qx 'DataDirectory '"${TEST_TEMP_DIR}"'/data' "${TEST_TEMP_DIR}/generated/defaults-torrc"
}

@test "runtime path validation rejects filesystem root before directory ownership changes" {
    write_fake_runtime_commands

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="/" \
        GENERATED_DIR="${TEST_TEMP_DIR}/generated" \
        GENERATED_TORRC="${TEST_TEMP_DIR}/generated/torrc" \
        DEFAULTS_TORRC="${TEST_TEMP_DIR}/generated/defaults-torrc" \
        "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"DATA_DIR must not be the filesystem root"* ]]

    run env \
        PATH="$PATH" \
        TORRC_PATH="${TEST_TEMP_DIR}/torrc" \
        DATA_DIR="${TEST_TEMP_DIR}/data" \
        GENERATED_DIR="/" \
        GENERATED_TORRC="${TEST_TEMP_DIR}/generated/torrc" \
        DEFAULTS_TORRC="${TEST_TEMP_DIR}/generated/defaults-torrc" \
        "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"GENERATED_DIR must not be the filesystem root"* ]]
}
