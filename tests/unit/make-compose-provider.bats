#!/usr/bin/env bats

# Exercise the real `make` entry point with no compose provider on PATH.
bats_require_minimum_version 1.5.0
load "../test_helper"

setup() {
    setup_temp_dir
    export COMPOSE_FREE_PATH="$TEST_TEMP_DIR/bin"
    mkdir -p "$COMPOSE_FREE_PATH"

    # `make` only needs these system utilities while loading and listing. Keep
    # the controlled PATH free of docker, docker-compose, and podman-compose.
    local command_name
    for command_name in dirname nproc find sed cut sort ls; do
        ln -s "$(command -v "$command_name")" "$COMPOSE_FREE_PATH/$command_name"
    done
}

teardown() {
    teardown_temp_dir
}

run_make_with_controlled_path() {
    run --separate-stderr bash -c 'cd "$1" || exit 1; PATH="$2"; export PATH; shift 2; exec /bin/bash ./make "$@"' \
        _ "$PROJECT_ROOT" "$COMPOSE_FREE_PATH" "$@"
}

@test "make list works without a compose provider" {
    run_make_with_controlled_path list

    [ "$status" -eq 0 ]
    [ "$output" = $'ansible\ndebian\ngithub-runner\njekyll\nopenresty\nopenvpn\nphp\npostgres\nsslh\nterraform\ntor\nvector\nweb-shell\nwordpress' ]
    [ -z "$stderr" ]
}

@test "make run refuses to proceed when no compose provider is available" {
    run_make_with_controlled_path run ansible

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"docker compose"* ]]
    [[ "$stderr" == *"podman-compose"* ]]
    [[ "$stderr" != *"docker-compose"* ]]
    [[ "$stderr" != *"Running ansible"* ]]
}

@test "make run refuses a working docker-compose binary when no supported provider is available" {
    cat > "$COMPOSE_FREE_PATH/docker-compose" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-compose-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-compose-args"
EOF
    chmod +x "$COMPOSE_FREE_PATH/docker-compose"

    run_make_with_controlled_path run ansible

    [ "$status" -ne 0 ]
    [ ! -e "$TEST_TEMP_DIR/docker-compose-args" ]
    [[ "$stderr" == *"No compose provider found"* ]]
    [[ "$stderr" != *"docker-compose"* ]]
}

@test "make run selects docker compose over a working docker-compose binary" {
    cat > "$COMPOSE_FREE_PATH/docker-compose" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-compose-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-compose-args"
EOF
    cat > "$COMPOSE_FREE_PATH/docker" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-args"
EOF
    chmod +x "$COMPOSE_FREE_PATH/docker-compose" "$COMPOSE_FREE_PATH/docker"

    run_make_with_controlled_path run ansible

    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/docker-compose-args" ]
    [ "$(sed -n '1p' "$TEST_TEMP_DIR/docker-args")" = "<compose><version>" ]
    [ "$(sed -n '2p' "$TEST_TEMP_DIR/docker-args")" = "<compose><run><--rm><ansible>" ]
    [[ "$stderr" == *"Found 'docker compose', continuing."* ]]
}

@test "make run accepts a podman-compose provider and passes its exact arguments" {
    cat > "$COMPOSE_FREE_PATH/podman-compose" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/podman-compose-args"
printf '\n' >> "$TEST_TEMP_DIR/podman-compose-args"
EOF
    chmod +x "$COMPOSE_FREE_PATH/podman-compose"

    run_make_with_controlled_path run ansible

    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$TEST_TEMP_DIR/podman-compose-args")" = "<version>" ]
    [ "$(sed -n '2p' "$TEST_TEMP_DIR/podman-compose-args")" = "<run><--rm><ansible>" ]
    [[ "$stderr" == *"Found 'podman-compose', continuing."* ]]
}

@test "make run selects docker compose without executing an irrelevant docker-compose binary" {
    cat > "$COMPOSE_FREE_PATH/docker-compose" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-compose-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-compose-args"
exit 1
EOF
    cat > "$COMPOSE_FREE_PATH/docker" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-args"
EOF
    chmod +x "$COMPOSE_FREE_PATH/docker-compose" "$COMPOSE_FREE_PATH/docker"

    run_make_with_controlled_path run ansible

    [ "$status" -eq 0 ]
    [ ! -e "$TEST_TEMP_DIR/docker-compose-args" ]
    [ "$(sed -n '1p' "$TEST_TEMP_DIR/docker-args")" = "<compose><version>" ]
    [ "$(sed -n '2p' "$TEST_TEMP_DIR/docker-args")" = "<compose><run><--rm><ansible>" ]
    [[ "$stderr" == *"Found 'docker compose', continuing."* ]]
}

@test "sourcing sbom-utils preserves the caller's shell options" {
    run bash -c '
        set +e
        set -u
        set -o pipefail
        source "$1" || exit 1
        case "$-" in *e*) exit 1 ;; esac
        [[ "$(set -o | awk "\$1 == \"nounset\" { print \$2 }")" == on ]]
        [[ "$(set -o | awk "\$1 == \"pipefail\" { print \$2 }")" == on ]]
    ' _ "$PROJECT_ROOT/helpers/sbom-utils.sh"

    [ "$status" -eq 0 ]
}

@test "sourcing sbom-utils fails when retry utilities cannot be loaded" {
    mkdir -p "$TEST_TEMP_DIR/helpers"
    cp "$PROJECT_ROOT/helpers/sbom-utils.sh" "$TEST_TEMP_DIR/helpers/sbom-utils.sh"

    run bash -c 'source "$1"' _ "$TEST_TEMP_DIR/helpers/sbom-utils.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to load retry utilities"* ]]
}

@test "sourcing sbom-utils fails when logging utilities cannot be loaded" {
    mkdir -p "$TEST_TEMP_DIR/helpers"
    cp "$PROJECT_ROOT/helpers/sbom-utils.sh" "$PROJECT_ROOT/helpers/retry.sh" "$PROJECT_ROOT/helpers/logging.sh" \
        "$TEST_TEMP_DIR/helpers/"
    chmod 000 "$TEST_TEMP_DIR/helpers/logging.sh"

    run bash -c '
        log_error() { printf "caller log: %s\\n" "$*"; }
        source "$1"
    ' _ "$TEST_TEMP_DIR/helpers/sbom-utils.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to load logging utilities"* ]]
}

@test "install_syft fails and does not claim success when its download fails" {
    local helper_bin="$TEST_TEMP_DIR/helper-bin"
    mkdir -p "$helper_bin"
    ln -s "$(command -v dirname)" "$helper_bin/dirname"
    ln -s "$(command -v sh)" "$helper_bin/sh"
    cat > "$helper_bin/curl" <<'EOF'
#!/bin/sh
exit 22
EOF
    chmod +x "$helper_bin/curl"

    run bash -c 'PATH="$2"; export PATH; source "$1" || exit 1; install_syft' _ "$PROJECT_ROOT/helpers/sbom-utils.sh" "$helper_bin"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to install syft"* ]]
    [[ "$output" != *"installed successfully"* ]]
    [[ "$output" != *"installed to ~/.local/bin"* ]]
}

@test "install_syft does not download again after a successful system install outside PATH" {
    local helper_bin="$TEST_TEMP_DIR/helper-bin"
    local install_calls="$TEST_TEMP_DIR/install-calls"
    mkdir -p "$helper_bin"
    ln -s "$(command -v dirname)" "$helper_bin/dirname"
    cat > "$helper_bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' curl >> "$SYFT_INSTALL_CALLS"
printf 'stub installer\n'
EOF
    cat > "$helper_bin/sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$4" >> "$SYFT_INSTALL_CALLS"
if [ "$4" = /usr/local/bin ]; then
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/syft
    /bin/chmod +x /usr/local/bin/syft
else
    /bin/mkdir -p "$4"
    printf '#!/bin/sh\nexit 0\n' > "$4/syft"
    /bin/chmod +x "$4/syft"
fi
exit 0
EOF
    chmod +x "$helper_bin/curl" "$helper_bin/sh"

    if ! unshare -Urnm bash -c 'mount -t tmpfs tmpfs /usr/local/bin'; then
        skip "user namespace with private mount not available"
    fi

    run unshare -Urnm bash -c '
        mount -t tmpfs tmpfs /usr/local/bin || exit 1
        PATH="$2"; export PATH
        SYFT_INSTALL_CALLS="$3"; export SYFT_INSTALL_CALLS
        HOME="$(dirname "$3")/home"; export HOME
        source "$1" || exit 1
        install_syft
    ' _ "$PROJECT_ROOT/helpers/sbom-utils.sh" "$helper_bin" "$install_calls"

    [ "$status" -eq 0 ]
    [ "$(wc -l < "$install_calls")" -eq 2 ]
    [ "$(sed -n '1p' "$install_calls")" = "curl" ]
    [ "$(sed -n '2p' "$install_calls")" = "/usr/local/bin" ]
    [[ "$output" == *"installed successfully"* ]]
    [[ "$output" != *"installed to ~/.local/bin"* ]]
}
