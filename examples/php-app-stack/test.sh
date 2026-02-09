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
    $ch = curl_init("http://openresty:80/");
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

echo "  All PHP App Stack tests passed"
