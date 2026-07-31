#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    ORIG_PATH="$PATH"
    # Cleared going in, not just coming out: one of these exported in the shell
    # that runs the suite would otherwise steer the stub through tests that never
    # asked for it.
    unset E2E_IMAGE E2E_BUILD_TAG E2E_BUILD_VERSION E2E_BUILD_VARIANT E2E_BUILD_FLAVOR E2E_READY_TIMEOUT E2E_TEST_TIMEOUT DOCKER_IMAGE_ID DOCKER_INSPECT_OUTPUT DOCKER_INSPECT_EXIT \
        DOCKER_INSPECT_ERROR DOCKER_PS_OUTPUT DOCKER_PS_EXIT DOCKER_PS_ERROR \
        DOCKER_IMAGES_OUTPUT DOCKER_RM_FAIL_ON_SECOND
    # Each bats test is its own process, so it inherits these from the shell that
    # launched the suite: an exported E2E_IMAGE walks straight past the discovery
    # tests, and a different owner invalidates the ambiguous-image fixture.
    export GITHUB_REPOSITORY_OWNER=oorabona
    FIXTURE_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$FIXTURE_REPO/tests" "$FIXTURE_REPO/helpers"
    cp "$PROJECT_ROOT/tests/e2e-test.sh" "$FIXTURE_REPO/tests/e2e-test.sh"
    cp "$PROJECT_ROOT/helpers/logging.sh" "$FIXTURE_REPO/helpers/logging.sh"
    cp "$PROJECT_ROOT/helpers/variant-utils.sh" "$FIXTURE_REPO/helpers/variant-utils.sh"
    mkdir -p "$FIXTURE_REPO/test-harness"
    cp "$PROJECT_ROOT/test-harness/image-identity.sh" "$FIXTURE_REPO/test-harness/image-identity.sh"
    chmod +x "$FIXTURE_REPO/tests/e2e-test.sh"
}

teardown() {
    export PATH="$ORIG_PATH"
    unset E2E_IMAGE E2E_BUILD_TAG E2E_BUILD_VERSION E2E_BUILD_VARIANT E2E_BUILD_FLAVOR E2E_READY_TIMEOUT E2E_TEST_TIMEOUT DOCKER_LOG DOCKER_IMAGES_OUTPUT DOCKER_PS_OUTPUT DOCKER_PS_EXIT DOCKER_PS_ERROR DOCKER_IMAGE_ID DOCKER_INSPECT_OUTPUT DOCKER_INSPECT_EXIT DOCKER_INSPECT_ERROR DOCKER_RM_FAIL_ON_SECOND PS_COUNT_FILE TEST_SCRIPT_MARKER RUN_STARTED TEST_SUITE_STARTED HARNESS_PID_FILE
    teardown_temp_dir
}

# Every test below that expects the harness to give up wraps it in a watchdog
# `timeout`, so that a wait which stopped bounding anything fails instead of
# hanging. That makes the watchdog's own statuses a false pass: 124 when it sends
# SIGTERM, 137 when its kill-after grace follows with SIGKILL. Either means the
# harness never reached the failure the test is about.
assert_harness_failed_on_its_own() {
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ]
    [ "$status" -ne 137 ]
}

# The signal fixtures run the harness beneath an outer watchdog. A missing
# marker used to leave them polling after that watchdog had exited, so fail the
# test itself instead of turning a harness crash into a stuck bats worker.
wait_for_marker() {
    local marker="$1"
    local watchdog_pid="$2"
    local path_description="$3"
    local marker_deadline=$((SECONDS + 10))

    while [ ! -e "$marker" ]; do
        if ! kill -0 "$watchdog_pid" 2>/dev/null; then
            printf '%s marker was never written: outer watchdog exited\n' "$path_description" >&2
            return 1
        fi
        if [ "$SECONDS" -ge "$marker_deadline" ]; then
            printf '%s marker was not written within 10 seconds\n' "$path_description" >&2
            return 1
        fi
        /bin/sleep 0.05
    done
}

install_docker_stub() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    shift
fi
case "$1" in
    images)
        printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}"
        ;;
    inspect)
        inspect_format=""
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --format)
                    inspect_format="$2"
                    shift 2
                    ;;
                --format=*)
                    inspect_format="${1#--format=}"
                    shift
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        if [ "$inspect_format" = '{{.Id}}' ]; then
            printf '%s\n' "${DOCKER_IMAGE_ID:-sha256:e2e-loaded-image}"
            exit 0
        fi
        if [ "$inspect_format" != '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' ]; then
            printf 'unexpected inspect format: %s\n' "$inspect_format" >&2
            exit 64
        fi
        inspect_exit="${DOCKER_INSPECT_EXIT:-0}"
        if [ "$inspect_exit" -ne 0 ]; then
            printf '%s\n' "${DOCKER_INSPECT_ERROR:-inspect failed}" >&2
            exit "$inspect_exit"
        fi
        printf '%s\n' "${DOCKER_INSPECT_OUTPUT:-nohealth}"
        ;;
    ps)
        ps_exit="${DOCKER_PS_EXIT:-0}"
        if [ "$ps_exit" -ne 0 ]; then
            printf '%s\n' "${DOCKER_PS_ERROR:-ps failed}" >&2
            exit "$ps_exit"
        fi
        printf '%s\n' "${DOCKER_PS_OUTPUT:-e2e-openvpn}"
        ;;
    rm)
        # Signal fixtures make their trapped removal fail so the asserted status
        # proves the handler reached its explicit exit rather than falling out.
        if [ "${DOCKER_RM_FAIL_ON_SECOND:-false}" = true ] && [ "$(grep -c '^rm ' "${DOCKER_LOG:?}")" -eq 2 ]; then
            exit 1
        fi
        exit 0
        ;;
    run|logs|exec)
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
    cat > "$FIXTURE_REPO/openvpn/version.sh" <<'SH'
#!/bin/bash
if [[ "${1:-}" == "--tag-suffix" ]]; then
    printf '%s\n' '-alpine'
    exit 0
fi
exit 1
SH
    chmod +x "$FIXTURE_REPO/openvpn/version.sh"
    cat > "$FIXTURE_REPO/openvpn/test.sh" <<'SH'
#!/bin/bash
printf '%s\n' "${CONTAINER_NAME:-}" > "${TEST_SCRIPT_MARKER:?}"
SH
    chmod +x "$FIXTURE_REPO/openvpn/test.sh"
}

add_single_image_identity_fixture() {
    local container="$1" tag="$2" suffix="$3"
    mkdir -p "$FIXTURE_REPO/$container"
    printf 'versions:\n  - tag: %s\n' "$tag" > "$FIXTURE_REPO/$container/variants.yaml"
    printf '#!/bin/bash\nif [[ "${1:-}" == "--tag-suffix" ]]; then printf "%%s\\n" %q; exit 0; fi\nexit 1\n' "$suffix" > "$FIXTURE_REPO/$container/version.sh"
    chmod +x "$FIXTURE_REPO/$container/version.sh"
}

@test "helper sourcing resolves from repo root" {
    run "$FIXTURE_REPO/tests/e2e-test.sh" --help

    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-build"* ]]
}

@test "source-only mode leaves the caller and startup commands untouched" {
    local caller_dir="$TEST_TEMP_DIR/caller"
    mkdir -p "$caller_dir" "$TEST_TEMP_DIR/bin"
    printf '#!/bin/bash\n: > "${SOURCE_ONLY_MAKE_MARKER:?}"\n' > "$caller_dir/make"
    chmod +x "$caller_dir/make"
    printf '#!/bin/bash\n: > "${SOURCE_ONLY_TIMEOUT_MARKER:?}"\n' > "$TEST_TEMP_DIR/bin/timeout"
    chmod +x "$TEST_TEMP_DIR/bin/timeout"
    export SOURCE_ONLY_MAKE_MARKER="$TEST_TEMP_DIR/make-ran"
    export SOURCE_ONLY_TIMEOUT_MARKER="$TEST_TEMP_DIR/timeout-ran"

    run env E2E_TEST_SOURCE_ONLY=1 PATH="$TEST_TEMP_DIR/bin:$PATH" bash -c '
        script="$1"
        caller_dir="$2"
        cd "$caller_dir"
        set +e +u
        set +o pipefail
        SECONDS=37
        set -- caller-first caller-second
        source "$script"
        [[ "$SECONDS" -ge 37 ]]
        [[ "$#" -eq 2 && "$1" == caller-first && "$2" == caller-second ]]
        [[ "$-" != *e* && "$-" != *u* ]]
        [[ "$(set -o | awk "\$1 == \"pipefail\" { print \$2 }")" == off ]]
        declare -F resolve_e2e_image >/dev/null
    ' _ "$FIXTURE_REPO/tests/e2e-test.sh" "$caller_dir"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$SOURCE_ONLY_MAKE_MARKER" ]
    [ ! -e "$SOURCE_ONLY_TIMEOUT_MARKER" ]
}

@test "S3/AD3: an E2E image ID and passed build cell bypass routing and run unchanged" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="sha256:ci-loaded-image"
    export DOCKER_IMAGE_ID="sha256:ci-loaded-image"
    export E2E_BUILD_TAG="v2.7.5-alpine"
    export E2E_BUILD_VERSION="v2.7.5-alpine"
    export E2E_BUILD_VARIANT=""
    export E2E_BUILD_FLAVOR=""

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_SCRIPT_MARKER")" = "e2e-openvpn" ]
    grep -q '^run .*sha256:ci-loaded-image' "$DOCKER_LOG"

    run_line=$(grep '^run ' "$DOCKER_LOG")
    [[ "$run_line" == *"--cap-drop ALL"* ]]
    [[ "$run_line" == *"--cap-add NET_ADMIN"* ]]
    [[ "$run_line" == *"--cap-add SETUID"* ]]
    [[ "$run_line" == *"--cap-add SETGID"* ]]
    [[ "$run_line" == *"--device /dev/net/tun:/dev/net/tun"* ]]
    [[ "$run_line" == *"-e AUTO_INSTALL=y"* ]]
    [[ "$run_line" == *"-e AUTO_START=y"* ]]
    [[ "$run_line" == *"sha256:ci-loaded-image"* ]]
    ! grep -q '^images ' "$DOCKER_LOG"
}

@test "deleting the missing-script check would pass a run that verified nothing" {
    # Everything before the per-container script is a generic liveness check that
    # any image passes. Skipping a deleted script in silence turned a suite into
    # "the container started" while still reporting success — which is how this
    # harness came to sit unrun for months.
    add_openvpn_fixture
    rm "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"no test script"* ]]
}

@test "deleting the executable check would pass a script that cannot run" {
    # A checkout or an archive can drop the mode bit without touching a byte of
    # the script.
    add_openvpn_fixture
    chmod -x "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"not executable"* ]]
}

@test "a TERM while docker run is still returning removes the active container through the armed trap" {
    # #1008: docker run creates the detached container before it returns. The old
    # trap was armed after that return, so a TERM in this window left the newly
    # created container behind; the marker below stands in for that creation.
    add_openvpn_fixture
    install_docker_stub
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
case "$1" in
    run)
        : > "${RUN_STARTED:?}"
        /bin/sleep 2
        ;;
    rm)
        # The stale-name cleanup succeeds; the signal-path removal fails. This
        # makes the status assertion below red against the old fatal handler.
        if [ "$(grep -c '^rm ' "${DOCKER_LOG:?}")" -eq 2 ]; then
            exit 1
        fi
        ;;
    *)
        exit 0
        ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export RUN_STARTED="$TEST_TEMP_DIR/container-created"
    export HARNESS_PID_FILE="$TEST_TEMP_DIR/harness.pid"

    timeout -k 2 15 bash -c 'printf "%s\\n" "$$" > "$1"; shift; exec "$@"' _ \
        "$HARNESS_PID_FILE" "$FIXTURE_REPO/tests/e2e-test.sh" openvpn > "$TEST_TEMP_DIR/harness.out" 2>&1 &
    local watchdog_pid=$!
    if ! wait_for_marker "$RUN_STARTED" "$watchdog_pid" "docker run signal fixture"; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        return 1
    fi
    # Signal the harness PID only. The test is specifically not relying on a
    # terminal-style process-group signal to interrupt docker run for us.
    kill -TERM "$(cat "$HARNESS_PID_FILE")"
    local watchdog_status=0
    wait "$watchdog_pid" || watchdog_status=$?

    # The first removal clears a possible stale name before docker run; the
    # second proves the armed TERM trap removed the newly started one. Before
    # #1008 this was one: the signal arrived before any trap existed.
    [ "$watchdog_status" -eq 143 ]
    [ "$(grep -c '^rm ' "$DOCKER_LOG")" -eq 2 ]
}

@test "a TERM during a hanging custom suite reaches cleanup once its bound ends" {
    # #1007: Bash defers a TERM trap while the foreground suite runs. Without
    # this bound, signalling only the harness PID leaves both it and its named
    # container stuck forever; the outer watchdog makes that regression fail.
    add_openvpn_fixture
    cat > "$FIXTURE_REPO/openvpn/test.sh" <<'SH'
#!/bin/bash
: > "${TEST_SUITE_STARTED:?}"
while :; do /bin/sleep 1; done
SH
    chmod +x "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_TEST_TIMEOUT=1
    export HARNESS_PID_FILE="$TEST_TEMP_DIR/harness.pid"
    export TEST_SUITE_STARTED="$TEST_TEMP_DIR/custom-suite-started"
    export DOCKER_RM_FAIL_ON_SECOND=true

    local before=$SECONDS
    timeout -k 2 15 bash -c 'printf "%s\\n" "$$" > "$1"; shift; exec "$@"' _ \
        "$HARNESS_PID_FILE" "$FIXTURE_REPO/tests/e2e-test.sh" openvpn > "$TEST_TEMP_DIR/harness.out" 2>&1 &
    local watchdog_pid=$!
    if ! wait_for_marker "$TEST_SUITE_STARTED" "$watchdog_pid" "custom-suite signal fixture"; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        return 1
    fi
    # This is intentionally the script PID, not the foreground process group.
    kill -TERM "$(cat "$HARNESS_PID_FILE")"
    local watchdog_status=0
    wait "$watchdog_pid" || watchdog_status=$?
    local elapsed=$((SECONDS - before))

    [ "$watchdog_status" -eq 143 ]
    [ "$elapsed" -lt 13 ]
    # As above, one removal is stale-name cleanup; the other is the deferred TERM
    # trap after timeout has ended the otherwise infinite suite.
    [ "$(grep -c '^rm ' "$DOCKER_LOG")" -eq 2 ]
}

@test "a hanging custom suite is stopped by the bound and names it in the report" {
    # #1007: the point of the bound is that a suite which never returns still ends,
    # and that the report says what happened. It does not say "timed out" as a
    # fact — see the sibling test below for why the harness cannot know that from
    # the status alone — but the bound has to be named, or an operator reading
    # "exit 124" has nothing to go on.
    add_openvpn_fixture
    cat > "$FIXTURE_REPO/openvpn/test.sh" <<'SH'
#!/bin/bash
while :; do /bin/sleep 1; done
SH
    chmod +x "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_TEST_TIMEOUT=1

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"Custom tests failed for openvpn (exit 124"* ]]
    [[ "$output" == *"1s bound"* ]]
    [ "$(grep -c '^rm ' "$DOCKER_LOG")" -eq 2 ]
}

@test "a custom suite returning 124 is not asserted to have timed out" {
    # `timeout` preserves its command's status when its deadline did not fire, and
    # web-shell/test.sh runs `timeout` and can propagate 124 without having timed
    # out. The harness cannot tell the two apart from the status alone — every
    # mechanism tried for that cost more than the ambiguity — so what is locked
    # here is that it does not CLAIM to: the status is reported, the bound is
    # offered as one cause among others, and nothing states a timeout as fact.
    add_openvpn_fixture
    cat > "$FIXTURE_REPO/openvpn/test.sh" <<'SH'
#!/bin/bash
exit 124
SH
    chmod +x "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_TEST_TIMEOUT=10

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -eq 1 ]
    [[ "$output" == *"Custom tests failed for openvpn (exit 124"* ]]
    [[ "$output" != *"Custom tests timed out for openvpn"* ]]
}

@test "fallback image discovery errors on zero matches" {
    mkdir -p "$FIXTURE_REPO/debian"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=""

    run "$FIXTURE_REPO/tests/e2e-test.sh" --no-build debian

    [ "$status" -eq 1 ]
    [[ "$output" == *"No image found for debian"* ]]
    ! grep -q '^run ' "$DOCKER_LOG"
}

@test "fallback image discovery errors on ambiguous image IDs" {
    mkdir -p "$FIXTURE_REPO/debian"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=$'sha111 ghcr.io/oorabona/debian:trixie\nsha222 docker.io/oorabona/debian:bookworm'

    run "$FIXTURE_REPO/tests/e2e-test.sh" --no-build debian

    [ "$status" -eq 1 ]
    [[ "$output" == *"Ambiguous local images for debian"* ]]
    ! grep -q '^run ' "$DOCKER_LOG"
}

@test "an explicit tag uses its local ghcr image" {
    add_single_image_identity_fixture debian trixie ''
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT='sha111 ghcr.io/oorabona/debian:trixie'

    run env E2E_TEST_SOURCE_ONLY=1 bash -c 'source "$1"; resolve_e2e_image debian trixie --json' _ \
        "$FIXTURE_REPO/tests/e2e-test.sh"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.image' <<<"$output")" = "ghcr.io/oorabona/debian:trixie" ]
    [ "$(jq -r '.image_id' <<<"$output")" = "sha111" ]
    [ "$(jq -r '.cell.tag' <<<"$output")" = "trixie" ]
}

@test "an explicit tag on two local prefixes sharing one image ID is unambiguous" {
    add_single_image_identity_fixture debian trixie ''
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=$'sha111 ghcr.io/oorabona/debian:trixie\nsha111 docker.io/oorabona/debian:trixie'

    run env E2E_TEST_SOURCE_ONLY=1 bash -c 'source "$1"; resolve_e2e_image debian trixie --json' _ \
        "$FIXTURE_REPO/tests/e2e-test.sh"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.image' <<<"$output")" = "ghcr.io/oorabona/debian:trixie" ]
    [ "$(jq -r '.image_id' <<<"$output")" = "sha111" ]
    [ "$(jq -r '.cell.tag' <<<"$output")" = "trixie" ]
}

@test "an explicit tag absent locally falls back to Docker Hub with an explanation" {
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=''

    run env E2E_TEST_SOURCE_ONLY=1 bash -c 'source "$1"; resolve_e2e_image debian trixie' _ \
        "$FIXTURE_REPO/tests/e2e-test.sh"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Image docker.io/oorabona/debian:trixie was not found locally; using remote reference"* ]]
    [[ "$output" == *"docker.io/oorabona/debian:trixie"* ]]
}

@test "fallback image discovery keeps a declared cell when its tag precedes latest" {
    add_single_image_identity_fixture debian trixie ''
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    # A build adds both of these tags to one image. A later undeclared alias
    # must not erase the cell selected from the declared tag.
    export DOCKER_IMAGES_OUTPUT=$'sha111 ghcr.io/oorabona/debian:trixie\nsha111 ghcr.io/oorabona/debian:latest'

    run env E2E_TEST_SOURCE_ONLY=1 bash -c 'source "$1"; resolve_e2e_image debian "" --json' _ \
        "$FIXTURE_REPO/tests/e2e-test.sh"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.image' <<<"$output")" = "ghcr.io/oorabona/debian:trixie" ]
    [ "$(jq -r '.image_id' <<<"$output")" = "sha111" ]
    [ "$(jq -r '.cell.tag' <<<"$output")" = "trixie" ]
}

@test "fallback image discovery keeps a declared cell when latest precedes its tag" {
    add_single_image_identity_fixture debian trixie ''
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=$'sha111 ghcr.io/oorabona/debian:latest\nsha111 ghcr.io/oorabona/debian:trixie'

    run env E2E_TEST_SOURCE_ONLY=1 bash -c 'source "$1"; resolve_e2e_image debian "" --json' _ \
        "$FIXTURE_REPO/tests/e2e-test.sh"

    [ "$status" -eq 0 ]
    [ "$(jq -r '.image' <<<"$output")" = "ghcr.io/oorabona/debian:trixie" ]
    [ "$(jq -r '.image_id' <<<"$output")" = "sha111" ]
    [ "$(jq -r '.cell.tag' <<<"$output")" = "trixie" ]
}

@test "fallback image discovery rejects two declared cells on one image ID" {
    add_single_image_identity_fixture debian bookworm ''
    printf '  - tag: trixie\n' >> "$FIXTURE_REPO/debian/variants.yaml"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_IMAGES_OUTPUT=$'sha111 ghcr.io/oorabona/debian:bookworm\nsha111 docker.io/oorabona/debian:trixie'

    run env E2E_TEST_SOURCE_ONLY=1 bash -c 'source "$1"; resolve_e2e_image debian' _ \
        "$FIXTURE_REPO/tests/e2e-test.sh"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Ambiguous declared image tags for debian"* ]]
    [[ "$output" == *"ghcr.io/oorabona/debian:bookworm"* ]]
    [[ "$output" == *"docker.io/oorabona/debian:trixie"* ]]
}

@test "sslh run profile: args-only command, port 443, NET_BIND_SERVICE (entrypoint+healthcheck match)" {
    mkdir -p "$FIXTURE_REPO/sslh"
    add_single_image_identity_fixture sslh v2.3.1-alpine -alpine
    # The real container has one, and the harness now requires it — this fixture
    # stands in for it so the assertions below stay about the run profile.
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_REPO/sslh/test.sh"
    chmod +x "$FIXTURE_REPO/sslh/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_PS_OUTPUT="e2e-sslh"
    export E2E_IMAGE="ghcr.io/example/sslh:v2.3.1-alpine"

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
    if sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$PROJECT_ROOT/sslh/test.sh" | grep -qE '\bpgrep\b'; then
        false
    fi
    grep -q '/bin/busybox nc' "$PROJECT_ROOT/sslh/test.sh"
}

@test "terraform run profile: --entrypoint sleep, because the image entrypoint execs terraform with its args" {
    mkdir -p "$FIXTURE_REPO/terraform"
    cat > "$FIXTURE_REPO/terraform/variants.yaml" <<'YAML'
versions:
  - tag: 1.15.8-alpine
    variants:
      - name: full
        suffix: ""
        flavor: full
        default: true
YAML
    cat > "$FIXTURE_REPO/terraform/version.sh" <<'SH'
#!/bin/bash
[[ "${1:-}" == "--tag-suffix" ]] && { printf '%s\n' '-alpine'; exit 0; }
exit 1
SH
    chmod +x "$FIXTURE_REPO/terraform/version.sh"
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_REPO/terraform/test.sh"
    chmod +x "$FIXTURE_REPO/terraform/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_PS_OUTPUT="e2e-terraform"
    export E2E_IMAGE="ghcr.io/example/terraform:1.15.8-alpine"

    run "$FIXTURE_REPO/tests/e2e-test.sh" terraform

    [ "$status" -eq 0 ]
    run_line=$(grep '^run ' "$DOCKER_LOG")
    # The image entrypoint ends in `exec /bin/terraform "$@"`, so without an
    # entrypoint override `sleep infinity` arrives as terraform arguments and the
    # container is gone before the first probe. Overriding it is what keeps the
    # container alive; dropping this line makes every terraform probe unrunnable.
    # Order matters as much as presence: an option placed after the image is a
    # container argument, not a docker option, so the override would silently
    # stop applying. One glob pins the sequence.
    # The trailing space matters: without it `--entrypoint sleeper` satisfies the
    # match while being an invalid entrypoint.
    [[ "$run_line" == *"--entrypoint sleep "*"sha256:e2e-loaded-image"*"infinity"* ]]
}

@test "the readiness budget bounds elapsed time, not the number of polls" {
    # The wait used to add 2 to a counter per iteration, so everything spent
    # inside docker was free: with calls this slow it would have kept polling for
    # 30 iterations — a minute of wall clock against a 3-second budget. The stub
    # sleeps through the real /bin/sleep because install_docker_stub shadows sleep
    # with a no-op, which is what keeps the other tests instant.
    add_openvpn_fixture
    install_docker_stub
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
case "$1" in
    images) printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)     /bin/sleep 1; printf '%s\n' "${DOCKER_PS_OUTPUT:-e2e-openvpn}" ;;
    inspect) /bin/sleep 1; printf '%s\n' "starting" ;;
    *)      exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=3

    # Bounded so that a budget which has stopped bounding anything fails this test
    # rather than hanging it: the wait would otherwise poll for its full 60s
    # default, or forever if the deadline check itself is broken.
    local before=$SECONDS
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn
    local elapsed=$((SECONDS - before))

    assert_harness_failed_on_its_own
    # The final probe may be admitted with a one-second bound and either finish
    # or be killed by that bound.  Both reports are correct; this test is about
    # the elapsed readiness deadline, not which side of that scheduling edge won.
    [[ "$output" == *"readiness timed out"* || "$output" == *"did not become ready in time"* ]]
    # Both probes ran: without this, an implementation that skipped every docker
    # call and declared a timeout immediately would satisfy the timing bound.
    grep -q '^ps ' "$DOCKER_LOG"
    grep -q '^inspect ' "$DOCKER_LOG"
    # It also spent the budget rather than giving up early.
    [ "$elapsed" -ge 3 ]
    # The regression this has to fail is a wait that counts polls again, which
    # takes its full 60-second default. Anything well under that catches it, so
    # the ceiling is set for margin rather than tightness: bats runs four files at
    # once in CI, and a ceiling near the ~4s this actually takes would turn a busy
    # runner into a red suite.
    [ "$elapsed" -lt 20 ]
}

@test "a container whose probes remain starting reports a readiness timeout" {
    add_openvpn_fixture
    install_docker_stub
    # The normal test stub suppresses sleeps. Restore them here so each successful
    # poll is followed by a real retry delay rather than spinning until a probe is
    # admitted with only one second left and gets killed by its own bound.
    printf '#!/bin/bash\nexec /bin/sleep "$@"\n' > "$TEST_TEMP_DIR/bin/sleep"
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=3
    export DOCKER_INSPECT_OUTPUT=starting

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    # Successful probes can still be starved after admission at the final
    # one-second boundary.  If that happens it is a real probe failure and the
    # report must name it; otherwise the no-failure wording is correct.
    [[ "$output" == *"did not become ready in time"* || "$output" == *"readiness timed out; last probe failure:"* ]]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
}

@test "an inspect failure never treats the container as ready" {
    add_openvpn_fixture
    install_docker_stub
    # Restore retry sleeps below: with the suite's no-op sleep stub the wait would
    # otherwise spin hot for its whole budget, spawning processes for nothing.
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
case "$1" in
    images)  printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)      printf '%s\n' "${DOCKER_PS_OUTPUT:-e2e-openvpn}" ;;
    inspect)
        printf '%s\n' "inspect transport failed" "inspect retry diagnostic" >&2
        exit 42
        ;;
    *)       exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    printf '#!/bin/bash\nexec /bin/sleep "$@"\n' > "$TEST_TEMP_DIR/bin/sleep"
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    # Enough budget for two things at once: the loop certainly reaches the inspect
    # (at one second it can expire between the ps and the inspect), and a failed
    # inspect misread as "no healthcheck" would have room for its full grace and
    # would therefore pass — which is what makes this test a lock on that misread
    # rather than on the budget running out.
    export E2E_READY_TIMEOUT=6

    # Bounded for the same reason as the budget test above: this expectation is
    # "the wait gives up", so a wait that stopped giving up must fail here, not
    # hang the suite.
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"readiness timed out; last probe failure: inspect probe attempt returned status 42: inspect transport failed%0Ainspect retry diagnostic"* ]]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
    # The branch under test is the one that reads a failed inspect, so prove the
    # inspect was actually attempted rather than skipped past.
    grep -q '^inspect ' "$DOCKER_LOG"
}

@test "a grace period cut short by the budget is not readiness" {
    # With no healthcheck to consult, the elapsed grace is the only evidence the
    # container is up. A budget too small to hold it leaves that evidence
    # unavailable, which is a timeout, not a pass.
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=1

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"did not become ready in time"* ]]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
}

@test "a container that dies during its grace period is not ready" {
    # With no healthcheck the grace is the whole readiness argument, and it rests
    # on a liveness check taken before it started. A container that exits while
    # the harness waits is an exit, not a slow start.
    add_openvpn_fixture
    install_docker_stub
    export PS_COUNT_FILE="$TEST_TEMP_DIR/ps-count"
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
case "$1" in
    images) printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)
        seen=$(cat "${PS_COUNT_FILE:?}" 2>/dev/null || printf '0')
        printf '%s' "$((seen + 1))" > "$PS_COUNT_FILE"
        # Listed the first time, gone by the time the grace is over. The exit is
        # explicit: a trailing `[ … ] && printf` would leave the stub exiting 1
        # when the test wants an empty list, which is a different answer.
        if [ "$seen" -eq 0 ]; then printf '%s\n' "e2e-openvpn"; fi
        exit 0
        ;;
    inspect) printf '%s\n' "nohealth" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"exited unexpectedly"* ]]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
}

@test "a container name is matched literally, not as a pattern" {
    # Docker allows `.` in a name, and as a pattern it matches any character: a
    # sibling called e2e-v1X2 would then stand in for e2e-v1.2, and the harness
    # would call an exited container running. No fixture directory is needed —
    # this fails before the per-container suite is ever looked for.
    add_single_image_identity_fixture v1.2 v1.2-alpine -alpine
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    # The resolver correctly requires the repository component to name the
    # requested container, so use a compatible reference and reach the
    # liveness assertion this test is about.
    export E2E_IMAGE="ghcr.io/example/v1.2:v1.2-alpine"
    export DOCKER_PS_OUTPUT="e2e-v1X2"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" v1.2

    assert_harness_failed_on_its_own
    # The message is the oracle: read as a pattern this container looks alive, and
    # the run fails later for an unrelated reason.
    [[ "$output" == *"exited unexpectedly"* ]]
}

@test "an unrecognised docker ps failure is reported at the timeout, not as a container exit" {
    # The two are different claims: one says the runtime did not answer, the other
    # says it answered and the container was gone. Reporting the first as the
    # second blames the image for the daemon.
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=2
    # Restore retry sleeps below: without them a failing probe would make the wait
    # fork processes flat out for its whole budget, adding flaky CPU pressure.
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
case "$1" in
    images) printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)
        printf '%s\n' "ps transport failed" "ps retry diagnostic" >&2
        exit 42
        ;;
    *)      exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    printf '#!/bin/bash\nexec /bin/sleep "$@"\n' > "$TEST_TEMP_DIR/bin/sleep"
    chmod +x "$TEST_TEMP_DIR/bin/sleep"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"readiness timed out; last probe failure: ps probe attempt returned status 42: ps transport failed%0Aps retry diagnostic"* ]]
    [[ "$output" != *"exited unexpectedly"* ]]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
}

@test "a retained readiness diagnostic cannot forge a workflow command" {
    # The report is a log sink.  In particular, the second physical stderr line
    # must stay part of the value rather than becoming a GitHub Actions command.
    # An oversized tail confirms the report is no longer truncated while the
    # second physical stderr line remains a value rather than an annotation.
    add_openvpn_fixture
    install_docker_stub
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
case "$1" in
    images) printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)
        printf '%s\n' "ps transport failed" "::error::forged annotation" >&2
        head -c 2048 /dev/zero | tr '\0' x >&2
        exit 42
        ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    printf '#!/bin/bash\nexec /bin/sleep "$@"\n' > "$TEST_TEMP_DIR/bin/sleep"
    chmod +x "$TEST_TEMP_DIR/bin/sleep"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=2

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"readiness timed out; last probe failure: ps probe attempt returned status"* ]]
    [[ "$output" == *"%0A::error::forged annotation"* ]]
    [[ "$output" != *$'\n::error::forged annotation'* ]]
    [[ "$output" != *"[stderr truncated after 1024 bytes]"* ]]
    [[ "$output" == *"$(head -c 2048 /dev/zero | tr '\0' x)"* ]]
}

@test "a failed readiness stderr allocation reports the harness failure" {
    # #1009: readiness stderr classifies terminal Docker failures. Falling back
    # to an empty filename turns mktemp's own failure into repeated transient
    # probes, ending with the false claim that the container was merely slow.
    add_openvpn_fixture
    install_docker_stub
    printf '#!/bin/bash\nprintf "mktemp: fixture allocation failed\\n" >&2\nexit 1\n' > "$TEST_TEMP_DIR/bin/mktemp"
    chmod +x "$TEST_TEMP_DIR/bin/mktemp"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=1

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"Harness could not allocate its readiness stderr temp file"* ]]
    # mktemp's own diagnostic reaches the log on its own stderr rather than being
    # folded into the harness's value, so both are present and neither depends on
    # a capture that a chatty tool could poison.
    [[ "$output" == *"mktemp: fixture allocation failed"* ]]
    [[ "$output" != *"did not become ready in time"* ]]
    [ "$(grep -c '^rm ' "$DOCKER_LOG")" -eq 2 ]
}

@test "every docker call in the wait and the cleanup is bounded" {
    # The property, not the spelling. An earlier version pinned whole source
    # lines verbatim, which broke on reformatting and — worse — had baked the
    # probes' `2>&1` into the expectation, so it was holding a defect in place.
    #
    # Two ways a bound can be missing: a `timeout` that lost its -k, and a
    # wrapper deleted outright. Requiring every docker-invoking line to carry
    # `timeout -k` catches both, because a deleted wrapper leaves the docker call
    # behind on a line that no longer matches.
    run bash -c '
        source_file="$1"
        # Lines that invoke docker as a command, ignoring comments, log text and
        # the readiness stderr messages that merely name it.
        unbounded=$(grep -nE "^[^#]*(^|[^a-zA-Z_-])docker[[:space:]]" "$source_file" |
            grep -vE "timeout -k" |
            grep -vE "log_error|log_warning|printf|echo")
        offenders=$(printf "%s\n" "$unbounded" | grep -c . || true)
        if [ "$offenders" -ne 0 ]; then
            printf "%s\n" "$unbounded" >&2
            exit 1
        fi
    ' _ "$PROJECT_ROOT/tests/e2e-test.sh"

    [ "$status" -eq 0 ]
}

@test "no timeout call omits its kill-after grace" {
    # A bound without -k is not a bound: plain `timeout` sends SIGTERM and then
    # waits forever for a child that ignores it.
    run bash -c '
        matches=$(grep -nE "^[^#]*\btimeout\b" "$1") || exit 3
        printf "%s\n" "$matches" | grep -vE "(^|[[:space:]])-k[[:space:]]"
    ' _ "$PROJECT_ROOT/tests/e2e-test.sh"

    [ "$status" -eq 1 ]
}

@test "a docker command missing from PATH stops readiness immediately and reports stderr" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=60
    export DOCKER_PS_OUTPUT=""
    export DOCKER_PS_ERROR="docker: command not found"
    export DOCKER_PS_EXIT=127

    local before=$SECONDS
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn
    local elapsed=$((SECONDS - before))

    assert_harness_failed_on_its_own
    [[ "$output" == *"readiness ps probe attempt returned status 127: docker: command not found"* ]]
    [[ "$output" != *"did not become ready in time"* ]]
    [ "$elapsed" -lt 10 ]
}

@test "a Docker permission error stops inspect readiness immediately and reports stderr" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=60
    export DOCKER_INSPECT_OUTPUT=""
    export DOCKER_INSPECT_ERROR="permission denied while trying to connect to the Docker daemon socket"
    export DOCKER_INSPECT_EXIT=1

    local before=$SECONDS
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn
    local elapsed=$((SECONDS - before))

    assert_harness_failed_on_its_own
    [[ "$output" == *"readiness inspect probe attempt returned status 1: permission denied while trying to connect to the Docker daemon socket"* ]]
    [[ "$output" != *"did not become ready in time"* ]]
    [ "$elapsed" -lt 10 ]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
}

@test "a timeout that cannot bound anything is refused before the container starts" {
    add_openvpn_fixture
    install_docker_stub
    # Stands in for a missing or too-old timeout: the harness cannot bound its
    # docker calls, and must say so while there is still nothing to leak.
    printf '#!/bin/bash\nexit 127\n' > "$TEST_TEMP_DIR/bin/timeout"
    chmod +x "$TEST_TEMP_DIR/bin/timeout"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"accepting -k"* ]]
    [ ! -s "$DOCKER_LOG" ]
}

@test "a docker CLI that chatters on stderr does not poison the health value" {
    # podman's docker shim prints "Emulate Docker CLI using podman…" to stderr on
    # every call. Merging that into the captured value makes $health neither
    # nohealth nor a status, so the wait matches no arm and polls to its budget —
    # and real Docker says nothing there, so this passes CI and breaks everyone
    # running podman.
    add_openvpn_fixture
    install_docker_stub
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
if [[ "$1" == "image" && "${2:-}" == "inspect" ]]; then
    printf '%s\n' "sha256:e2e-loaded-image"
    exit 0
fi
echo "Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg." >&2
case "$1" in
    images)  printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)      printf '%s\n' "${DOCKER_PS_OUTPUT:-e2e-openvpn}" ;;
    inspect) printf '%s\n' "nohealth" ;;
    *)       exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -eq 0 ]
    [[ "$output" != *"did not become ready in time"* ]]
    [ "$(cat "$TEST_SCRIPT_MARKER")" = "e2e-openvpn" ]
}

@test "a healthy inspect result proceeds to the per-container suite" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export DOCKER_INSPECT_OUTPUT=healthy

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_SCRIPT_MARKER")" = "e2e-openvpn" ]
}

@test "an invalid E2E_READY_TIMEOUT is rejected before anything is started" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=zero

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"between 1 and 99999"* ]]
    # Rejecting it after `docker run` would strand the container: --rm removes it
    # when it stops, and nothing stops it on this path.
    [ ! -s "$DOCKER_LOG" ]
}

@test "an invalid E2E_TEST_TIMEOUT is rejected before anything is started" {
    # #1007: this value bounds a foreground suite that can otherwise defer the
    # cleanup trap indefinitely, so it must be rejected before docker run.
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_TEST_TIMEOUT=zero

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"E2E_TEST_TIMEOUT must be a whole number of seconds between 1 and 99999"* ]]
    [ ! -s "$DOCKER_LOG" ]
}

@test "a value too large to hold as a deadline is rejected" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:v2.7.5-alpine"
    export E2E_READY_TIMEOUT=99999999999999999999

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"between 1 and 99999"* ]]
    [ ! -s "$DOCKER_LOG" ]
}
