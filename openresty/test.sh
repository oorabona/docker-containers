#!/bin/bash
# E2E test for openresty container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-openresty}"

echo "  Testing OpenResty/Nginx configuration..."

# Test nginx config syntax
if ! docker exec "$CONTAINER_NAME" nginx -t 2>&1; then
    echo "  ❌ Nginx config test failed"
    exit 1
fi
echo "  ✅ Nginx config syntax OK"

# Test OpenResty version
echo "  Checking OpenResty version..."
docker exec "$CONTAINER_NAME" nginx -v 2>&1 || true

# Test HTTP response on the non-privileged port the non-root default server
# listens on. Uses busybox wget (curl is not in the runtime image) and asserts
# a successful response, so this actually protects the :8080 port contract.
echo "  Testing HTTP endpoint on :8080..."
if docker exec "$CONTAINER_NAME" wget -q -O /dev/null "http://localhost:8080/"; then
    echo "  ✅ HTTP endpoint responding on :8080"
else
    echo "  ❌ HTTP endpoint did not respond on :8080"
    exit 1
fi

# Test Lua module availability (optional)
echo "  Testing Lua module..."
if docker exec "$CONTAINER_NAME" which resty &>/dev/null; then
    lua_test=$(docker exec "$CONTAINER_NAME" resty -e 'print(1+1)' 2>/dev/null) || lua_test=""
    if [ "$lua_test" = "2" ]; then
        echo "  ✅ Lua/resty working"
    else
        echo "  ⚠️  Lua test returned: '$lua_test'"
    fi
else
    echo "  (resty not in PATH, skipping Lua test)"
fi

echo "  ✅ All OpenResty tests passed"
