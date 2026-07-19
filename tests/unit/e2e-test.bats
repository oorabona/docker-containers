#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    ORIG_PATH="$PATH"
    FIXTURE_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$FIXTURE_REPO/tests" "$FIXTURE_REPO/helpers"
    cp "$PROJECT_ROOT/tests/e2e-test.sh" "$FIXTURE_REPO/tests/e2e-test.sh"
    cp "$PROJECT_ROOT/helpers/logging.sh" "$FIXTURE_REPO/helpers/logging.sh"
    cp "$PROJECT_ROOT/helpers/variant-utils.sh" "$FIXTURE_REPO/helpers/variant-utils.sh"
    chmod +x "$FIXTURE_REPO/tests/e2e-test.sh"
}

teardown() {
    export PATH="$ORIG_PATH"
    unset E2E_IMAGE DOCKER_LOG DOCKER_IMAGES_OUTPUT DOCKER_PS_OUTPUT TEST_SCRIPT_MARKER
    teardown_temp_dir
}

install_docker_stub() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    images)
        printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}"
        ;;
    inspect)
        printf '%s\n' "none"
        ;;
    ps)
        printf '%s\n' "${DOCKER_PS_OUTPUT:-e2e-openvpn}"
        ;;
    rm|run|logs|exec)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"

    cat > "$TEST_TEMP_DIR/bin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

add_openvpn_fixture() {
    mkdir -p "$FIXTURE_REPO/openvpn"
    cat > "$FIXTURE_REPO/openvpn/variants.yaml" <<'YAML'
versions:
  - tag: v2.7.5-alpine
YAML
    cat > "$FIXTURE_REPO/openvpn/test.sh" <<'SH'
#!/bin/bash
printf '%s\n' "${CONTAINER_NAME:-}" > "${TEST_SCRIPT_MARKER:?}"
SH
    chmod +x "$FIXTURE_REPO/openvpn/test.sh"
}

@test "S2: helper sourcing resolves from repo root" {
    run "$FIXTURE_REPO/tests/e2e-test.sh" --help

    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-build"* ]]
}

@test "S3/AD3: E2E_IMAGE bypasses variant routing but still applies openvpn run profile and test.sh" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_SCRIPT_MARKER")" = "e2e-openvpn" ]

    run_line=$(grep '^run ' "$DOCKER_LOG")
    [[ "$run_line" == *"--cap-drop ALL"* ]]
    [[ "$run_line" == *"--cap-add NET_ADMIN"* ]]
    [[ "$run_line" == *"--cap-add SETUID"* ]]
    [[ "$run_line" == *"--cap-add SETGID"* ]]
    [[ "$run_line" == *"--device /dev/net/tun:/dev/net/tun"* ]]
    [[ "$run_line" == *"-e AUTO_INSTALL=y"* ]]
    [[ "$run_line" == *"-e AUTO_START=y"* ]]
    [[ "$run_line" == *"ghcr.io/example/openvpn:e2e"* ]]
    ! grep -q '^images ' "$DOCKER_LOG"
}

@test "S6: fallback image discovery errors on zero matches" {
    mkdir -p "$FIXTURE_REPO/debian"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=""

    run "$FIXTURE_REPO/tests/e2e-test.sh" --no-build debian

    [ "$status" -eq 1 ]
    [[ "$output" == *"No image found for debian"* ]]
    ! grep -q '^run ' "$DOCKER_LOG"
}

@test "S6: fallback image discovery errors on ambiguous image IDs" {
    mkdir -p "$FIXTURE_REPO/debian"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=$'sha111 ghcr.io/oorabona/debian:trixie\nsha222 docker.io/oorabona/debian:bookworm'

    run "$FIXTURE_REPO/tests/e2e-test.sh" --no-build debian

    [ "$status" -eq 1 ]
    [[ "$output" == *"Ambiguous local images for debian"* ]]
    ! grep -q '^run ' "$DOCKER_LOG"
}

@test "sslh run profile: args-only command, port 443, NET_BIND_SERVICE (entrypoint+healthcheck match)" {
    mkdir -p "$FIXTURE_REPO/sslh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_PS_OUTPUT="e2e-sslh"
    export E2E_IMAGE="ghcr.io/example/sslh:e2e"

    run "$FIXTURE_REPO/tests/e2e-test.sh" sslh

    [ "$status" -eq 0 ]
    run_line=$(grep '^run ' "$DOCKER_LOG")
    # image ENTRYPOINT is sslh-ev → command is ARGS ONLY (no re-specified binary)
    [[ "$run_line" == *"--foreground"* ]]
    [[ "$run_line" != *"sslh-ev --foreground"* ]]
    # front port 443 to match the image HEALTHCHECK (nc -z 443), not 8443
    [[ "$run_line" == *"-p 0.0.0.0:443"* ]]
    [[ "$run_line" != *"0.0.0.0:8443"* ]]
    # nobody must be able to bind the privileged port
    [[ "$run_line" == *"--cap-add NET_BIND_SERVICE"* ]]
}

@test "sslh/test.sh proves liveness without pgrep (scratch image lacks it)" {
    # The sslh image is FROM scratch: no pgrep. The smoke check must use the
    # busybox nc applet that ships in the image, not pgrep.
    ! grep -qE '\bpgrep\b' "$PROJECT_ROOT/sslh/test.sh"
    grep -q '/bin/busybox nc' "$PROJECT_ROOT/sslh/test.sh"
}
