#!/usr/bin/env bats

load "../test_helper"

bats_require_minimum_version 1.5.0

# Bats's run --separate-stderr overwrites this capture variable in the tests below.
stderr=""

setup() {
    setup_temp_dir
    # Direct resolver cases must exercise image resolution, not an inherited override.
    unset OPENRESTY_IMAGE
    RUNNER="$PROJECT_ROOT/openresty/tests/test-runner-linux.bats"
    # The loader must keep working when a resolver utility is deliberately stubbed.
    LOADER_AWK="$(command -v awk)"
}

teardown() {
    teardown_temp_dir
}

run_find_image() {
    # Permit Bats run options such as --separate-stderr for channel assertions.
    run "$@" bash -c '
        source <("$2" "/^_find_image\\(\\) \\{/ { inside = 1 } inside { print } inside && /^}\$/ { exit }" "$1")
        _find_image
    ' _ "$RUNNER" "$LOADER_AWK"
}

run_find_image_with_override() {
    local image="$1"
    shift

    # Keep the override case explicit: the rest of this suite resolves images.
    run "$@" env OPENRESTY_IMAGE="$image" bash -c '
        source <("$2" "/^_find_image\\(\\) \\{/ { inside = 1 } inside { print } inside && /^}\$/ { exit }" "$1")
        _find_image
    ' _ "$RUNNER" "$LOADER_AWK"
}

# The resolver cases exercise _find_image directly. Spawn Bats for the runner
# suite as well, explicitly without the override, so these cases cover setup's
# resolution failure propagation.
run_runner_suite() {
    local nested_bin="$TEST_TEMP_DIR/nested-runner-bin"
    local runner_path="$nested_bin:$PATH"
    local -a runner_env=(env "PATH=$runner_path")

    [[ -n "${RUNNER_EXTRA_PATH:-}" ]] && runner_env=(env "PATH=$nested_bin:$RUNNER_EXTRA_PATH:$PATH")
    [[ -n "${DOCKER_RUN_LOG:-}" ]] && runner_env+=("DOCKER_RUN_LOG=$DOCKER_RUN_LOG")
    [[ -n "${DOCKER_RETAG_STATE:-}" ]] && runner_env+=("DOCKER_RETAG_STATE=$DOCKER_RETAG_STATE")
    [[ -n "${DOCKER_REJECT_LABEL_INSPECT:-}" ]] && runner_env+=("DOCKER_REJECT_LABEL_INSPECT=$DOCKER_REJECT_LABEL_INSPECT")
    run "${runner_env[@]}" bats "$RUNNER"
}

run_runner_suite_with_override() {
    local image="$1"
    local nested_bin="$TEST_TEMP_DIR/nested-runner-bin"
    local runner_path="$nested_bin:$PATH"
    local -a runner_env=(env "OPENRESTY_IMAGE=$image" "PATH=$runner_path")

    [[ -n "${DOCKER_RUN_LOG:-}" ]] && runner_env+=("DOCKER_RUN_LOG=$DOCKER_RUN_LOG")
    [[ -n "${DOCKER_RETAG_STATE:-}" ]] && runner_env+=("DOCKER_RETAG_STATE=$DOCKER_RETAG_STATE")
    [[ -n "${DOCKER_REJECT_LABEL_INSPECT:-}" ]] && runner_env+=("DOCKER_REJECT_LABEL_INSPECT=$DOCKER_REJECT_LABEL_INSPECT")
    run "${runner_env[@]}" bats "$RUNNER"
}

stub_docker() {
    local docker_body="$1"
    local docker_bin="${2:-$TEST_TEMP_DIR/bin}"

    mkdir -p "$docker_bin"
    cat > "$docker_bin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    images)
        if [[ "\$#" -ne 4 || "\$2" != --no-trunc || "\$3" != --format || "\$4" != '{{.ID}} {{.Repository}}:{{.Tag}}' ]]; then
            printf 'unexpected docker invocation:' >&2
            printf ' %q' "\$@" >&2
            printf '\\n' >&2
            exit 64
        fi
        $docker_body
        ;;
    image)
        if [[ "\$#" -eq 5 && "\$2" == inspect && "\$3" == --format && "\$4" == '{{.Id}}' ]]; then
            printf '%s\\n' "\${DOCKER_IMAGE_ID:-sha256:override}"
        else
            printf 'unexpected docker invocation:' >&2
            printf ' %q' "\$@" >&2
            printf '\\n' >&2
            exit 64
        fi
        ;;
    *)
        printf 'unexpected docker invocation:' >&2
        printf ' %q' "\$@" >&2
        printf '\\n' >&2
        exit 64
        ;;
esac
EOF
    chmod +x "$docker_bin/docker"
    export PATH="$docker_bin:$PATH"
}

expected_openresty_digest() {
    local resty_version="$1"

    (
        cd "$PROJECT_ROOT/openresty" || exit
        # shellcheck source=../../helpers/build-cache-utils.sh
        # shellcheck disable=SC1091 # The project-root variable resolves the checked-in helper.
        source "$PROJECT_ROOT/helpers/build-cache-utils.sh"
        unset CUSTOM_BUILD_ARGS
        export VERSION="$resty_version"
        # shellcheck source=../../openresty/build
        source ./build >/dev/null
        compute_build_digest Dockerfile ""
    )
}

stub_runner_docker() {
    local image_id="$1"
    local build_digest="$2"
    local resty_version="${3:-1.31.1.1}"
    local retag_after_listing="${4:-false}"
    local docker_bin="$TEST_TEMP_DIR/nested-runner-bin"

    mkdir -p "$docker_bin"
    cat > "$docker_bin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    images)
        [[ "\$#" -eq 4 && "\$2" == --no-trunc && "\$3" == --format && "\$4" == '{{.ID}} {{.Repository}}:{{.Tag}}' ]] || exit 64
        printf '%s\n' '$image_id ghcr.io/oorabona/openresty:latest'
        if [[ '$retag_after_listing' == true ]]; then
            : > "\$DOCKER_RETAG_STATE"
        fi
        ;;
    image)
        [[ "\$2" == inspect && "\$3" == --format ]] || exit 64
        case "\$4" in
            '{{.Id}}') printf '%s\n' '$image_id' ;;
            *'resty_version'*) printf '%s\n' '$resty_version' ;;
            *) [[ "\${DOCKER_REJECT_LABEL_INSPECT:-}" != 1 ]] || exit 65; printf '%s\n' '$build_digest' ;;
        esac
        ;;
    run)
        printf '%s\n' "\$@" >> "\$DOCKER_RUN_LOG"
        printf '%s\n' runner-container
        ;;
    port) printf '%s\n' 127.0.0.1:18080 ;;
    exec)
        case "\$*" in
            *'command -v nginx'*) printf '%s\n' nginx ;;
            *'ldd '*) printf '%s\n' 'libpcre2-8.so => /usr/local/openresty/pcre2/lib/libpcre2-8.so' ;;
            *'nginx -V'*) printf '%s\n' '/usr/local/openresty/pcre2/include /usr/local/openresty/pcre2/lib' ;;
        esac
        ;;
    rm)
        if [[ -n "\${DOCKER_RM_LOG:-}" ]]; then
            printf '%s\n' "\$@" >> "\$DOCKER_RM_LOG"
        fi
        ;;
    logs) exit 0 ;;
    *) exit 64 ;;
esac
EOF
    chmod +x "$docker_bin/docker"

    cat > "$docker_bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *'/re/42'*) printf '%s\n' m=42 ;;
esac
EOF
    chmod +x "$docker_bin/curl"
}

@test "openresty image resolver: Docker's unreachable runtime diagnostic fails, not missing build" {
    stub_docker "printf '%s\\n' 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: Podman's unreachable runtime diagnostic fails, not missing build" {
    stub_docker "printf '%s\\n' 'Error: unable to connect to Podman socket: Get \\\"http://d/v4.0.0/libpod/images/json\\\": dial unix /run/user/1000/podman/podman.sock: connect: no such file or directory' >&2; exit 42"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: unable to connect to Podman socket"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: an unexplained listing error fails, not skips" {
    stub_docker 'exit 42'

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: container runtime did not answer while listing images (exit 42): (no diagnostic)"* ]]
    [[ "$output" == *"OPENRESTY_IMAGE"* ]]
    [[ "$output" != *"SKIP:"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver: explicit OPENRESTY_IMAGE override resolves its ID before listing images" {
    local image="registry.example.test/openresty:explicit-override"
    stub_docker "printf '%s\\n' 'docker must not be called for OPENRESTY_IMAGE' >&2; exit 64"

    run_find_image_with_override "$image"

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:override" ]
}

@test "openresty image resolver: an empty reachable store returns the skip status" {
    stub_docker 'exit 0'

    run_find_image

    [ "$status" -eq 3 ]
    [[ "$output" == *"ERROR: no built openresty image found (run ./make build openresty, or set OPENRESTY_IMAGE)"* ]]
}

@test "openresty image resolver: distinct full IDs sharing a short prefix remain ambiguous" {
    stub_docker "printf '%s\\n' \\
        'sha256:123456789abc000000000000000000000000000000000000000000000000 ghcr.io/oorabona/openresty:latest' \\
        'sha256:123456789abc111111111111111111111111111111111111111111111111 openresty:dev'"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: ambiguous — 2 distinct openresty images present; set OPENRESTY_IMAGE to the one under test"* ]]
}

@test "openresty image resolver: aliases for one image resolve to its unique ID" {
    stub_docker "printf '%s\\n' \\
        'sha256:one ghcr.io/oorabona/openresty:latest' \\
        'sha256:one docker.io/oorabona/openresty:latest' \\
        'sha256:one openresty:dev'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:one" ]
}

@test "openresty image resolver: one matching image returns its ID" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run_find_image

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:one" ]
}

@test "openresty image resolver: successful listing replays its warning to stderr" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'; printf '%s\\n' 'WARNING: image store is in degraded mode' >&2"

    run_find_image --separate-stderr

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:one" ]
    [[ "$stderr" == *"WARNING: image store is in degraded mode"* ]]
}

@test "openresty image resolver: successful listing with empty stderr emits nothing extra" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run_find_image --separate-stderr

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:one" ]
    [ "$stderr" = "" ]
}

@test "openresty runner: unreachable runtime fails the runner suite" {
    stub_docker "printf '%s\\n' 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' >&2; exit 1" "$TEST_TEMP_DIR/nested-runner-bin"

    run_runner_suite

    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty runner: empty reachable store skips all smoke tests" {
    stub_docker 'exit 0' "$TEST_TEMP_DIR/nested-runner-bin"

    run_runner_suite

    [ "$status" -eq 0 ]
    [[ "$output" == *"1..3"* ]]
    [ "$(grep -F -c '# skip no built openresty image found; set OPENRESTY_IMAGE or run ./make build openresty' <<< "$output")" -eq 3 ]
}

@test "openresty runner: enumerated image without a build digest label skips" {
    local expected
    expected=$(expected_openresty_digest 1.31.1.1)
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:enumerated" "none" "1.31.1.1"

    run_runner_suite

    [ "$status" -eq 0 ]
    [[ "$output" == *"resolved openresty image sha256:enumerated has org.opencontainers.image.build-digest label none; expected $expected; run ./make build openresty, or set OPENRESTY_IMAGE"* ]]
    [ ! -s "$DOCKER_RUN_LOG" ]
}

@test "openresty runner: enumerated image without a resty_version label skips" {
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:enumerated" "unreached-build-digest" "none"

    run_runner_suite

    [ "$status" -eq 0 ]
    [[ "$output" == *"resolved openresty image sha256:enumerated has resty_version label none; run ./make build openresty, or set OPENRESTY_IMAGE"* ]]
    [ ! -s "$DOCKER_RUN_LOG" ]
}

@test "openresty runner: enumerated image with a different build digest label skips" {
    local expected
    expected=$(expected_openresty_digest 1.31.1.1)
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:enumerated" "different-digest" "1.31.1.1"

    run_runner_suite

    [ "$status" -eq 0 ]
    [[ "$output" == *"resolved openresty image sha256:enumerated has org.opencontainers.image.build-digest label different-digest; expected $expected; run ./make build openresty, or set OPENRESTY_IMAGE"* ]]
    [ ! -s "$DOCKER_RUN_LOG" ]
}

@test "openresty runner: stale digest skip leaves inherited teardown targets untouched" {
    local sentinel_nginx_conf="$TEST_TEMP_DIR/sentinel-nginx.conf"
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    local DOCKER_RM_LOG="$TEST_TEMP_DIR/docker-rm.log"
    : > "$sentinel_nginx_conf"
    : > "$DOCKER_RUN_LOG"
    : > "$DOCKER_RM_LOG"
    export CONTAINER_ID="sentinel-container"
    export NGINX_CONF="$sentinel_nginx_conf"
    export DOCKER_RM_LOG
    stub_runner_docker "sha256:enumerated" "different-digest" "1.31.1.1"

    run_runner_suite

    [ "$status" -eq 0 ]
    [ -e "$sentinel_nginx_conf" ]
    [ ! -s "$DOCKER_RM_LOG" ]
}

@test "openresty runner: matching enumerated image runs by its ID" {
    local expected
    expected=$(expected_openresty_digest 1.31.1.1)
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:matching" "$expected" "1.31.1.1"

    run_runner_suite

    [ "$status" -eq 0 ]
    [[ "$output" != *"# skip"* ]]
    [ "$(awk 'END {print $NF}' "$DOCKER_RUN_LOG")" = "sha256:matching" ]
}

@test "openresty runner: a retag after enumeration cannot change the image run" {
    local expected
    expected=$(expected_openresty_digest 1.31.1.1)
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    local DOCKER_RETAG_STATE="$TEST_TEMP_DIR/retagged"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:resolved-before-retag" "$expected" "1.31.1.1" true

    run_runner_suite

    [ "$status" -eq 0 ]
    [ -e "$DOCKER_RETAG_STATE" ]
    [ "$(awk 'END {print $NF}' "$DOCKER_RUN_LOG")" = "sha256:resolved-before-retag" ]
}

@test "openresty runner: OPENRESTY_IMAGE bypasses label comparison but runs its resolved ID" {
    local image="registry.example.test/openresty:operator-choice"
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    local DOCKER_REJECT_LABEL_INSPECT=1
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:operator-choice" "none" "none"

    run_runner_suite_with_override "$image"

    [ "$status" -eq 0 ]
    [[ "$output" != *"# skip"* ]]
    [ "$(awk 'END {print $NF}' "$DOCKER_RUN_LOG")" = "sha256:operator-choice" ]
}

@test "openresty runner: a build digest computation failure fails without skipping or running" {
    local failing_bin="$TEST_TEMP_DIR/failing-yq-bin"
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:enumerated" "none" "1.31.1.1"
    mkdir -p "$failing_bin"
    cat > "$failing_bin/yq" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
    chmod +x "$failing_bin/yq"
    local RUNNER_EXTRA_PATH="$failing_bin"

    run_runner_suite

    [ "$status" -ne 0 ]
    [[ "$output" == *"digest input: failed to query variants.yaml"* ]]
    [[ "$output" != *"# skip"* ]]
    [ ! -s "$DOCKER_RUN_LOG" ]
}

@test "openresty runner: a failing build hook fails without skipping or running" {
    local DOCKER_RUN_LOG="$TEST_TEMP_DIR/docker-run.log"
    : > "$DOCKER_RUN_LOG"
    stub_runner_docker "sha256:enumerated" "none" "not-a-version"

    run_runner_suite

    [ "$status" -ne 0 ]
    [[ "$output" != *"# skip"* ]]
    [ ! -s "$DOCKER_RUN_LOG" ]
}

@test "openresty runner: resty_version changes the expected build digest" {
    local first_version="1.31.1.1"
    local second_version="1.31.1.2"
    local first_expected second_expected

    first_expected=$(expected_openresty_digest "$first_version")
    second_expected=$(expected_openresty_digest "$second_version")

    [ -n "$first_expected" ]
    [ -n "$second_expected" ]
    [ "$first_expected" != "$second_expected" ]
}

@test "openresty image resolver: a processing utility failure fails, not skips" {
    local failing_bin="$TEST_TEMP_DIR/failing-awk-bin"

    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"
    mkdir -p "$failing_bin"
    cat > "$failing_bin/awk" <<'EOF'
#!/usr/bin/env bash
printf '%s\\n' 'deliberate awk failure' >&2
exit 42
EOF
    chmod +x "$failing_bin/awk"
    export PATH="$failing_bin:$PATH"

    run_find_image

    [ "$status" -eq 1 ]
    [[ "$output" == *"deliberate awk failure"* ]]
    [[ "$output" == *"ERROR: could not process container image listing"* ]]
    [[ "$output" != *"no built openresty image found"* ]]
}

@test "openresty image resolver stub: exact resolver invocation returns fixture rows" {
    stub_docker "printf '%s\\n' 'sha256:one ghcr.io/oorabona/openresty:latest'"

    run docker images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'

    [ "$status" -eq 0 ]
    [ "$output" = "sha256:one ghcr.io/oorabona/openresty:latest" ]
}

@test "openresty image resolver stub: invocation without --format fails" {
    stub_docker 'exit 0'

    run docker images --no-trunc

    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected docker invocation"* ]]
}

@test "openresty image resolver stub: invocation with another subcommand fails" {
    stub_docker 'exit 0'

    run docker ps --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'

    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected docker invocation"* ]]
}

@test "openresty image resolver stub: invocation with another format fails" {
    stub_docker 'exit 0'

    run docker images --no-trunc --format '{{.Repository}}:{{.Tag}}'

    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected docker invocation"* ]]
}
