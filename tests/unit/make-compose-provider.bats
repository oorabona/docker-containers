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

@test "sourcing sbom-utils does not assign syft pin variables in the caller" {
    run bash -c '
        unset SYFT_VERSION SYFT_LINUX_AMD64_SHA256 SYFT_LINUX_ARM64_SHA256 \
            SYFT_DARWIN_AMD64_SHA256 SYFT_DARWIN_ARM64_SHA256
        source "$1" || exit 1
        ! [[ -v SYFT_VERSION || -v SYFT_LINUX_AMD64_SHA256 || -v SYFT_LINUX_ARM64_SHA256 \
            || -v SYFT_DARWIN_AMD64_SHA256 || -v SYFT_DARWIN_ARM64_SHA256 ]]
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
    tar -czf "$archive" -C "$archive_dir" syft
    sha256sum "$archive" | awk '{print $1}'
}

copy_sbom_utils_with_archive_digest() {
    local archive_digest="$1"
    local helper_dir="$TEST_TEMP_DIR/helpers"

    mkdir -p "$helper_dir"
    sed \
        -e "s/2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f/${archive_digest}/" \
        -e "s/6c0466811541ea03add5213a60a1562f0851e4c0b0ecfdee1a694a9455285900/${archive_digest}/" \
        -e "s/cddf9a044145caf0a1a3194d00d1dd51a1666f4814f2919cdb4768a0c062ad95/${archive_digest}/" \
        -e "s/4f37f4c7fefce0a68e4cf71ba3f5f9829a99e65d89b29f7ee41b8c2c10ea8c59/${archive_digest}/" \
        "$PROJECT_ROOT/helpers/sbom-utils.sh" > "$helper_dir/sbom-utils.sh"
    cp "$PROJECT_ROOT/helpers/retry.sh" "$helper_dir/retry.sh"
    printf '%s\n' "$helper_dir/sbom-utils.sh"
}

make_syft_helper_bin() {
    local helper_bin="$TEST_TEMP_DIR/helper-bin"
    local command_name mktemp_path mv_path

    mkdir -p "$helper_bin"
    for command_name in dirname uname rm sha256sum tar gzip install mkdir; do
        ln -s "$(command -v "$command_name")" "$helper_bin/$command_name"
    done
    mktemp_path=$(command -v mktemp)
    mv_path=$(command -v mv)
    cat > "$helper_bin/mktemp" <<EOF
#!/bin/sh
case "\$1" in
    /usr/local/bin/syft.tmp.*)
        echo 'refusing test system staging path' >&2
        exit 1
        ;;
    /usr/local/bin/*)
        exec "${mktemp_path}" "\${TMPDIR:-/tmp}/syft-system-stage.XXXXXX"
        ;;
    *)
        exec "${mktemp_path}" "\$@"
        ;;
esac
EOF
    cat > "$helper_bin/mv" <<EOF
#!/bin/sh
source_path=""
destination=""
for argument in "\$@"; do
    case "\$argument" in
        -*) ;;
        *) source_path="\$destination"; destination="\$argument" ;;
    esac
done
if [ "\$destination" = /usr/local/bin/syft ]; then
    if [ -n "\${SYFT_SYSTEM_DESTINATION:-}" ]; then
        if [ -n "\${SYFT_SYSTEM_MV_DESTINATION:-}" ]; then
            printf '%s\\n' "\$destination" > "\$SYFT_SYSTEM_MV_DESTINATION"
        fi
        exec "${mv_path}" "\$source_path" "\$SYFT_SYSTEM_DESTINATION"
    fi
    echo 'refusing test write to /usr/local/bin/syft' >&2
    exit 1
fi
exec "${mv_path}" "\$@"
EOF
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
if [ -n "${SYFT_CURL_CALLS:-}" ]; then
    printf 'curl\n' >> "$SYFT_CURL_CALLS"
fi
if [ "${SYFT_ALTERED_BYTES:-false}" = true ]; then
    /bin/cp "$SYFT_ALTERED_ARCHIVE" "$destination"
elif [ "${SYFT_CURL_FAIL:-false}" = true ]; then
    exit 1
else
    /bin/cp "$SYFT_TEST_ARCHIVE" "$destination"
fi
EOF
    chmod +x "$helper_bin/mktemp" "$helper_bin/mv" "$helper_bin/curl"
    printf '%s\n' "$helper_bin"
}

@test "make_syft_helper_bin refuses a default system staging path without returning one" {
    local helper_bin
    helper_bin=$(make_syft_helper_bin)

    run --separate-stderr "$helper_bin/mktemp" /usr/local/bin/syft.tmp.XXXXXX

    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" != *"/usr/local/bin/"* ]]
    [[ "$stderr" == *"refusing test system staging path"* ]]
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
case "$1" in
    *linux_amd64*) digest="2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f" ;;
    *linux_arm64*) digest="6c0466811541ea03add5213a60a1562f0851e4c0b0ecfdee1a694a9455285900" ;;
    *darwin_amd64*) digest="cddf9a044145caf0a1a3194d00d1dd51a1666f4814f2919cdb4768a0c062ad95" ;;
    *darwin_arm64*) digest="4f37f4c7fefce0a68e4cf71ba3f5f9829a99e65d89b29f7ee41b8c2c10ea8c59" ;;
    *) exit 1 ;;
esac
printf '%s  %s\n' "$digest" "$1" > "$SYFT_DIGEST_INPUT"
printf '%s  %s\n' "$digest" "$1"
EOF
    cat > "$helper_bin/tar" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$helper_bin/uname" "$helper_bin/curl" "$helper_bin/sha256sum" "$helper_bin/tar"
    printf '%s\n' "$helper_bin"
}

@test "install_syft selects the pinned asset and digest for every platform this helper accepts" {
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
Linux|x86_64|syft_1.51.0_linux_amd64.tar.gz|2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f
Linux|amd64|syft_1.51.0_linux_amd64.tar.gz|2a2e837a2c8d59ec9af5472ee22d3b04ee463c4e44476ecf993fd1e5ab6ebc7f
Linux|aarch64|syft_1.51.0_linux_arm64.tar.gz|6c0466811541ea03add5213a60a1562f0851e4c0b0ecfdee1a694a9455285900
Linux|arm64|syft_1.51.0_linux_arm64.tar.gz|6c0466811541ea03add5213a60a1562f0851e4c0b0ecfdee1a694a9455285900
Darwin|x86_64|syft_1.51.0_darwin_amd64.tar.gz|cddf9a044145caf0a1a3194d00d1dd51a1666f4814f2919cdb4768a0c062ad95
Darwin|amd64|syft_1.51.0_darwin_amd64.tar.gz|cddf9a044145caf0a1a3194d00d1dd51a1666f4814f2919cdb4768a0c062ad95
Darwin|arm64|syft_1.51.0_darwin_arm64.tar.gz|4f37f4c7fefce0a68e4cf71ba3f5f9829a99e65d89b29f7ee41b8c2c10ea8c59
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
    [[ "$output" == *"No verified syft 1.51.0 release asset for FreeBSD/x86_64"* ]]
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

@test "install_syft refuses a verified binary reporting an unpinned version without replacing destinations" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir destination existing
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

    for existing in false true; do
        destination="$home_dir/.local/bin/syft"
        rm -f "$destination"
        if [ "$existing" = true ]; then
            mkdir -p "$(dirname "$destination")"
            printf '%s\n' 'previous syft bytes' > "$destination"
        fi

        run bash -c '
        PATH="$2"; export PATH
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        HOME="$4"; export HOME
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$TEST_TEMP_DIR/home"

        [ "$status" -ne 0 ]
        if [ "$existing" = true ]; then
            [ "$(cat "$destination")" = 'previous syft bytes' ]
        else
            [ ! -e "$destination" ]
        fi
        [ -z "$(find "$home_dir/.local/bin" -name 'syft.tmp.*' -print -quit 2>/dev/null)" ]
        [[ "$output" == *"reported version 9.9.9-test, expected 1.51.0"* ]]
        [[ "$output" != *"installed successfully"* ]]
    done
}

@test "install_syft returns failure without installing or logging success when download fails" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir system_destination system_mv_destination
    archive_digest=$(make_syft_archive "$archive" "1.51.0")
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    system_destination="$TEST_TEMP_DIR/system-bin/syft"
    system_mv_destination="$TEST_TEMP_DIR/system-mv-destination"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$4"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        SYFT_CURL_FAIL=true; export SYFT_CURL_FAIL
        SYFT_SYSTEM_DESTINATION="$5"; export SYFT_SYSTEM_DESTINATION
        SYFT_SYSTEM_MV_DESTINATION="$6"; export SYFT_SYSTEM_MV_DESTINATION
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir" "$system_destination" "$system_mv_destination"

    [ "$status" -ne 0 ]
    [ ! -e "$home_dir/.local/bin/syft" ]
    [ ! -e "$system_destination" ]
    [ ! -e "$system_mv_destination" ]
    [[ "$output" == *"Failed to download syft 1.51.0"* ]]
    [[ "$output" != *"installed successfully"* ]]
}

@test "install_syft falls back to the user directory and exports PATH when the system directory is unavailable" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir
    archive_digest=$(make_syft_archive "$archive" "1.51.0")
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
        install_syft || exit 1
        test -x "$HOME/.local/bin/syft"
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) ;;
            *) exit 1 ;;
        esac
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"syft 1.51.0 installed successfully"* ]]
}

@test "install_syft installs a verified binary at the requested system destination" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir system_destination system_mv_destination mktemp_path curl_calls
    archive_digest=$(make_syft_archive "$archive" "1.51.0")
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    system_destination="$TEST_TEMP_DIR/system-bin/syft"
    system_mv_destination="$TEST_TEMP_DIR/system-mv-destination"
    curl_calls="$TEST_TEMP_DIR/curl-calls"
    mktemp_path=$(command -v mktemp)
    mkdir -p "$(dirname "$system_destination")"
    cat > "$helper_bin/mktemp" <<EOF
#!/bin/sh
case "\$1" in
    /usr/local/bin/syft.tmp.*) exec "${mktemp_path}" "${TEST_TEMP_DIR}/system-stage.XXXXXX" ;;
    *) exec "${mktemp_path}" "\$@" ;;
esac
EOF
    chmod +x "$helper_bin/mktemp"

    run bash -c '
        PATH="$2"; export PATH
        HOME="$4"; export HOME
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        SYFT_SYSTEM_DESTINATION="$5"; export SYFT_SYSTEM_DESTINATION
        SYFT_SYSTEM_MV_DESTINATION="$6"; export SYFT_SYSTEM_MV_DESTINATION
        SYFT_CURL_CALLS="$7"; export SYFT_CURL_CALLS
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir" "$system_destination" "$system_mv_destination" "$curl_calls"

    [ "$status" -eq 0 ]
    [ -x "$system_destination" ]
    [ "$("$system_destination" version | awk '/^Version:/ { print $2 }')" = 1.51.0 ]
    [ "$(cat "$system_mv_destination")" = /usr/local/bin/syft ]
    [ "$(wc -l < "$curl_calls")" -eq 1 ]
    [ ! -e "$home_dir/.local/bin/syft" ]
}

@test "install_syft verifies a correct archive in a TMPDIR containing a backslash" {
    local archive="$TEST_TEMP_DIR/syft.tar.gz"
    local archive_digest helper helper_bin home_dir tmpdir
    archive_digest=$(make_syft_archive "$archive" "1.51.0")
    helper=$(copy_sbom_utils_with_archive_digest "$archive_digest")
    helper_bin=$(make_syft_helper_bin)
    home_dir="$TEST_TEMP_DIR/home"
    tmpdir="$TEST_TEMP_DIR/tmp\\dir"
    mkdir -p "$tmpdir"
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
        TMPDIR="$5"; export TMPDIR
        SYFT_TEST_ARCHIVE="$3"; export SYFT_TEST_ARCHIVE
        source "$1" || exit 1
        install_syft
    ' _ "$helper" "$helper_bin" "$archive" "$home_dir" "$tmpdir"

    [ "$status" -eq 0 ]
    [ -x "$home_dir/.local/bin/syft" ]
    [[ "$output" == *"syft 1.51.0 installed successfully"* ]]
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
    archive_digest=$(make_syft_archive "$archive" "v1.51.0")
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
