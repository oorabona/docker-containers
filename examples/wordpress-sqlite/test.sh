#!/bin/bash
# Integration test for WordPress + SQLite + OpenResty stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=90

# Helper: run wp-cli in the WordPress container (stderr suppressed for PHP deprecation noise)
wp_exec() {
    docker compose -f "$COMPOSE_FILE" exec -T wordpress wp "$@" 2>/dev/null
}

cleanup() {
    echo "  Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing WordPress SQLite Stack..."

# Start the stack (auto-install via WP_AUTO_INSTALL=true + WP_DB_TYPE=sqlite)
echo "  Starting services..."
docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null

# Wait for WordPress to be ready
echo "  Waiting for WordPress to be ready..."
elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    if wp_exec core version | grep -qE '^[0-9]'; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $TIMEOUT ]; then
    echo "  FAIL: WordPress did not become ready in ${TIMEOUT}s"
    docker compose -f "$COMPOSE_FILE" logs 2>/dev/null || true
    exit 1
fi

# Wait for entrypoint auto-install
sleep 10

# Test: wp-config.php generated with SQLite settings
echo "  Checking wp-config.php generation..."
if wp_exec config path | grep -q "wp-config.php"; then
    echo "  OK wp-config.php generated"
else
    echo "  FAIL: wp-config.php not found"
    exit 1
fi

# Test: SQLite drop-in is active
echo "  Checking SQLite drop-in..."
if wp_exec eval 'echo defined("DB_DIR") ? "sqlite-active" : "no-sqlite";' | grep -q "sqlite-active"; then
    echo "  OK SQLite drop-in active"
else
    echo "  FAIL: SQLite drop-in not active"
    exit 1
fi

# Test: Security constants
echo "  Checking security hardening..."
if wp_exec config get DISALLOW_FILE_MODS | grep -q "1"; then
    echo "  OK DISALLOW_FILE_MODS is active"
else
    echo "  FAIL: DISALLOW_FILE_MODS not set"
    exit 1
fi

# Test: WordPress auto-installed
echo "  Checking auto-install..."
if wp_exec core is-installed; then
    echo "  OK WordPress auto-installed with SQLite"
else
    echo "  FAIL: WordPress not installed"
    exit 1
fi

# Test: Site title matches env var
echo "  Checking site configuration..."
if wp_exec option get blogname | grep -q "My WordPress Site"; then
    echo "  OK Site title configured correctly"
else
    echo "  FAIL: Site title does not match WP_SITE_TITLE"
    exit 1
fi

# Test: Database is actually SQLite (no MySQL dependency)
echo "  Checking SQLite database file..."
if docker compose -f "$COMPOSE_FILE" exec -T wordpress \
    test -f wp-content/database/.ht.sqlite; then
    echo "  OK SQLite database file exists"
else
    echo "  FAIL: SQLite database file not found"
    exit 1
fi

# Test: OpenResty reachable on its PUBLISHED host port — guards both the
# non-root port migration and the compose `ports:` mapping (catches a wrong
# listen port, failed startup, broken FastCGI proxy, or a bad host mapping)
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

echo "  All WordPress SQLite Stack tests passed"
