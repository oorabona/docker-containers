#!/bin/bash
# Integration test for the Tor Playground stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=120
# A dedicated Compose project, not the directory-derived default: running
# this test must never touch a reader's own already-running `docker compose
# up -d` playground session (or its `tor-data` volume) in the same
# directory — confirmed, cleanup only ever tears down this project's own
# resources. It does NOT make the test itself runnable alongside a
# reader's session, though: docker-compose.yaml still publishes a fixed
# host port (127.0.0.1:9050), which is global regardless of Compose
# project, so `compose up -d` here will fail to bind if a reader's own
# instance already holds it — harmlessly (this script exits non-zero,
# their stack stays untouched), just not concurrently runnable.
PROJECT="tor-playground-test-$$"

compose() {
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
}

cleanup() {
    echo "  Cleaning up..."
    compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

if ! command -v xxd >/dev/null 2>&1; then
    echo "  FAIL: 'xxd' is required on the host to run this test (hex-encodes the control cookie)"
    exit 1
fi

echo "  Testing Tor Playground Stack..."

echo "  Starting services..."
compose up -d

echo "  Confirming nyx is present (monitoring flavor smoke check)..."
compose exec -T tor nyx --version >/dev/null

# The SOCKS and control-port checks below run curl/nc *inside* the
# container via `compose exec`, not against the host-published port — this
# stack's published 127.0.0.1:9050 is for a reader pointing their own
# tools at it, not something this test needs to depend on. It means the
# test can't collide with anything already bound to 9050 on the host.
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
        | compose exec -T tor nc 127.0.0.1 9051 2>/dev/null || echo ""
)
mapfile -t reply_lines < <(printf '%s' "$signal_response" | tr -d '\r')
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
