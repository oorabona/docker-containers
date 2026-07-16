#!/bin/bash
# Integration test for the Tor Playground stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TEST_OVERRIDE="$(dirname "$0")/docker-compose.test.yaml"
TIMEOUT=120

# Dependency checks come before anything else uses these tools (the
# project-name generation below needs xxd) — a missing dependency should
# be the first thing reported, not a raw "command not found" partway in.
if ! command -v xxd >/dev/null 2>&1; then
    echo "  FAIL: 'xxd' is required on the host to run this test (hex-encodes random bytes and the control cookie)"
    exit 1
fi

# GNU sort -V isn't available on stock macOS/BSD hosts, so version
# comparison is done with plain arithmetic instead — portable back to
# bash 3.2 (macOS's stock /bin/bash), no external tool required.
version_at_least() {
    local required="$1" actual="$2" i
    local IFS=.
    # Unquoted on purpose: this is exactly the IFS=. word-split the function
    # needs to tokenize "2.24.4" into its three parts. `read -a`/`mapfile`
    # would avoid the shellcheck warning but reintroduce the bash 4+
    # dependency this function exists to avoid; $required/$actual are
    # either the hardcoded literal above or a `docker compose version`
    # string, never attacker-controlled input.
    # shellcheck disable=SC2206
    local -a req=($required) act=($actual)
    for i in 0 1 2; do
        local r="${req[i]:-0}" a="${act[i]:-0}"
        a="${a%%[^0-9]*}"
        [ -z "$a" ] && a=0
        if [ "$a" -gt "$r" ] 2>/dev/null; then return 0; fi
        if [ "$a" -lt "$r" ] 2>/dev/null; then return 1; fi
    done
    return 0
}

# The test override needs !override (Compose 2.24.4+) to actually clear the
# base file's port publish — on anything older, `compose up` below fails
# with a confusing YAML-merge error instead of a clear version message.
compose_version=$(docker compose version --short 2>/dev/null || echo "0")
if ! version_at_least "2.24.4" "$compose_version"; then
    echo "  FAIL: Docker Compose 2.24.4+ is required (found: ${compose_version:-unknown}) — this test's override uses the !override YAML merge tag"
    exit 1
fi

# A dedicated Compose project, not the directory-derived default: running
# this test must never touch a reader's own already-running `docker compose
# up -d` playground session (or its `tor-data` volume) in the same
# directory — confirmed, cleanup only ever tears down this project's own
# resources. The PID alone isn't unique across separate PID namespaces
# that might share one Docker daemon (containerized CI running several
# jobs against the same daemon, for instance); pairing it with 8 random
# bytes (not bash's 15-bit $RANDOM) makes an actual collision the kind of
# thing that doesn't happen in practice, not just "unlikely."
PROJECT="tor-playground-test-$$-$(head -c8 /dev/urandom | xxd -p | tr -d '\n')"

compose() {
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" -f "$TEST_OVERRIDE" "$@"
}

cleanup() {
    echo "  Cleaning up..."
    compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing Tor Playground Stack..."

echo "  Starting services..."
compose up -d

echo "  Confirming nyx is present (monitoring flavor smoke check)..."
compose exec -T tor nyx --version >/dev/null

# The SOCKS and control-port checks below run curl/nc *inside* the
# container via `compose exec`, not against a host-published port — and
# thanks to TEST_OVERRIDE clearing the port publish entirely, `compose up
# -d` above didn't need host port 9050 either. The whole test run is free
# of any host-port dependency, so it can't collide with a reader's own
# playground session, local Tor, or anything else already bound to 9050.
echo "  Waiting for a Tor circuit through the SOCKS proxy..."
start=$SECONDS
response=""
while (( SECONDS - start < TIMEOUT )); do
    response=$(compose exec -T tor curl -fsS --connect-timeout 10 --max-time 20 \
        --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null || echo "")
    echo "$response" | grep -q '"IsTor":true' && break
    sleep 3
done

if ! echo "$response" | grep -q '"IsTor":true'; then
    echo "  FAIL: check.torproject.org did not confirm a Tor circuit within ${TIMEOUT}s (got: $response)"
    exit 1
fi
echo "  OK SOCKS proxy is carrying traffic through Tor"

# Test: the scripted control-port path from the README/blog post actually works.
# The cookie never becomes part of a docker/container argv (visible via `ps`
# in either namespace while the command runs) — it's piped in as stdin to a
# bare `nc`, not interpolated into an `sh -c "..."` string.
echo "  Checking control-port NEWNYM signal..."
cookie=$(compose exec -T tor cat /var/lib/tor/control_auth_cookie | xxd -p | tr -d '\n')
signal_response=$(
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" \
        | compose exec -T tor nc -w 15 127.0.0.1 9051 2>/dev/null || echo ""
)
# A plain read loop, not `mapfile` (bash 4+ only — macOS's stock
# /bin/bash is still 3.2), so this stays portable to the same bash
# version every other example's test.sh already assumes. The `||
# [ -n "$line" ]` matters: $(...) strips ALL trailing newlines, and Tor's
# QUIT isn't documented as guaranteeing a reply of its own — if SIGNAL
# NEWNYM's "250 OK" ends up as the final, non-newline-terminated line,
# a bare `while read` silently drops it (read returns false at EOF even
# with real data in $line), turning a genuinely successful exchange into
# a false test failure.
reply_lines=()
while IFS= read -r line || [ -n "$line" ]; do
    reply_lines+=("$line")
done < <(printf '%s' "$signal_response" | tr -d '\r')
# Each line sent gets exactly one reply line in order — line 1 is
# AUTHENTICATE's response, line 2 is SIGNAL NEWNYM's. Checking their exact
# content (not just "at least N '250' lines somewhere in the output")
# means AUTHENTICATE succeeding while SIGNAL itself fails can't slip
# through as a pass.
if [ "${reply_lines[0]:-}" = "250 OK" ] && [ "${reply_lines[1]:-}" = "250 OK" ]; then
    echo "  OK Control port authenticated and accepted SIGNAL NEWNYM"
else
    echo "  FAIL: expected '250 OK' for both AUTHENTICATE and SIGNAL NEWNYM, got: ${reply_lines[*]:-<empty>} (raw: $signal_response)"
    exit 1
fi

echo "  All Tor Playground Stack tests passed"
