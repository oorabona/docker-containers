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
    [[ "$stderr" == *"docker-compose"* ]]
    [[ "$stderr" == *"docker compose"* ]]
    [[ "$stderr" == *"podman-compose"* ]]
    [[ "$stderr" != *"Running ansible"* ]]
}

@test "make run accepts a docker-compose provider on PATH" {
    cat > "$COMPOSE_FREE_PATH/docker-compose" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-compose-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-compose-args"
EOF
    chmod +x "$COMPOSE_FREE_PATH/docker-compose"

    run_make_with_controlled_path run ansible

    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/docker-compose-args" ]
    [ "$(sed -n '1p' "$TEST_TEMP_DIR/docker-compose-args")" = "<version>" ]
    [ "$(sed -n '2p' "$TEST_TEMP_DIR/docker-compose-args")" = "<run><--rm><ansible>" ]
    [[ "$stderr" == *"Found 'docker-compose', continuing."* ]]
    [[ "$stderr" != *"No compose provider found"* ]]
}

@test "make run accepts a docker compose provider and passes its exact arguments" {
    cat > "$COMPOSE_FREE_PATH/docker" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >> "$TEST_TEMP_DIR/docker-args"
printf '\n' >> "$TEST_TEMP_DIR/docker-args"
EOF
    chmod +x "$COMPOSE_FREE_PATH/docker"

    run_make_with_controlled_path run ansible

    [ "$status" -eq 0 ]
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

@test "make run skips a provider whose probe fails and selects the next usable provider" {
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
    [ "$(cat "$TEST_TEMP_DIR/docker-compose-args")" = "<version>" ]
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
    printf 'return 1\n' > "$TEST_TEMP_DIR/helpers/logging.sh"

    run bash -c '
        log_error() { printf "caller log: %s\\n" "$*"; }
        source "$1"
    ' _ "$TEST_TEMP_DIR/helpers/sbom-utils.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to load logging utilities"* ]]
}

make_syft_archive() {
    local archive="$1"
    local reported_version="$2"
    local version_status="${3:-0}"
    local archive_dir="$TEST_TEMP_DIR/syft-archive"

    mkdir -p "$archive_dir"
    cat > "$archive_dir/syft" <<EOF
#!/bin/sh
if [ "\$1" = version ]; then
    printf '%s\\n' 'Application: syft' 'Version: ${reported_version}'
    exit ${version_status}
fi
EOF
    chmod +x "$archive_dir/syft"
    tar --owner=0 --group=0 -czf "$archive" -C "$archive_dir" syft
    sha256sum "$archive" | awk '{print $1}'
}

copy_sbom_utils_with_archive_digest() {
    local archive_digest="$1"
    local helper_dir="$TEST_TEMP_DIR/helpers"

    mkdir -p "$helper_dir"
    sed \
        -e "s/989ded4e772810f93de6ccdc4512f79a6dabb5fb2dd2a9ffc72a80c955e6125a/${archive_digest}/" \
        -e "s/dfc9ac5fffa8fea95b4f84b427e200dbb2bd9bd0bbf2760d1a9369715b60a91d/${archive_digest}/" \
        -e "s/1e52e39d24a4eaec94329e0f3283c448e2ee8f79dc03e5f1e405d324b7ae4e1c/${archive_digest}/" \
        -e "s/b83cdcbd1b4c55505abd359c25c5903d94b99be47e6f98572bf96927b7b47e45/${archive_digest}/" \
        "$PROJECT_ROOT/helpers/sbom-utils.sh" > "$helper_dir/sbom-utils.sh"
    cp "$PROJECT_ROOT/helpers/retry.sh" "$helper_dir/retry.sh"
    printf '%s\n' "$helper_dir/sbom-utils.sh"
}

make_syft_helper_bin() {
    local helper_bin="$TEST_TEMP_DIR/helper-bin"
    local command_name

    mkdir -p "$helper_bin"
    for command_name in dirname uname mktemp rm sha256sum tar gzip install mkdir mv; do
        ln -s "$(command -v "$command_name")" "$helper_bin/$command_name"
    done
    cat > "$helper_bin/curl" <<'EOF'
#!/bin/sh
destination=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        destination="$1"
    fi
    shift
done
if [ "${SYFT_ALTERED_BYTES:-false}" = true ]; then
    /bin/cp "$SYFT_ALTERED_ARCHIVE" "$destination"
else
    /bin/cp "$SYFT_TEST_ARCHIVE" "$destination"
fi
EOF
    chmod +x "$helper_bin/curl"
    printf '%s\n' "$helper_bin"
}

make_syft_platform_helper_bin() {
    local helper_bin

    helper_bin=$(make_syft_helper_bin)
    rm "$helper_bin/sha256sum" "$helper_bin/tar" "$helper_bin/uname"
    cat > "$helper_bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) printf '%s\n' "$SYFT_UNAME_S" ;;
    -m) printf '%s\n' "$SYFT_UNAME_M" ;;
    *) exit 1 ;;
esac
EOF
    cat > "$helper_bin/curl" <<'EOF'
#!/bin/sh
destination=""
curl_args="$*"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        destination="$1"
    fi
    shift
done
printf '%s\n' "$curl_args" > "$SYFT_CURL_ARGS"
: > "$destination"
EOF
    cat > "$helper_bin/sha256sum" <<'EOF'
#!/bin/sh
IFS= read -r digest_input
printf '%s\n' "$digest_input" > "$SYFT_DIGEST_INPUT"
EOF
    cat > "$helper_bin/tar" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$helper_bin/uname" "$helper_bin/curl" "$helper_bin/sha256sum" "$helper_bin/tar"
    printf '%s\n' "$helper_bin"
}

@test "install_syft selects the pinned asset and digest for every supported platform" {
    local helper_bin os arch asset digest curl_args digest_input
    helper_bin=$(make_syft_platform_helper_bin)

    while IFS='|' read -r os arch asset digest; do
        curl_args="$TEST_TEMP_DIR/${os}-${arch}-curl-args"
        digest_input="$TEST_TEMP_DIR/${os}-${arch}-digest-input"

        run bash -c '
            PATH="$2"; export PATH
            SYFT_UNAME_S="$3"; export SYFT_UNAME_S
            SYFT_UNAME_M="$4"; export SYFT_UNAME_M
            SYFT_CURL_ARGS="$5"; export SYFT_CURL_ARGS
            SYFT_DIGEST_INPUT="$6"; export SYFT_DIGEST_INPUT
            source "$1" || exit 1
            install_syft
        ' _ "$PROJECT_ROOT/helpers/sbom-utils.sh" "$helper_bin" "$os" "$arch" "$curl_args" "$digest_input"

        [ "$status" -ne 0 ]
        [[ "$output" == *"Failed to extract verified syft"* ]]
        grep -Fq "$asset" "$curl_args"
        [ "$(awk '{print $1}' "$digest_input")" = "$digest" ]
    done <<'EOF'
Linux|x86_64|syft_1.42.1_linux_amd64.tar.gz|989ded4e772810f93de6ccdc4512f79a6dabb5fb2dd2a9ffc72a80c955e6125a
Linux|arm64|syft_1.42.1_linux_arm64.tar.gz|dfc9ac5fffa8fea95b4f84b427e200dbb2bd9bd0bbf2760d1a9369715b60a91d
Darwin|x86_64|syft_1.42.1_darwin_amd64.tar.gz|1e52e39d24a4eaec94329e0f3283c448e2ee8f79dc03e5f1e405d324b7ae4e1c
Darwin|arm64|syft_1.42.1_darwin_arm64.tar.gz|b83cdcbd1b4c55505abd359c25c5903d94b99be47e6f98572bf96927b7b47e45
EOF
}

@test "install_syft refuses an unsupported platform" {
    local helper_bin
    helper_bin=$(make_syft_platform_helper_bin)

    run bash -c '
        PATH="$2"; export PATH
        SYFT_UNAME_S="FreeBSD"; export SYFT_UNAME_S
        SYFT_UNAME_M="x86_64"; export SYFT_UNAME_M
        source "$1" || exit 1
        install_syft
    ' _ "$PROJECT_ROOT/helpers/sbom-utils.sh" "$helper_bin"

    [ "$status" -ne 0 ]
    [[ "$output" == *"No verified syft 1.42.1 release asset for FreeBSD/x86_64"* ]]
}

@test "install_syft refuses altered bytes before installing anything" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local altered_archive="$TEST_TEMP_DIR/altered-syft.tar.gz"
    local archive_digest helper helper_bin install_calls home_dir
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test")
    make_syft_archive "$altered_archive" "9.9.8-altered" >/dev/null
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    install_calls="$TEST_TEMP_DIR/install-calls"
    home_dir="$TEST_TEMP_DIR/home"
    rm "$helper_bin/install"
    cat > "$helper_bin/install" <<'EOF'
#!/bin/sh
printf 'install called\n' > "$SYFT_INSTALL_CALLS"
exit 1
EOF
    chmod +x "$helper_bin/install"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$6"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        SYFT_ALTERED_ARCHIVE="$4"; export SYFT_ALTERED_ARCHIVE
        SYFT_ALTERED_BYTES=true; export SYFT_ALTERED_BYTES
        SYFT_INSTALL_CALLS="$5"; export SYFT_INSTALL_CALLS
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$altered_archive" "$install_calls" "$home_dir"

    [ "$status" -ne 0 ]
    [ ! -e "$install_calls" ]
    [ ! -e "$home_dir/.local/bin/syft" ]
    [[ "$output" == *"failed SHA-256 verification"* ]]
    [[ "$output" != *"installed successfully"* ]]
}

@test "install_syft refuses altered bytes with the shasum fallback before installing anything" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local altered_archive="$TEST_TEMP_DIR/altered-syft.tar.gz"
    local archive_digest helper helper_bin install_calls home_dir sha256sum_path
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test")
    make_syft_archive "$altered_archive" "9.9.8-altered" >/dev/null
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    install_calls="$TEST_TEMP_DIR/install-calls"
    home_dir="$TEST_TEMP_DIR/home"
    sha256sum_path=$(command -v sha256sum)
    rm "$helper_bin/sha256sum" "$helper_bin/install"
    cat > "$helper_bin/shasum" <<EOF
#!/bin/sh
exec "${sha256sum_path}" "\$3"
EOF
    cat > "$helper_bin/install" <<'EOF'
#!/bin/sh
printf 'install called\n' > "$SYFT_INSTALL_CALLS"
exit 1
EOF
    chmod +x "$helper_bin/shasum" "$helper_bin/install"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$6"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        SYFT_ALTERED_ARCHIVE="$4"; export SYFT_ALTERED_ARCHIVE
        SYFT_ALTERED_BYTES=true; export SYFT_ALTERED_BYTES
        SYFT_INSTALL_CALLS="$5"; export SYFT_INSTALL_CALLS
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$altered_archive" "$install_calls" "$home_dir"

    [ "$status" -ne 0 ]
    [ ! -e "$install_calls" ]
    [ ! -e "$home_dir/.local/bin/syft" ]
    [[ "$output" == *"failed SHA-256 verification"* ]]
    [[ "$output" != *"installed successfully"* ]]
}

@test "install_syft logs the version reported by the verified installed binary" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test")
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)

    run unshare -Urnm bash -c '
        mount -t tmpfs tmpfs /usr/local/bin || exit 1
        PATH="$2"; export PATH
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        HOME="$4"; export HOME
        source "$1" || exit 1
        install_syft
        test -x /usr/local/bin/syft
    ' _ "$helper" "$helper_bin" "$archive" "$TEST_TEMP_DIR/home"

    [ "$status" -eq 0 ]
    [[ "$output" == *"syft 9.9.9-test installed successfully"* ]]
    [[ "$output" != *"syft ${SYFT_VERSION:-1.42.1} installed successfully"* ]]
}

@test "install_syft falls back to the user directory and exports PATH when the system directory is unavailable" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test")
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    rm "$helper_bin/install"
    cat > "$helper_bin/install" <<'EOF'
#!/bin/sh
destination=""
for argument in "$@"; do
    destination="$argument"
done
if [ "$destination" = /usr/local/bin/syft ]; then
    exit 1
fi
exec /usr/bin/install "$@"
EOF
    chmod +x "$helper_bin/install"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$4"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        source "$1" || exit 1
        install_syft || exit 1
        test -x "$HOME/.local/bin/syft"
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) ;;
            *) exit 1 ;;
        esac
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"syft 9.9.9-test installed successfully"* ]]
}

@test "install_syft leaves no new destination binary when validation fails" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test" 1)
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    rm "$helper_bin/install"
    cat > "$helper_bin/install" <<'EOF'
#!/bin/sh
destination=""
for argument in "$@"; do
    destination="$argument"
done
case "$destination" in
    /usr/local/bin/syft.tmp.*) exit 1 ;;
esac
exec /usr/bin/install "$@"
EOF
    chmod +x "$helper_bin/install"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$4"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir"

    [ "$status" -ne 0 ]
    [ ! -e "$home_dir/.local/bin/syft" ]
    [ -z "$(find "$home_dir/.local/bin" -name 'syft.tmp.*' -print -quit 2>/dev/null)" ]
    [[ "$output" == *"Installed syft did not report its version"* ]]
}

@test "install_syft preserves an existing destination binary when validation fails" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir destination
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test" 1)
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    destination="$home_dir/.local/bin/syft"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n' 'previous syft bytes' > "$destination"
    rm "$helper_bin/install"
    cat > "$helper_bin/install" <<'EOF'
#!/bin/sh
destination=""
for argument in "$@"; do
    destination="$argument"
done
case "$destination" in
    /usr/local/bin/syft.tmp.*) exit 1 ;;
esac
exec /usr/bin/install "$@"
EOF
    chmod +x "$helper_bin/install"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$4"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir"

    [ "$status" -ne 0 ]
    [ "$(cat "$destination")" = 'previous syft bytes' ]
    [ -z "$(find "$home_dir/.local/bin" -name 'syft.tmp.*' -print -quit 2>/dev/null)" ]
}

@test "install_syft succeeds when logging success fails" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir
    archive_digest=$(make_syft_archive "$archive" "9.9.9-test")
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    rm "$helper_bin/install"
    cat > "$helper_bin/install" <<'EOF'
#!/bin/sh
destination=""
for argument in "$@"; do
    destination="$argument"
done
case "$destination" in
    /usr/local/bin/syft.tmp.*) exit 1 ;;
esac
exec /usr/bin/install "$@"
EOF
    chmod +x "$helper_bin/install"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$4"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        source "$1" || exit 1
        log_success() { return 1; }
        install_syft
        test -x "$HOME/.local/bin/syft"
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir"

    [ "$status" -eq 0 ]
}
