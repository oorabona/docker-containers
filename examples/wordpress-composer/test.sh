#!/bin/bash
# Integration test for WordPress Composer stack
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/docker-compose.yaml"
TIMEOUT=120

# wp-cli runs from /var/www where wp-cli.yml points to public/wp
wp_exec() {
    docker compose -f "$COMPOSE_FILE" exec -T wordpress wp "$@" 2>/dev/null
}

cleanup() {
    echo "  Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo "  Testing WordPress Composer Stack..."

# Build and start (Composer resolves deps during docker build)
echo "  Building image and starting services..."
docker compose -f "$COMPOSE_FILE" up -d --build 2>/dev/null

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

# Test: Composer directory layout
echo "  Checking Composer directory layout..."
if docker compose -f "$COMPOSE_FILE" exec -T wordpress \
    test -d /var/www/public/wp/wp-admin; then
    echo "  OK WordPress core in public/wp/ (roots/wordpress)"
else
    echo "  FAIL: Composer layout not found"
    exit 1
fi

# Test: Vendor autoloader present
echo "  Checking Composer autoloader..."
if docker compose -f "$COMPOSE_FILE" exec -T wordpress \
    test -f /var/www/vendor/autoload.php; then
    echo "  OK Composer autoloader present"
else
    echo "  FAIL: vendor/autoload.php not found"
    exit 1
fi

# Test: Theme installed via Composer
echo "  Checking Composer-managed theme..."
if docker compose -f "$COMPOSE_FILE" exec -T wordpress \
    test -d /var/www/public/wp-content/themes/twentytwentyfive; then
    echo "  OK Theme installed via Composer (twentytwentyfive)"
else
    echo "  FAIL: Composer-managed theme not found"
    exit 1
fi

# Test: Security hardening
echo "  Checking security hardening..."
if wp_exec config get DISALLOW_FILE_MODS | grep -q "1"; then
    echo "  OK DISALLOW_FILE_MODS is active"
else
    echo "  FAIL: DISALLOW_FILE_MODS not set"
    exit 1
fi

# Test: Database connectivity
echo "  Checking database connectivity..."
if wp_exec db check > /dev/null 2>&1; then
    echo "  OK Database connection successful"
else
    echo "  FAIL: Cannot connect to database"
    exit 1
fi

# Test: Install WordPress via wp-cli
echo "  Installing WordPress..."
wp_exec core install \
    --url="http://localhost:8080" \
    --title="Composer WordPress" \
    --admin_user=admin \
    --admin_password=test_pass_123 \
    --admin_email=admin@example.com \
    --skip-email

# Test: WordPress installed
echo "  Checking installation..."
if wp_exec core is-installed; then
    echo "  OK WordPress installed via Composer layout"
else
    echo "  FAIL: WordPress not installed"
    exit 1
fi

# Test: Site title
echo "  Checking site configuration..."
if wp_exec option get blogname | grep -q "Composer WordPress"; then
    echo "  OK Site title configured correctly"
else
    echo "  FAIL: Site title does not match"
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

echo "  All WordPress Composer Stack tests passed"
