#!/bin/bash
# Integration test for PHP + PostgreSQL + OpenResty stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=60

cleanup() {
    echo "  Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing PHP App Stack..."

# Start the stack
echo "  Starting services..."
docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null

# Wait for PHP-FPM to be healthy
echo "  Waiting for PHP-FPM to be ready..."
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    if docker compose -f "$COMPOSE_FILE" exec -T php php -r 'echo "ok";' 2>/dev/null | grep -q "ok"; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $TIMEOUT ]; then
    echo "  FAIL: PHP-FPM did not become ready in ${TIMEOUT}s"
    exit 1
fi

sleep 5

# Test: OpenResty responds with PHP content (use PHP curl)
echo "  Checking OpenResty -> PHP-FPM..."
response=$(docker compose -f "$COMPOSE_FILE" exec -T php php -r '
    $ch = curl_init("http://openresty:8080/");
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    echo curl_exec($ch);
    curl_close($ch);
' 2>/dev/null || echo "")
if echo "$response" | grep -q "PHP App Stack"; then
    echo "  OK OpenResty serving PHP content"
else
    echo "  FAIL: OpenResty did not return PHP content"
    exit 1
fi

# Test: PHP connects to PostgreSQL
echo "  Checking PHP -> PostgreSQL..."
if echo "$response" | grep -q "connected"; then
    echo "  OK PHP connected to PostgreSQL"
else
    echo "  FAIL: PHP cannot connect to PostgreSQL"
    exit 1
fi

# Test: Sample data present
echo "  Checking sample data..."
if echo "$response" | grep -q "admin@example.com"; then
    echo "  OK Sample data loaded"
else
    echo "  FAIL: Sample data not found"
    exit 1
fi

# Test: OpenResty reachable on its PUBLISHED host port — guards the compose
# `ports:` mapping (a broken host mapping is invisible to the internal checks)
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
status=$(curl -sS -o /dev/null -w '%{http_code}' "http://${host_addr}/" 2>/dev/null || true)
if echo "$status" | grep -qE '^[23][0-9][0-9]$'; then
    echo "  OK OpenResty serving on the published port (HTTP $status)"
else
    echo "  FAIL: OpenResty did not return 2xx/3xx on the published port (got: ${status:-no response})"
    exit 1
fi

echo "  All PHP App Stack tests passed"
