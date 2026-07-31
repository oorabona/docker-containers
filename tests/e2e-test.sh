#!/bin/bash

# E2E Container Tests
# Builds and validates all containers using existing build system + custom tests
#
# Usage:
#   ./e2e-test.sh                          # Test all containers (non-variant only)
#   ./e2e-test.sh postgres:16              # Test all variants for postgres v16
#   ./e2e-test.sh postgres:16-full-alpine  # Test specific variant
#   ./e2e-test.sh --no-build               # Skip build, use existing images
#
# For containers with variants, version is required (e.g., postgres:16)
# Set E2E_IMAGE=<image-ref> to test a preloaded image directly.
# Set E2E_BUILD_TAG, E2E_BUILD_VERSION, E2E_BUILD_VARIANT, and
# E2E_BUILD_FLAVOR when the caller already knows the exact build cell.
# Set E2E_READY_TIMEOUT=<seconds> (1-99999, default 60) to give a container with a
# slow healthcheck longer to report itself ready.
# Set E2E_TEST_TIMEOUT=<seconds> (1-99999, default 600) to bound each
# container-specific test suite.

# Resolve the real version exactly as the workflow does for a `tag: latest`
# declaration: ask version.sh and use latest as its failure/unknown fallback.
# There is no live lookup when the declaration has no latest tag, which keeps
# resolution of pinned retained cells independent of the current upstream.
resolve_declared_real_version() {
    local container_dir="$1"
    local real_version

    if ! yq -e '.versions[]? | select(.tag == "latest")' "$container_dir/variants.yaml" >/dev/null 2>&1; then
        printf '\n'
        return 0
    fi

    if ! real_version=$(cd "$container_dir" && ./version.sh 2>/dev/null); then
        real_version="latest"
    fi
    if [[ -z "$real_version" || "$real_version" == "unknown" ]]; then
        real_version="latest"
    fi
    printf '%s\n' "$real_version"
}

# Resolve a local image only after inspecting every tag attached to its one
# image ID. The default output is the image reference for callers of the
# original helper; --json also carries the selected declared cell and local
# image ID to the identity resolver, so the normal harness path does not
# enumerate or re-resolve it twice.
# This is defined before source-only mode so unit tests can source this routing
# helper without entering the CLI setup below.
resolve_e2e_image() {
    local container="$1"
    local image_tag="${2:-}"
    local output_format="${3:-image}"
    local repo_root="${REPO_ROOT:-}"
    local github_repository_owner="${GITHUB_REPOSITORY_OWNER:-oorabona}"

    case "$output_format" in
        image|--json) ;;
        *)
            printf 'Unknown resolve_e2e_image output format: %s\n' "$output_format" >&2
            return 2
            ;;
    esac

    if [[ -z "$repo_root" ]]; then
        repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi

    if ! declare -F image_identity_resolve >/dev/null; then
        # shellcheck source=../test-harness/image-identity.sh
        source "$repo_root/test-harness/image-identity.sh"
    fi
    if ! declare -F log_error >/dev/null; then
        # shellcheck source=../helpers/logging.sh
        source "$repo_root/helpers/logging.sh"
    fi

    if [ -n "${E2E_IMAGE:-}" ]; then
        if [[ "$output_format" == "--json" ]]; then
            jq -cn --arg image "$E2E_IMAGE" '{image: $image, image_id: null, cell: null}'
        else
            printf '%s\n' "$E2E_IMAGE"
        fi
        return 0
    fi

    local images=""
    images=$(timeout -k 2 10 docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null) || true

    local ids
    ids=$(printf '%s\n' "$images" | awk -v owner="$github_repository_owner" -v container="$container" -v tag="$image_tag" '
        function starts_with(value, prefix) {
            return substr(value, 1, length(prefix)) == prefix
        }
        function local_image(value) {
            return starts_with(value, "ghcr.io/" owner "/" container ":") ||
                starts_with(value, "docker.io/" owner "/" container ":") ||
                starts_with(value, container ":")
        }
        local_image($2) && (tag == "" || $2 == "ghcr.io/" owner "/" container ":" tag ||
            $2 == "docker.io/" owner "/" container ":" tag || $2 == container ":" tag) {
            print $1
        }
    ' | sort -u)

    local count
    if [ -z "$ids" ]; then
        count=0
    else
        count=$(printf '%s\n' "$ids" | grep -c .)
    fi

    if [ "$count" -eq 0 ]; then
        if [ -n "$image_tag" ]; then
            local tagged_image
            tagged_image="docker.io/${github_repository_owner}/${container}:${image_tag}"
            log_info "Image $tagged_image was not found locally; using remote reference"
            if [[ "$output_format" == "--json" ]]; then
                jq -cn --arg image "$tagged_image" '{image: $image, image_id: null, cell: null}'
            else
                printf '%s\n' "$tagged_image"
            fi
            return 0
        fi
        log_error "No image found for $container; build it first, pass container:tag, or set E2E_IMAGE"
        return 1
    fi

    if [ "$count" -gt 1 ]; then
        log_error "Ambiguous local images for $container ($count distinct image IDs); set E2E_IMAGE"
        printf '%s\n' "$images" | awk -v owner="$github_repository_owner" -v container="$container" '
            function starts_with(value, prefix) {
                return substr(value, 1, length(prefix)) == prefix
            }
            starts_with($2, "ghcr.io/" owner "/" container ":") ||
            starts_with($2, "docker.io/" owner "/" container ":") ||
            starts_with($2, container ":") {
                print "  " $1 " " $2
            }
        ' >&2
        return 1
    fi

    # :latest commonly shares an image ID with one declared tag. Listing order
    # is not an identity contract: enumerate all retained declared cells once,
    # collect every matching tag on the image ID, and refuse if it names more
    # than one distinct cell.
    local harness_dir matrix real_version image image_id candidate candidate_tag candidate_cell selected_cell declared_cells declared_candidates declared_count
    harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if ! real_version=$(resolve_declared_real_version "$repo_root/$container"); then
        log_error "Could not resolve the current version for $container"
        return 1
    fi
    if ! matrix=$(source "$harness_dir/helpers/variant-utils.sh" && list_build_matrix "$repo_root/$container" "$real_version" true 2>/dev/null); then
        log_error "Could not enumerate declared image tags for $container"
        return 1
    fi
    image=""
    image_id="$ids"
    selected_cell=""
    declared_cells=""
    declared_candidates=""
    declared_count=0
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        candidate_tag="${candidate##*:}"
        # A cell is the matrix record, rather than just its tag: duplicate tags
        # are not a valid resolution and therefore do not count as a match.
        if candidate_cell=$(jq -c -e -r --arg tag "$candidate_tag" '
            [.[] | select(.tag == $tag)] |
            if length == 1 then .[0] else error("not one declared cell") end
        ' <<<"$matrix" 2>/dev/null); then
            if [[ $'\n'"$declared_cells"$'\n' != *$'\n'"$candidate_cell"$'\n'* ]]; then
                if [[ -n "$declared_cells" ]]; then
                    declared_candidates+=$'\n'
                fi
                declared_cells+="${declared_cells:+$'\n'}$candidate_cell"
                declared_candidates+="$candidate"
                declared_count=$((declared_count + 1))
                image="$candidate"
                # Keep the selected cell separate from the probe result: a
                # later undeclared alias must not erase this successful match.
                selected_cell="$candidate_cell"
            fi
        fi
    done < <(printf '%s\n' "$images" | awk -v id="$ids" -v owner="$github_repository_owner" -v container="$container" -v tag="$image_tag" '
        function starts_with(value, prefix) {
            return substr(value, 1, length(prefix)) == prefix
        }
        $1 == id && (starts_with($2, "ghcr.io/" owner "/" container ":") || starts_with($2, "docker.io/" owner "/" container ":") || starts_with($2, container ":")) &&
            (tag == "" || $2 == "ghcr.io/" owner "/" container ":" tag || $2 == "docker.io/" owner "/" container ":" tag || $2 == container ":" tag) {
            print $2
        }
    ')

    if [ "$declared_count" -eq 0 ]; then
        log_error "No declared image tag found for local image $ids; set E2E_IMAGE"
        return 1
    fi

    if [ "$declared_count" -gt 1 ]; then
        log_error "Ambiguous declared image tags for $container on local image $ids ($declared_count distinct declared cells); set E2E_IMAGE"
        while IFS= read -r candidate; do
            printf '  %s\n' "$candidate"
        done <<<"$declared_candidates" >&2
        return 1
    fi

    if [[ "$output_format" == "--json" ]]; then
        jq -cn --arg image "$image" --arg image_id "$image_id" --argjson cell "$selected_cell" \
            '{image: $image, image_id: $image_id, cell: $cell}'
    else
        printf '%s\n' "$image"
    fi
}

# This must stay before shell options, argument parsing, ./make, command
# validation, and the banner: sourcing for the helper above must not mutate the
# caller's shell state or run startup work.
if [[ "${E2E_TEST_SOURCE_ONLY:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

set -euo pipefail

# The readiness deadline is `SECONDS` plus a budget, and `SECONDS` is inherited:
# a caller who exports a huge one would wrap that sum negative and every wait
# would expire before it began. Reset once, here, so the deadlines below start
# from a number this script controls.
SECONDS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/helpers/logging.sh"
source "$REPO_ROOT/helpers/variant-utils.sh"
# shellcheck source=../test-harness/image-identity.sh
source "$REPO_ROOT/test-harness/image-identity.sh"

BUILD=true
CONTAINERS=""
FAILED=()
PASSED=()
GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-oorabona}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            BUILD=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [CONTAINER...]"
            echo ""
            echo "Options:"
            echo "  --no-build    Skip building images"
            echo "  -h, --help    Show this help"
            echo ""
            echo "Environment:"
            echo "  E2E_IMAGE            Test this image ref directly, skipping discovery"
            echo "  E2E_BUILD_*          Authoritative build cell for E2E_IMAGE (workflow use)"
            echo "  E2E_READY_TIMEOUT    Seconds a container gets to report ready (1-99999, default 60)"
            echo "  E2E_TEST_TIMEOUT     Seconds each container-specific suite may run (1-99999, default 600)"
            echo ""
            echo "Examples:"
            echo "  $0                    # Test all containers"
            echo "  $0 postgres openresty # Test specific containers"
            echo "  $0 --no-build         # Test with existing images"
            exit 0
            ;;
        *)
            CONTAINERS="$CONTAINERS $1"
            shift
            ;;
    esac
done

# Get list of containers to test
if [ -z "$CONTAINERS" ]; then
    CONTAINERS=$(./make list 2>/dev/null)
fi

# How long each container gets to become ready. Checked here, before anything is
# built or started: rejecting it later would leave a running container behind,
# since `docker run --rm` only cleans up once the container stops. The upper bound
# keeps `$((SECONDS + max_wait))` inside machine arithmetic — a value near INT64_MAX
# wraps to a negative deadline, which reads as a budget that has already expired.
READY_TIMEOUT="${E2E_READY_TIMEOUT:-60}"
if ! [[ "$READY_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]]; then
    log_error "E2E_READY_TIMEOUT must be a whole number of seconds between 1 and 99999 (got: $READY_TIMEOUT)"
    exit 1
fi

TEST_TIMEOUT="${E2E_TEST_TIMEOUT:-600}"
if ! [[ "$TEST_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]]; then
    log_error "E2E_TEST_TIMEOUT must be a whole number of seconds between 1 and 99999 (got: $TEST_TIMEOUT)"
    exit 1
fi

# The wait bounds each docker call with `timeout -k`, and so does the cleanup that
# removes a container after a failure. A `timeout` that is missing, or too old for
# `-k`, would therefore leave a started container running. This asks whether the
# flag is accepted, before anything is built or started — not whether the
# implementation honours it, which would cost a deliberately unkillable child on
# every invocation.
if ! timeout -k 1 1 true 2>/dev/null; then
    log_error "this harness needs a 'timeout' accepting -k (GNU coreutils provides one)"
    exit 1
fi

echo ""
echo "🧪 E2E Container Tests"
echo "======================"
echo ""

# Seconds left before the deadline, or non-zero once the budget is spent. Every
# check of "is there time left" goes through here: the loop below asks twice per
# iteration, since time passes inside the docker calls, and a second hand-written
# copy of the comparison is a second place to get it wrong. It never prints 0 —
# `timeout 0` means *no timeout* to coreutils, which is the opposite of the bound
# the caller is asking for.
#
# The budget is honoured to whole seconds: `SECONDS` has that resolution, so a
# probe admitted with a second left may return just after the deadline, and a
# child that ignores SIGTERM adds the kill-after grace on top. The bound is
# "about the budget", not a hard real-time guarantee — enough for a test harness,
# and the reason nothing here reaches for a monotonic clock.
# Usage: remaining=$(readiness_remaining <deadline>) || <budget spent>
readiness_remaining() {
    local left=$(( $1 - SECONDS ))
    [ "$left" -gt 0 ] || return 1
    printf '%s' "$left"
}

# Sleep no longer than the remaining readiness budget, so the budget is an upper
# bound on the wait rather than on its naps alone. Returns non-zero when it could
# not sleep the whole requested time — a poll interval does not care, but a caller
# that treats the delay itself as evidence does, and must not read a shortened one
# as the full one.
# Usage: sleep_within_readiness_deadline <seconds> <deadline>
sleep_within_readiness_deadline() {
    local requested="$1"
    local sleep_deadline="$2"
    local sleep_remaining=$((sleep_deadline - SECONDS))

    if [ "$sleep_remaining" -le 0 ]; then
        return 1
    fi
    if [ "$requested" -gt "$sleep_remaining" ]; then
        sleep "$sleep_remaining" || true
        return 1
    fi
    sleep "$requested"
}

# The container name is intentionally global: EXIT/INT/TERM traps run in the
# shell process, after test_container's locals have gone out of scope. Clearing
# it before returning makes cleanup safe to call on every path and makes the
# eventual EXIT trap a no-op after each container in a multi-container suite.
CLEANUP_CONTAINER_NAME=""
# Where a probe's stderr is kept while its stdout stays the value. Removed by
# cleanup_container, which runs on every path including the traps.
READINESS_STDERR_FILE=""

cleanup_container() {
    local cleanup_name="$CLEANUP_CONTAINER_NAME"
    local cleanup_output cleanup_status=0

    CLEANUP_CONTAINER_NAME=""
    trap - EXIT INT TERM

    [ -n "${READINESS_STDERR_FILE:-}" ] && rm -f "$READINESS_STDERR_FILE"
    READINESS_STDERR_FILE=""

    [ -n "$cleanup_name" ] || return 0

    cleanup_output=$(timeout -k 2 5 docker rm -f "$cleanup_name" 2>&1) || cleanup_status=$?
    # An already-absent name is the end state an idempotent cleanup wants, unlike a
    # timeout, a daemon failure, or a permission failure that can leave the
    # container running. Runtimes disagree on how they say it: Docker exits
    # non-zero with "No such container", while Podman on this machine exits 0 and
    # prints nothing, so it never reaches this test at all. Matched
    # case-insensitively because the casing is one vendor's choice and not a
    # contract — the same reason the readiness classifier lowercases its input.
    #
    # A removal that hit its own bound is never accepted on the strength of that
    # phrase: 124 and 137 mean the removal did not finish, whatever it had printed
    # before, so they stay reported rather than being read as an absent container.
    if [ "$cleanup_status" -ne 0 ] \
        && { [ "$cleanup_status" -eq 124 ] || [ "$cleanup_status" -eq 137 ] \
            || [[ "${cleanup_output,,}" != *"no such container"* ]]; }; then
        log_warning "$cleanup_name could not be removed and may still be running: $cleanup_output"
        # No retry, deliberately, and the container is then leaked: a loop around a
        # `docker rm -f` that already failed under its own bound is more machinery
        # than the leak is worth on runners that are thrown away anyway. Nor does
        # keeping the name buy anything — the traps are cleared just above, so
        # nothing would run to use it, and the next container overwrites it. The
        # warning naming the survivor is the whole of the report, on purpose.
        return 1
    fi
}

# A readiness probe can fail because its bound fired or the daemon had a
# transient problem; neither says anything about the container. These statuses
# cannot be repaired by another poll, though: the command is unavailable or the
# caller cannot use Docker. Docker reports the latter on stderr, which callers
# pass here after capturing it.
docker_readiness_failure_is_terminal() {
    local status="$1"
    local output="$2"

    case "$status" in
        126|127)
            return 0
            ;;
        124|137)
            return 1
            ;;
    esac

    case "${output,,}" in
        *"permission denied"*|*"operation not permitted"*)
            return 0
            ;;
    esac

    return 1
}

# Test a single container (or variant)
# Usage: test_container <container> [image_tag]
test_container() {
    local container="$1"
    local image_tag="${2:-}"
    local container_name="e2e-$container"
    local test_script="$REPO_ROOT/$container/test.sh"

    # Build test name for display
    local test_name="$container"
    [[ -n "$image_tag" ]] && test_name="$container:$image_tag"

    log_step "Testing $test_name..."

    # Build if requested (only for non-variant tests or when no tag specified)
    if [ -z "${E2E_IMAGE:-}" ] && [ "$BUILD" = true ] && [ -z "$image_tag" ]; then
        log_info "Building $container..."
        if ! ./make build "$container" 2>&1 | tail -5; then
            log_error "Build failed for $container"
            return 1
        fi
    fi

    # Determine image name
    local image_resolution image identity selected_cell image_id
    if ! image_resolution=$(resolve_e2e_image "$container" "$image_tag" --json); then
        return 1
    fi
    if ! image=$(jq -er '.image | strings | select(length > 0)' <<<"$image_resolution") || \
        ! selected_cell=$(jq -c '.cell' <<<"$image_resolution") || \
        ! image_id=$(jq -er '
            if .image_id == null then ""
            elif (.image_id | type == "string" and length > 0) then .image_id
            else error("invalid image ID") end
        ' <<<"$image_resolution"); then
        log_error "Could not read the resolved image for $test_name"
        return 1
    fi
    [[ "$selected_cell" == "null" ]] && selected_cell=""
    if [ -z "$image" ]; then
        log_error "No image found for $test_name"
        return 1
    fi
    log_info "Using image: $image"
    if ! identity=$(image_identity_resolve "$REPO_ROOT/$container" "$image" "$selected_cell"); then
        log_error "Could not resolve image identity for $image"
        return 1
    fi
    if [[ -z "$image_id" ]]; then
        if ! image_id=$(timeout -k 2 10 docker image inspect --format '{{.Id}}' "$image") || [[ -z "$image_id" ]]; then
            log_error "Could not resolve local image ID for $image"
            return 1
        fi
    fi

    # Clean up any existing test container before reusing its fixed name.
    CLEANUP_CONTAINER_NAME="$container_name"
    if ! cleanup_container; then
        return 1
    fi

    CLEANUP_CONTAINER_NAME="$container_name"
    trap cleanup_container EXIT
    # Cleanup failure is already reported by cleanup_container itself. The status
    # here belongs to the caller's signal, so make cleanup non-fatal and preserve
    # the promised signal exit rather than replacing it with that failure.
    trap 'cleanup_container || true; exit 130' INT
    trap 'cleanup_container || true; exit 143' TERM

    # Start container with appropriate options
    log_info "Starting $container..."
    local run_opts="--rm -d --name $container_name"

    # Container-specific run options and command
    local run_cmd=""
    case "$container" in
        postgres)
            run_opts="$run_opts -e POSTGRES_PASSWORD=test -e POSTGRES_USER=test -e POSTGRES_DB=test"
            ;;
        openvpn)
            # Run under the shipped hardened profile so the e2e actually exercises
            # the privilege drop: cap_drop:ALL + NET_ADMIN (tun/routes) + SETUID/SETGID
            # (the drop to nobody). AUTO_INSTALL/AUTO_START generate the config and
            # start the server; ENDPOINT is pinned so the installer never reaches out
            # for public-IP detection. openvpn/test.sh asserts the daemon runs as nobody.
            run_opts="$run_opts --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID"
            run_opts="$run_opts --security-opt no-new-privileges --device /dev/net/tun:/dev/net/tun"
            run_opts="$run_opts --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv4.conf.all.forwarding=1"
            run_opts="$run_opts --sysctl net.ipv6.conf.all.disable_ipv6=0 --sysctl net.ipv6.conf.all.forwarding=1"
            run_opts="$run_opts -e AUTO_INSTALL=y -e AUTO_START=y -e ENDPOINT=127.0.0.1"
            ;;
        ansible|debian)
            # These need a command to stay running
            run_cmd="sleep infinity"
            ;;
        terraform)
            # A CLI image: its default command prints help and exits, and its
            # entrypoint ends in `exec /bin/terraform "$@"`, so any command passed
            # becomes a terraform argument — `sleep infinity` would run
            # `terraform sleep infinity` and fail. Override the entrypoint so the
            # container stays up long enough for the suite to exec into it.
            run_opts="$run_opts --entrypoint sleep"
            run_cmd="infinity"
            ;;
        sslh)
            # sslh-ev is the image ENTRYPOINT, so pass ARGS ONLY (no binary name,
            # else it runs "sslh-ev sslh-ev ..." with a bogus first argument).
            # Listen on 443 to satisfy the image HEALTHCHECK (busybox nc -z 443);
            # the image runs as nobody, so grant NET_BIND_SERVICE to bind the
            # privileged port. Backends need not be reachable for sslh to listen.
            run_opts="$run_opts --cap-add NET_BIND_SERVICE"
            run_cmd="--foreground -p 0.0.0.0:443 --ssh 127.0.0.1:22 --tls 127.0.0.1:8443"
            ;;
    esac

    # A signal cannot run this shell's trap while a foreground command is active,
    # so this bound is what stops docker run deferring cleanup indefinitely over a
    # container it may already have created. It is creation, not readiness:
    # measured at ~0.7s for these images, so the budget is wide enough that only a
    # genuine hang can reach it. Run the immutable local image ID, not its mutable
    # tag: the container started is the exact image whose tags established the
    # identity above, so docker cannot pull or retag-substitute it before run.
    if ! timeout -k 5 120 docker run $run_opts "$image_id" $run_cmd; then
        log_error "Failed to start $container"
        cleanup_container
        return 1
    fi

    # Wait for container to be ready (healthcheck or basic startup)
    log_info "Waiting for $container to be ready..."
    local start=$SECONDS
    local deadline=$((start + READY_TIMEOUT))
    local ready=false
    # Declared here, not on the assignment below: `local x=$(cmd)` returns the
    # builtin's status, which would swallow the one the loop condition reads.
    local remaining health readiness_stderr
    # Status only — mktemp's stderr is deliberately NOT folded into the value. A
    # capture that merges stderr into a variable is poisoned by anything the tool
    # writes there on success, which is how a CLI that greets on stderr corrupts
    # the one thing it was asked for. mktemp's own diagnostic still reaches the
    # harness's stderr and so the run log; it just never reaches this path.
    if ! READINESS_STDERR_FILE=$(mktemp); then
        log_error "Harness could not allocate its readiness stderr temp file"
        cleanup_container
        return 1
    fi
    # Whether an image with no healthcheck has already served its grace. It is
    # readiness only once the loop has come back around and seen the container
    # still listed: a container that dies during the grace is not ready, it is a
    # container that died.
    local grace_served=0

    while remaining=$(readiness_remaining "$deadline"); do
        # Check if container is still running. A `docker ps` that does not answer —
        # because it hit its bound, or the daemon is unwell — is not the same as one
        # that answered and did not list the container, so only the latter is
        # reported as an exit. The former keeps polling and, if that is all we ever
        # get, ends as the timeout it is.
        # `-k` matters as much as the bound: plain `timeout` sends SIGTERM and then
        # waits forever for a child that ignores it, which is the hang this whole
        # change is about. The grace is what the wait can overshoot its budget by.
        local names ps_output ps_status=0
        ps_output=$(timeout -k 2 "$remaining" docker ps --format '{{.Names}}' \
            2>"$READINESS_STDERR_FILE") || ps_status=$?
        if [ "$ps_status" -ne 0 ]; then
            readiness_stderr=$(cat "$READINESS_STDERR_FILE" 2>/dev/null)
            if docker_readiness_failure_is_terminal "$ps_status" "$readiness_stderr"; then
                log_error "docker ps failed (exit $ps_status): $readiness_stderr"
                cleanup_container
                return 1
            fi
            sleep_within_readiness_deadline 2 "$deadline" || true
            continue
        fi
        names="$ps_output"
        # Fixed-string, whole-line, and fed from a here-string: a name is not a
        # pattern (docker allows `.` in one), and a pipeline whose producer is
        # still writing when `grep -q` exits on a match fails under `pipefail`,
        # which would read as the container having exited.
        if ! grep -Fxq "$container_name" <<< "$names"; then
            log_error "$container exited unexpectedly"
            timeout -k 2 5 docker logs "$container_name" 2>&1 | tail -20
            cleanup_container
            return 1
        fi

        # The container was listed just now, which is the liveness the grace was
        # waiting to confirm.
        if [ "$grace_served" -eq 1 ]; then
            ready=true
            break
        fi

        # Check health status if available. Time passed inside `docker ps`, so the
        # budget is re-read rather than reused.
        remaining=$(readiness_remaining "$deadline") || break
        # The conditional template distinguishes a missing healthcheck from an
        # inspect failure; treating the latter as no healthcheck would fail open.
        local inspect_output inspect_status=0
        inspect_output=$(timeout -k 2 "$remaining" docker inspect \
            --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' \
            "$container_name" 2>"$READINESS_STDERR_FILE") || inspect_status=$?
        if [ "$inspect_status" -ne 0 ]; then
            readiness_stderr=$(cat "$READINESS_STDERR_FILE" 2>/dev/null)
            if docker_readiness_failure_is_terminal "$inspect_status" "$readiness_stderr"; then
                log_error "docker inspect failed (exit $inspect_status): $readiness_stderr"
                cleanup_container
                return 1
            fi
            health="unavailable"
        else
            health="$inspect_output"
        fi

        case "$health" in
            healthy)
                ready=true
                break
                ;;
            unhealthy)
                log_error "$container is unhealthy"
                timeout -k 2 5 docker logs "$container_name" 2>&1 | tail -20
                cleanup_container
                return 1
                ;;
            starting)
                ;;
            nohealth)
                # Nothing to consult, so the only evidence of readiness is that
                # the grace elapsed with the container still up. A grace cut short
                # by the budget is not that evidence; neither is one the container
                # did not survive, which is why this loops once more instead of
                # declaring readiness on the strength of a liveness check taken
                # three seconds ago.
                if ! sleep_within_readiness_deadline 3 "$deadline"; then
                    break
                fi
                grace_served=1
                continue
                ;;
        esac

        # A shortened poll interval is fine — the loop condition re-checks anyway.
        sleep_within_readiness_deadline 2 "$deadline" || true
        printf "\r    ⏳ Waiting... (%ds)" "$((SECONDS - start))"
    done
    echo ""

    if [ "$ready" != true ]; then
        log_error "$container did not become ready in time"
        timeout -k 2 5 docker logs "$container_name" 2>&1 | tail -20
        cleanup_container
        return 1
    fi

    # The per-container script is the point of this run, not an optional extra:
    # everything above it is a generic liveness check that any image passes. A
    # missing or non-executable script used to be skipped in silence, so deleting
    # one — or losing its mode in a checkout — turned a suite into a container
    # that merely started, and the run still reported success. This harness has
    # been silently unrun once already; it says so now.
    if [ ! -e "$test_script" ]; then
        log_error "$container has no test script at ${test_script#"$REPO_ROOT"/}"
        log_error "Nothing container-specific would be verified — refusing to report success."
        cleanup_container
        return 1
    fi
    if [ ! -x "$test_script" ]; then
        log_error "${test_script#"$REPO_ROOT"/} is not executable, so it cannot run."
        cleanup_container
        return 1
    fi

    log_info "Running custom tests for $container..."
    # The suite is invoked directly, so `timeout` monitors the suite itself and its
    # `-k` escalation lands on the process that is actually hanging.
    #
    # Which means 124 and 137 are ambiguous, and the message below does not pretend
    # otherwise. `timeout` returns its command's own status when the deadline did
    # not fire, and web-shell/test.sh runs `timeout` and can propagate exactly
    # those. Two ways to resolve that ambiguity were built and both were worse than
    # the ambiguity: comparing elapsed whole seconds is an inference that misreads a
    # suite exiting across a tick, and having the suite record its own status through
    # a wrapper put `bash -c` between `timeout` and the suite — so the bound killed
    # the wrapper, `-k` never reached the suite, and a TERM-ignoring suite outlived
    # the thing meant to bound it. The report states the status and what could have
    # produced it, which is what is actually known.
    local test_status=0
    # Suites receive one already-resolved record and assertion helpers, rather
    # than the reference itself or separately-derived version/flavor variables.
    # Unset E2E_IMAGE so a suite cannot accidentally revive tag parsing.
    env -u E2E_IMAGE CONTAINER_NAME="$container_name" E2E_IMAGE_IDENTITY="$identity" \
        timeout -k 5 "$TEST_TIMEOUT" "$test_script" || test_status=$?
    if [ "$test_status" -ne 0 ]; then
        case "$test_status" in
            124|137)
                log_error "Custom tests failed for $container (exit $test_status — the ${TEST_TIMEOUT}s bound reports 124, or 137 after its kill grace, and a suite can also return either itself)"
                ;;
            *)
                log_error "Custom tests failed for $container (exit $test_status)"
                ;;
        esac
        cleanup_container
        return 1
    fi

    # Cleanup
    if ! cleanup_container; then
        return 1
    fi

    log_success "$container passed ✅"
    return 0
}

# Run tests
for arg in $CONTAINERS; do
    if [ -n "${E2E_IMAGE:-}" ]; then
        container="${arg%%:*}"
        echo ""
        if test_container "$container"; then
            PASSED+=("$container")
        else
            FAILED+=("$container")
        fi
        continue
    fi

    # Check if argument contains a tag (container:tag format)
    if [[ "$arg" == *":"* ]]; then
        container="${arg%%:*}"
        tag_part="${arg#*:}"
        container_dir="$REPO_ROOT/$container"

        # Determine if tag_part is a version (e.g., "16") or a full tag (e.g., "16-full-alpine")
        if [[ "$tag_part" =~ ^[0-9]+$ ]]; then
            # It's a version number - test all variants for this version
            local_version="$tag_part"

            if has_variants "$container_dir"; then
                log_info "$container:$local_version - testing all variants..."

                # Build all variants if requested
                if [ "$BUILD" = true ]; then
                    log_info "Building all variants for $container v$local_version..."
                    if ! ./make build "$container" "$local_version" 2>&1 | tail -10; then
                        log_error "Build failed for $container v$local_version"
                        FAILED+=("$container:$local_version")
                        continue
                    fi
                fi

                # Test each variant
                while IFS= read -r variant_name; do
                    [[ -z "$variant_name" ]] && continue

                    variant_tag=$(variant_image_tag "$local_version" "$variant_name" "$container_dir")
                    echo ""

                    if test_container "$container" "$variant_tag"; then
                        PASSED+=("$container:$variant_tag")
                    else
                        FAILED+=("$container:$variant_tag")
                    fi
                done < <(list_variants "$container_dir" "$local_version")
            else
                # No variants - test single image with this version
                echo ""
                if test_container "$container" "$local_version"; then
                    PASSED+=("$container:$local_version")
                else
                    FAILED+=("$container:$local_version")
                fi
            fi
        else
            # It's a full tag - test specific variant
            echo ""
            log_info "Testing specific variant: $container:$tag_part"

            if test_container "$container" "$tag_part"; then
                PASSED+=("$container:$tag_part")
            else
                FAILED+=("$container:$tag_part")
            fi
        fi
    else
        container="$arg"
        container_dir="$REPO_ROOT/$container"

        # Check if container has variants
        if has_variants "$container_dir"; then
            log_error "$container has variants - please specify version (e.g., $container:16)"
            FAILED+=("$container")
            continue
        else
            # No variants - test single image
            echo ""
            if test_container "$container"; then
                PASSED+=("$container")
            else
                FAILED+=("$container")
            fi
        fi
    fi
done

# Summary
echo ""
echo "========================================"
echo "E2E Test Summary"
echo "========================================"
echo ""

if [ ${#PASSED[@]} -gt 0 ]; then
    log_success "Passed (${#PASSED[@]}): ${PASSED[*]}"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    log_error "Failed (${#FAILED[@]}): ${FAILED[*]}"
    echo ""
    exit 1
fi

log_success "All ${#PASSED[@]} containers passed! 🎉"
exit 0
