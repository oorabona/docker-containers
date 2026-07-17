#!/bin/bash
# Integration test for Web Shell + OpenResty stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=30

cleanup() {
    echo "  Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing Web Terminal Stack..."

# Start the stack
echo "  Starting services..."
docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null

# Wait for web-shell to be healthy
echo "  Waiting for web-shell to be ready..."
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    if docker compose -f "$COMPOSE_FILE" exec -T web-shell curl -fsS http://localhost:7681/token 2>/dev/null | grep -q "token"; then
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ $elapsed -ge $TIMEOUT ]; then
    echo "  FAIL: web-shell did not become ready in ${TIMEOUT}s"
    exit 1
fi

sleep 3

# Use web-shell container for curl tests (it has curl installed, and is on the same network)

# Test: OpenResty requires auth (401 without credentials)
echo "  Checking auth enforcement..."
status=$(docker compose -f "$COMPOSE_FILE" exec -T web-shell curl -s -o /dev/null -w "%{http_code}" http://openresty:8080/ 2>/dev/null)
if [ "$status" = "401" ]; then
    echo "  OK Auth required (HTTP 401)"
else
    echo "  FAIL: Expected 401, got HTTP $status"
    exit 1
fi

# Test: OpenResty serves ttyd with valid credentials
echo "  Checking authenticated access..."
status=$(docker compose -f "$COMPOSE_FILE" exec -T web-shell curl -s -o /dev/null -w "%{http_code}" -u admin:admin_change_me http://openresty:8080/ 2>/dev/null)
if [ "$status" = "200" ]; then
    echo "  OK Authenticated access works (HTTP 200)"
else
    echo "  FAIL: Authenticated request returned HTTP $status"
    exit 1
fi

# Test: ttyd content present
echo "  Checking ttyd content..."
response=$(docker compose -f "$COMPOSE_FILE" exec -T web-shell curl -fsS -u admin:admin_change_me http://openresty:8080/ 2>/dev/null || echo "")
if echo "$response" | grep -qi "ttyd\|terminal"; then
    echo "  OK ttyd interface served through proxy"
else
    echo "  WARN: ttyd keyword not found (may use different branding)"
fi

# Test: OpenResty reachable on its PUBLISHED host port — guards the compose
# `ports:` mapping (a broken host mapping is invisible to the internal checks).
# openresty enforces basic auth here, so authenticate and expect a 2xx.
echo "  Checking OpenResty on its published host port..."
host_addr=$(docker compose -f "$COMPOSE_FILE" port openresty 8080 2>/dev/null || true)
if [ -z "$host_addr" ]; then
    echo "  FAIL: container port 8080 is not published (check the ports: mapping)"
    exit 1
fi
# `docker compose port` may print a wildcard host (0.0.0.0 / [::]); curl needs
# a routable loopback address.
host_addr="${host_addr/#0.0.0.0:/127.0.0.1:}"
host_addr="${host_addr/#\[::\]:/[::1]:}"
status=$(curl -sS -o /dev/null -w '%{http_code}' -u admin:admin_change_me "http://${host_addr}/" 2>/dev/null || true)
if echo "$status" | grep -qE '^[23][0-9][0-9]$'; then
    echo "  OK OpenResty serving on the published port (HTTP $status)"
else
    echo "  FAIL: OpenResty did not return 2xx/3xx on the published port (got: ${status:-no response})"
    exit 1
fi

echo "  All Web Terminal Stack tests passed"
