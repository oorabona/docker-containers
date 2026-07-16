#!/bin/bash
# Integration test for the Tor Playground stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=120

cleanup() {
    echo "  Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing Tor Playground Stack..."

echo "  Starting services..."
docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null

# Wait for a real Tor circuit through the SOCKS proxy directly, rather than
# on the image's Docker healthcheck status — the fleet's push pipeline
# (--provenance/--sbom flags on buildx) currently drops HEALTHCHECK from
# the pushed OCI config repo-wide, so .State.Health is nil on every
# container here, not just this one (tracked separately, not this stack's
# bug to work around silently).
echo "  Waiting for a Tor circuit through the SOCKS proxy..."
elapsed=0
response=""
while [ $elapsed -lt $TIMEOUT ]; do
    response=$(curl -fsS --connect-timeout 10 --max-time 20 \
        --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null || echo "")
    echo "$response" | grep -q '"IsTor":true' && break
    sleep 3
    elapsed=$((elapsed + 3))
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
cookie=$(docker compose -f "$COMPOSE_FILE" exec -T tor cat /var/lib/tor/control_auth_cookie | xxd -p | tr -d '\n')
signal_response=$(
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" \
        | docker compose -f "$COMPOSE_FILE" exec -T tor nc 127.0.0.1 9051 2>/dev/null || echo ""
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
