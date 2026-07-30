#!/usr/bin/env bats

load "../test_helper"

setup() {
    setup_temp_dir
    ORIG_PATH="$PATH"
    # Cleared going in, not just coming out: one of these exported in the shell
    # that runs the suite would otherwise steer the stub through tests that never
    # asked for it.
    unset E2E_IMAGE E2E_READY_TIMEOUT DOCKER_INSPECT_OUTPUT DOCKER_INSPECT_EXIT \
        DOCKER_INSPECT_ERROR DOCKER_PS_OUTPUT DOCKER_PS_EXIT DOCKER_PS_ERROR \
        DOCKER_IMAGES_OUTPUT
    # Each bats test is its own process, so it inherits these from the shell that
    # launched the suite: an exported E2E_IMAGE walks straight past the discovery
    # tests, and a different owner invalidates the ambiguous-image fixture.
    export GITHUB_REPOSITORY_OWNER=oorabona
    FIXTURE_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$FIXTURE_REPO/tests" "$FIXTURE_REPO/helpers"
    cp "$PROJECT_ROOT/tests/e2e-test.sh" "$FIXTURE_REPO/tests/e2e-test.sh"
    cp "$PROJECT_ROOT/helpers/logging.sh" "$FIXTURE_REPO/helpers/logging.sh"
    cp "$PROJECT_ROOT/helpers/variant-utils.sh" "$FIXTURE_REPO/helpers/variant-utils.sh"
    chmod +x "$FIXTURE_REPO/tests/e2e-test.sh"
}

teardown() {
    export PATH="$ORIG_PATH"
    unset E2E_IMAGE E2E_READY_TIMEOUT DOCKER_LOG DOCKER_IMAGES_OUTPUT DOCKER_PS_OUTPUT DOCKER_PS_EXIT DOCKER_PS_ERROR DOCKER_INSPECT_OUTPUT DOCKER_INSPECT_EXIT DOCKER_INSPECT_ERROR PS_COUNT_FILE TEST_SCRIPT_MARKER
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

@test "helper sourcing resolves from repo root" {
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

@test "deleting the missing-script check would pass a run that verified nothing" {
    # Everything before the per-container script is a generic liveness check that
    # any image passes. Skipping a deleted script in silence turned a suite into
    # "the container started" while still reporting success — which is how this
    # harness came to sit unrun for months.
    add_openvpn_fixture
    rm "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"not executable"* ]]
}

@test "a TERM after docker run removes the active container through the trap" {
    add_openvpn_fixture
    cat > "$FIXTURE_REPO/openvpn/test.sh" <<'SH'
#!/bin/bash
kill -TERM "$PPID"
SH
    chmod +x "$FIXTURE_REPO/openvpn/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    # The first removal clears a possible stale name before docker run; the
    # second proves the TERM trap removed the newly started one.
    [ "$(grep -c '^rm ' "$DOCKER_LOG")" -eq 2 ]
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

@test "sslh run profile: args-only command, port 443, NET_BIND_SERVICE (entrypoint+healthcheck match)" {
    mkdir -p "$FIXTURE_REPO/sslh"
    # The real container has one, and the harness now requires it — this fixture
    # stands in for it so the assertions below stay about the run profile.
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_REPO/sslh/test.sh"
    chmod +x "$FIXTURE_REPO/sslh/test.sh"
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

@test "terraform run profile: --entrypoint sleep, because the image entrypoint execs terraform with its args" {
    mkdir -p "$FIXTURE_REPO/terraform"
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_REPO/terraform/test.sh"
    chmod +x "$FIXTURE_REPO/terraform/test.sh"
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export DOCKER_PS_OUTPUT="e2e-terraform"
    export E2E_IMAGE="ghcr.io/example/terraform:e2e"

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
    [[ "$run_line" == *"--entrypoint sleep "*"ghcr.io/example/terraform:e2e"*"infinity"* ]]
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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export E2E_READY_TIMEOUT=3

    # Bounded so that a budget which has stopped bounding anything fails this test
    # rather than hanging it: the wait would otherwise poll for its full 60s
    # default, or forever if the deadline check itself is broken.
    local before=$SECONDS
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn
    local elapsed=$((SECONDS - before))

    assert_harness_failed_on_its_own
    [[ "$output" == *"did not become ready in time"* ]]
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

@test "an inspect failure never treats the container as ready" {
    add_openvpn_fixture
    install_docker_stub
    # A second of real time per inspect: with the suite's no-op sleep stub the
    # wait would otherwise spin hot for its whole budget, spawning processes for
    # nothing.
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    images)  printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)      printf '%s\n' "${DOCKER_PS_OUTPUT:-e2e-openvpn}" ;;
    inspect) /bin/sleep 1; exit 1 ;;
    *)       exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
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
    [[ "$output" == *"did not become ready in time"* ]]
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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

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
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/dotted:e2e"
    export DOCKER_PS_OUTPUT="e2e-v1X2"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" v1.2

    assert_harness_failed_on_its_own
    # The message is the oracle: read as a pattern this container looks alive, and
    # the run fails later for an unrelated reason.
    [[ "$output" == *"exited unexpectedly"* ]]
}

@test "a docker ps that cannot answer is a timeout, not a container exit" {
    # The two are different claims: one says the runtime did not answer, the other
    # says it answered and the container was gone. Reporting the first as the
    # second blames the image for the daemon.
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export E2E_READY_TIMEOUT=2
    # A real delay in the failing probe: the suite's sleep stub is a no-op, so a
    # stub that fails instantly would have the wait forking processes flat out for
    # its whole budget — CPU that shows up as flake in the timing test running
    # alongside it.
    cat > "$TEST_TEMP_DIR/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    images) printf '%s\n' "${DOCKER_IMAGES_OUTPUT:-}" ;;
    ps)     /bin/sleep 1; exit 1 ;;
    *)      exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/docker"

    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    assert_harness_failed_on_its_own
    [[ "$output" == *"did not become ready in time"* ]]
    [[ "$output" != *"exited unexpectedly"* ]]
    [ ! -e "$TEST_SCRIPT_MARKER" ]
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
        # Deliberately unbounded, each for a stated reason:
        #   docker images  — local discovery before anything is started
        #   docker run     — the start itself; nothing to clean up if it hangs
        allowed="docker images|docker run"
        offenders=$(printf "%s\n" "$unbounded" | grep -vE "$allowed" | grep -c . || true)
        if [ "$offenders" -ne 0 ]; then
            printf "%s\n" "$unbounded" | grep -vE "$allowed" >&2
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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export E2E_READY_TIMEOUT=60
    export DOCKER_PS_OUTPUT=""
    export DOCKER_PS_ERROR="docker: command not found"
    export DOCKER_PS_EXIT=127

    local before=$SECONDS
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn
    local elapsed=$((SECONDS - before))

    assert_harness_failed_on_its_own
    [[ "$output" == *"docker ps failed (exit 127): docker: command not found"* ]]
    [[ "$output" != *"did not become ready in time"* ]]
    [ "$elapsed" -lt 10 ]
}

@test "a Docker permission error stops inspect readiness immediately and reports stderr" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export TEST_SCRIPT_MARKER="$TEST_TEMP_DIR/openvpn-test.marker"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export E2E_READY_TIMEOUT=60
    export DOCKER_INSPECT_OUTPUT=""
    export DOCKER_INSPECT_ERROR="permission denied while trying to connect to the Docker daemon socket"
    export DOCKER_INSPECT_EXIT=1

    local before=$SECONDS
    run timeout -k 2 30 "$FIXTURE_REPO/tests/e2e-test.sh" openvpn
    local elapsed=$((SECONDS - before))

    assert_harness_failed_on_its_own
    [[ "$output" == *"docker inspect failed (exit 1): permission denied while trying to connect to the Docker daemon socket"* ]]
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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"

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
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export DOCKER_INSPECT_OUTPUT=healthy

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_SCRIPT_MARKER")" = "e2e-openvpn" ]
}

@test "an invalid E2E_READY_TIMEOUT is rejected before anything is started" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export E2E_READY_TIMEOUT=zero

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"between 1 and 99999"* ]]
    # Rejecting it after `docker run` would strand the container: --rm removes it
    # when it stops, and nothing stops it on this path.
    [ ! -s "$DOCKER_LOG" ]
}

@test "a value too large to hold as a deadline is rejected" {
    add_openvpn_fixture
    install_docker_stub
    export DOCKER_LOG="$TEST_TEMP_DIR/docker.log"
    export E2E_IMAGE="ghcr.io/example/openvpn:e2e"
    export E2E_READY_TIMEOUT=99999999999999999999

    run "$FIXTURE_REPO/tests/e2e-test.sh" openvpn

    [ "$status" -ne 0 ]
    [[ "$output" == *"between 1 and 99999"* ]]
    [ ! -s "$DOCKER_LOG" ]
}
