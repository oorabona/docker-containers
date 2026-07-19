#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [openvpn-image]" >&2
    exit 2
fi

image="${1:-${OPENVPN_IMAGE:-}}"
if [ -z "$image" ]; then
    echo "openvpn restart lifecycle: image ref required as argv[1] or OPENVPN_IMAGE" >&2
    exit 2
fi

suffix="${GITHUB_RUN_ID:-local}-$$-${RANDOM}"
volume="openvpn-restart-lifecycle-${suffix}"
bootstrap_container="openvpn-restart-bootstrap-${suffix}"
restart_container="openvpn-restart-existing-${suffix}"

cleanup() {
    local status=$?
    set +e
    docker rm -f "$bootstrap_container" "$restart_container" >/dev/null 2>&1
    docker volume rm -f "$volume" >/dev/null 2>&1
    return "$status"
}
trap cleanup EXIT

run_opts=(
    --cap-drop ALL
    --cap-add NET_ADMIN
    --cap-add SETUID
    --cap-add SETGID
    --security-opt no-new-privileges
    --device /dev/net/tun:/dev/net/tun
    --sysctl net.ipv4.ip_forward=1
    --sysctl net.ipv4.conf.all.forwarding=1
    --sysctl net.ipv6.conf.all.disable_ipv6=0
    --sysctl net.ipv6.conf.all.forwarding=1
)

log() {
    printf 'openvpn restart lifecycle: %s\n' "$*"
}

fail() {
    printf 'openvpn restart lifecycle: ERROR: %s\n' "$*" >&2
    exit 1
}

show_logs_tail() {
    local container="$1"

    docker logs "$container" 2>&1 | tail -80 >&2 || true
}

openvpn_server_pids() {
    local container="$1"

    docker exec "$container" sh -c '
pids=""
if command -v pgrep >/dev/null 2>&1; then
    pids=$(pgrep -x openvpn 2>/dev/null || true)
else
    for comm in /proc/[0-9]*/comm; do
        [ -r "$comm" ] || continue
        [ "$(cat "$comm" 2>/dev/null)" = openvpn ] || continue
        pid=${comm#/proc/}
        pids="${pids} ${pid%/comm}"
    done
fi

found=0
for pid in $pids; do
    cmdline=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmdline" in
        *openvpn*--config*) printf "%s\n" "$pid"; found=1 ;;
    esac
done
[ "$found" -eq 1 ]
' 2>/dev/null
}

wait_for_openvpn() {
    local container="$1"
    local phase="$2"
    local deadline
    local pids
    local status

    deadline=$((SECONDS + 150))
    while [ "$SECONDS" -lt "$deadline" ]; do
        status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
        if [ "$status" != "running" ]; then
            show_logs_tail "$container"
            fail "$phase container stopped before the OpenVPN server started (state: ${status:-missing})"
        fi

        pids="$(openvpn_server_pids "$container" || true)"
        if [ -n "$pids" ]; then
            log "$phase OpenVPN server is running"
            printf 'openvpn restart lifecycle: %s server pid(s):\n%s\n' "$phase" "$pids"
            return 0
        fi

        sleep 3
    done

    show_logs_tail "$container"
    fail "$phase OpenVPN server did not start within 150s"
}

assert_no_interactive_prompt() {
    local container="$1"
    local logs

    logs="$(docker logs "$container" 2>&1 || true)"
    if printf '%s\n' "$logs" | grep -Eq 'Select an option|Welcome to the OpenVPN installer'; then
        printf '%s\n' "openvpn restart lifecycle: ERROR: restart logs show installer/menu prompt" >&2
        printf '%s\n' "$logs" | tail -80 >&2
        exit 1
    fi
}

assert_nat_masquerade() {
    local container="$1"

    # The restart path must regenerate and apply the iptables rules, else OpenVPN
    # runs but client traffic is not NATed. Assert the MASQUERADE rule is present.
    if ! docker exec "$container" iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE; then
        show_logs_tail "$container"
        fail "restart did not apply the NAT MASQUERADE rule (client traffic would not route)"
    fi
    log "restart NAT MASQUERADE rule is applied"
}

pki_ca_hash() {
    local container="$1"
    local hash

    if ! hash="$(docker exec "$container" sha256sum /etc/openvpn/easy-rsa/pki/ca.crt 2>/dev/null | awk '{print $1}')"; then
        show_logs_tail "$container"
        fail "could not read generated CA certificate from $container"
    fi
    if [ -z "$hash" ]; then
        show_logs_tail "$container"
        fail "generated CA certificate hash was empty in $container"
    fi

    printf '%s\n' "$hash"
}

log "using image $image"
log "creating volume $volume"
docker volume create "$volume" >/dev/null

log "bootstrap boot: install and start with persisted /etc/openvpn"
docker run -d \
    --name "$bootstrap_container" \
    "${run_opts[@]}" \
    -v "$volume:/etc/openvpn" \
    -e START_EXISTING=y \
    -e AUTO_INSTALL=y \
    -e AUTO_START=y \
    -e ENDPOINT=127.0.0.1 \
    "$image" >/dev/null
wait_for_openvpn "$bootstrap_container" "bootstrap"

ca_before="$(pki_ca_hash "$bootstrap_container")"
log "bootstrap generated CA certificate hash: $ca_before"

log "destroying bootstrap container and keeping volume"
docker rm -f "$bootstrap_container" >/dev/null

log "restart boot: start existing config non-interactively"
# AUTO_INSTALL=y is set alongside START_EXISTING=y — matching the shipped Compose
# config — to prove START_EXISTING takes precedence over AUTO_INSTALL for an
# existing config (it must start the server, not re-run the installer).
docker run -d \
    --name "$restart_container" \
    "${run_opts[@]}" \
    -v "$volume:/etc/openvpn" \
    -e START_EXISTING=y \
    -e AUTO_INSTALL=y \
    -e AUTO_START=y \
    "$image" >/dev/null
wait_for_openvpn "$restart_container" "restart"
assert_no_interactive_prompt "$restart_container"
assert_nat_masquerade "$restart_container"
ca_after="$(pki_ca_hash "$restart_container")"
if [ "$ca_before" != "$ca_after" ]; then
    fail "restart changed the persisted CA certificate hash (before: $ca_before, after: $ca_after)"
fi
log "PASS: restart preserved existing CA certificate hash"

# Stability: guard against a start-then-exit restart. The server must still be
# running after a short settle interval, not merely have existed once.
sleep 5
wait_for_openvpn "$restart_container" "restart-stable"

log "PASS: existing /etc/openvpn volume restarts non-interactively with START_EXISTING=y"
