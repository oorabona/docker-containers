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
# Set E2E_READY_TIMEOUT=<seconds> (1-99999, default 60) to give a container with a
# slow healthcheck longer to report itself ready.

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
            echo "  E2E_READY_TIMEOUT    Seconds a container gets to report ready (1-99999, default 60)"
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

resolve_e2e_image() {
    local container="$1"
    local image_tag="${2:-}"

    if [ -n "${E2E_IMAGE:-}" ]; then
        printf '%s\n' "$E2E_IMAGE"
        return 0
    fi

    if [ -n "$image_tag" ]; then
        printf 'docker.io/%s/%s:%s\n' "$GITHUB_REPOSITORY_OWNER" "$container" "$image_tag"
        return 0
    fi

    local images=""
    images=$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null) || true

    local ids
    ids=$(printf '%s\n' "$images" | awk -v owner="$GITHUB_REPOSITORY_OWNER" -v container="$container" '
        function starts_with(value, prefix) {
            return substr(value, 1, length(prefix)) == prefix
        }
        starts_with($2, "ghcr.io/" owner "/" container ":") ||
        starts_with($2, "docker.io/" owner "/" container ":") ||
        starts_with($2, container ":") {
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
        log_error "No image found for $container; build it first, pass container:tag, or set E2E_IMAGE"
        return 1
    fi

    if [ "$count" -gt 1 ]; then
        log_error "Ambiguous local images for $container ($count distinct image IDs); set E2E_IMAGE"
        printf '%s\n' "$images" | awk -v owner="$GITHUB_REPOSITORY_OWNER" -v container="$container" '
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

    local image
    image=$(printf '%s\n' "$images" | awk -v id="$ids" -v owner="$GITHUB_REPOSITORY_OWNER" -v container="$container" '
        function starts_with(value, prefix) {
            return substr(value, 1, length(prefix)) == prefix
        }
        $1 == id && (
            starts_with($2, "ghcr.io/" owner "/" container ":") ||
            starts_with($2, "docker.io/" owner "/" container ":") ||
            starts_with($2, container ":")
        ) {
            print $2
            exit
        }
    ')

    printf '%s\n' "$image"
}

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
    local image
    if ! image=$(resolve_e2e_image "$container" "$image_tag"); then
        return 1
    fi
    if [ -z "$image" ]; then
        log_error "No image found for $test_name"
        return 1
    fi
    log_info "Using image: $image"

    # Clean up any existing test container
    docker rm -f "$container_name" 2>/dev/null || true

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

    if ! docker run $run_opts "$image" $run_cmd; then
        log_error "Failed to start $container"
        return 1
    fi

    # Wait for container to be ready (healthcheck or basic startup)
    log_info "Waiting for $container to be ready..."
    local start=$SECONDS
    local deadline=$((start + READY_TIMEOUT))
    local ready=false
    # Declared here, not on the assignment below: `local x=$(cmd)` returns the
    # builtin's status, which would swallow the one the loop condition reads.
    local remaining health
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
        local names ps_status=0
        names=$(timeout -k 2 "$remaining" docker ps --format '{{.Names}}' 2>/dev/null) || ps_status=$?
        if [ "$ps_status" -ne 0 ]; then
            sleep_within_readiness_deadline 2 "$deadline" || true
            continue
        fi
        # Fixed-string, whole-line, and fed from a here-string: a name is not a
        # pattern (docker allows `.` in one), and a pipeline whose producer is
        # still writing when `grep -q` exits on a match fails under `pipefail`,
        # which would read as the container having exited.
        if ! grep -Fxq "$container_name" <<< "$names"; then
            log_error "$container exited unexpectedly"
            timeout -k 2 5 docker logs "$container_name" 2>&1 | tail -20
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
        if ! health=$(timeout -k 2 "$remaining" docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$container_name" 2>/dev/null); then
            health="unavailable"
        fi

        case "$health" in
            healthy)
                ready=true
                break
                ;;
            unhealthy)
                log_error "$container is unhealthy"
                timeout -k 2 5 docker logs "$container_name" 2>&1 | tail -20
                timeout -k 2 5 docker rm -f "$container_name" 2>/dev/null ||
                log_warning "$container_name could not be removed and may still be running"
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
        timeout -k 2 5 docker rm -f "$container_name" 2>/dev/null ||
            log_warning "$container_name could not be removed and may still be running"
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
        docker rm -f "$container_name" 2>/dev/null || true
        return 1
    fi
    if [ ! -x "$test_script" ]; then
        log_error "${test_script#"$REPO_ROOT"/} is not executable, so it cannot run."
        docker rm -f "$container_name" 2>/dev/null || true
        return 1
    fi

    log_info "Running custom tests for $container..."
    if ! CONTAINER_NAME="$container_name" "$test_script"; then
        log_error "Custom tests failed for $container"
        docker rm -f "$container_name" 2>/dev/null || true
        return 1
    fi

    # Cleanup
    docker rm -f "$container_name" 2>/dev/null || true

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
