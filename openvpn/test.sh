#!/bin/bash
# E2E test for openvpn container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-openvpn}"

echo "  Testing OpenVPN..."

# Test OpenVPN version
echo "  Checking OpenVPN version..."
docker exec "$CONTAINER_NAME" openvpn --version 2>&1 | head -1

# Test easyrsa is available
echo "  Checking EasyRSA..."
if docker exec "$CONTAINER_NAME" which easyrsa &>/dev/null || \
   docker exec "$CONTAINER_NAME" test -x /usr/share/easy-rsa/easyrsa 2>/dev/null; then
    echo "  ✅ EasyRSA available"
else
    echo "  ⚠️  EasyRSA not found"
fi

# Test iptables (needed for routing)
echo "  Checking iptables..."
if docker exec "$CONTAINER_NAME" which iptables &>/dev/null; then
    echo "  ✅ iptables available"
else
    echo "  ⚠️  iptables not found"
fi

# Assert EVERY OpenVPN server daemon dropped to the unprivileged nobody/nogroup
# user and holds no capabilities. The container runs under cap_drop:ALL +
# NET_ADMIN + SETUID + SETGID with AUTO_INSTALL/AUTO_START (set in
# tests/e2e-test.sh), so it generates the PKI then starts openvpn, which drops
# per its server.conf's `user nobody` / `group nogroup`. That drop needs
# CAP_SETUID/CAP_SETGID under cap_drop:ALL and OpenVPN aborts if it fails, so a
# root daemon (or a container that exited) means the reduced profile is broken.
# PKI generation can take ~30-60s, so poll until a daemon reaches its dropped
# state before asserting the full credential + capability set.
echo "  Checking OpenVPN daemon(s) dropped to nobody/nogroup with no held caps..."

# Expected ids resolved from the container (the drop is name-based, so read the
# real ids rather than hard-coding 65534/65533). Unresolvable => hard failure,
# never a guess: a wrong expected id could false-pass or false-fail the drop.
nobody_uid=$(docker exec "$CONTAINER_NAME" id -u nobody 2>/dev/null || true)
nogroup_gid=$(docker exec "$CONTAINER_NAME" sh -c 'getent group nogroup 2>/dev/null | cut -d: -f3' 2>/dev/null || true)
if [ -z "$nobody_uid" ] || [ -z "$nogroup_gid" ]; then
    echo "  ❌ could not resolve nobody uid ('$nobody_uid') / nogroup gid ('$nogroup_gid') in the container — cannot verify the drop"
    exit 1
fi

# Verify one daemon PID's FULL dropped state. Re-reads /proc/cmdline first so a
# reused PID is rejected, then requires real+eff+saved+fs UID == nobody,
# real+eff+saved+fs GID == nogroup, supplementary groups ⊆ {nogroup}, and the
# held capability sets (Inh/Prm/Eff/Amb) all empty (Bnd is the ceiling, allowed).
assert_daemon_dropped() {
    local pid="$1" cmd st uid_line gid_line groups_line want_uid want_gid capname capval fail=0
    # Re-read the cmdline to reject a reused PID whose args no longer match the
    # openvpn server. (We can't use /proc/$pid/exe here: once openvpn drops to
    # nobody its dumpable flag is 0, so /proc/$pid/exe is only readable with
    # CAP_SYS_PTRACE — which this hardened profile deliberately does not grant.)
    cmd=$(docker exec "$CONTAINER_NAME" sh -c "tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null" 2>/dev/null || true)
    case "$cmd" in
        *openvpn*--config*) : ;;
        *) echo "    ❌ pid $pid is no longer the openvpn server (cmdline='$cmd')"; return 1 ;;
    esac
    st=$(docker exec "$CONTAINER_NAME" cat "/proc/$pid/status" 2>/dev/null)
    [ -n "$st" ] || { echo "    ❌ pid $pid: /proc status unreadable"; return 1; }

    uid_line=$(printf '%s\n' "$st" | awk '/^Uid:/{print $2, $3, $4, $5}')
    gid_line=$(printf '%s\n' "$st" | awk '/^Gid:/{print $2, $3, $4, $5}')
    groups_line=$(printf '%s\n' "$st" | awk '/^Groups:/{$1=""; sub(/^[ \t]+/,""); print}')
    want_uid="$nobody_uid $nobody_uid $nobody_uid $nobody_uid"
    want_gid="$nogroup_gid $nogroup_gid $nogroup_gid $nogroup_gid"

    [ "$uid_line" = "$want_uid" ] || { echo "    ❌ pid $pid Uid='$uid_line' (real eff saved fs), expected all $nobody_uid"; fail=1; }
    [ "$gid_line" = "$want_gid" ] || { echo "    ❌ pid $pid Gid='$gid_line', expected all $nogroup_gid"; fail=1; }
    case "$groups_line" in
        ""|"$nogroup_gid") : ;;
        *) echo "    ❌ pid $pid supplementary Groups='$groups_line', expected empty or $nogroup_gid"; fail=1 ;;
    esac
    for capname in CapInh CapPrm CapEff CapAmb; do
        capval=$(printf '%s\n' "$st" | awk -v k="^${capname}:" '$0 ~ k {print $2}')
        case "$capval" in
            0000000000000000) : ;;
            *) echo "    ❌ pid $pid $capname='$capval', expected 0000000000000000"; fail=1 ;;
        esac
    done
    return "$fail"
}

# Classify a container that exited before the drop could be verified. A failed
# privilege drop (missing SETUID/SETGID) is a HARD failure — that is exactly the
# regression this test exists to catch. A first-run install that could not fetch
# EasyRSA from GitHub (this image downloads it at runtime) is an infrastructure /
# network problem, not a privilege regression, so it SKIPs loudly rather than
# reporting a false red. Anything else fails, so unknown breakage is never hidden.
classify_exit_and_leave() {
    if printf '%s\n' "$last_logs" | grep -qiE 'set(gid|uid|groups).*failed|Operation not permitted'; then
        echo "  ❌ openvpn aborted on its privilege drop — the reduced capability profile is broken"
        printf '%s\n' "$last_logs" | tail -30
        exit 1
    elif printf '%s\n' "$last_logs" | grep -qiE 'Could not download EasyRSA|wget:|curl:|Could not resolve|Temporary failure in name resolution|api\.github\.com'; then
        echo "  ⚠️  SKIPPED: first-run install could not fetch EasyRSA from GitHub (network / rate-limit)."
        echo "  ⚠️  The openvpn privilege drop was NOT verified this run — infrastructure issue, not a regression."
        exit 0
    else
        echo "  ❌ container exited before the openvpn daemon started (cause unclear)"
        printf '%s\n' "$last_logs" | tail -40
        exit 1
    fi
}

drop_deadline=$((SECONDS + 150))
last_logs=""
pids=""
while [ "$SECONDS" -lt "$drop_deadline" ]; do
    # Snapshot logs while the container still exists (e2e runs it with --rm, so
    # after an early exit the logs are gone — keep the last good copy).
    logs=$(docker logs "$CONTAINER_NAME" 2>/dev/null) && [ -n "$logs" ] && last_logs="$logs"

    if ! docker ps --format '{{.Names}}' | grep -Fxq -- "$CONTAINER_NAME"; then
        classify_exit_and_leave
    fi

    # ALL server daemons (processes with --config) — not the `openvpn --version`
    # healthcheck (no --config), not the root ovpn bash wrapper. [o] avoids the
    # awk process matching itself.
    pids=$(docker exec "$CONTAINER_NAME" sh -c \
        "ps -eo pid,args 2>/dev/null | awk '/[o]penvpn.*--config/{print \$1}'" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        # Break only once EVERY current daemon has left the transient root phase,
        # so a still-starting sibling never triggers a premature false failure.
        all_dropped=1
        for p in $pids; do
            ru=$(docker exec "$CONTAINER_NAME" sh -c "awk '/^Uid:/{print \$2}' /proc/$p/status 2>/dev/null" 2>/dev/null || true)
            { [ -n "$ru" ] && [ "$ru" != "0" ]; } || all_dropped=0
        done
        [ "$all_dropped" = 1 ] && break
    fi
    sleep 3
done

if [ -z "$pids" ]; then
    # Never saw a server daemon — distinguish a crash (classify) from a hang.
    docker ps --format '{{.Names}}' | grep -Fxq -- "$CONTAINER_NAME" || classify_exit_and_leave
    echo "  ❌ no openvpn server daemon (--config) found within timeout"
    [ -n "$last_logs" ] && printf '%s\n' "$last_logs" | tail -40
    exit 1
fi

# EVERY daemon must be fully dropped — one root/capped process fails the test.
all_ok=1
count=0
for p in $pids; do
    count=$((count + 1))
    if assert_daemon_dropped "$p"; then
        echo "    ✅ pid $p: UID/GID all nobody/nogroup, no held caps"
    else
        all_ok=0
    fi
done

if [ "$all_ok" -ne 1 ]; then
    echo "  ❌ privilege drop assertion FAILED ($count daemon process(es) checked)"
    [ -n "$last_logs" ] && printf '%s\n' "$last_logs" | tail -40
    exit 1
fi
echo "  ✅ all $count openvpn server daemon(s) dropped to nobody/nogroup with no held capabilities"

echo "  ✅ All OpenVPN tests passed"
