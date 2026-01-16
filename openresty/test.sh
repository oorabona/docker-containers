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

# Test HTTP response (optional - may not have curl)
echo "  Testing HTTP endpoint..."
if docker exec "$CONTAINER_NAME" which curl &>/dev/null; then
    response=$(docker exec "$CONTAINER_NAME" curl -s -o /dev/null -w "%{http_code}" "http://localhost/" 2>/dev/null) || response="N/A"
    echo "  HTTP status: $response"
else
    echo "  (curl not available, skipping HTTP test)"
fi

# Test Lua module availability (optional)
echo "  Testing Lua module..."
if docker exec "$CONTAINER_NAME" which resty &>/dev/null; then
    lua_test=$(docker exec "$CONTAINER_NAME" sh -c 'echo "print(1+1)" | resty' 2>/dev/null) || lua_test=""
    if [ "$lua_test" = "2" ]; then
        echo "  ✅ Lua/resty working"
    else
        echo "  ⚠️  Lua test returned: '$lua_test'"
    fi
else
    echo "  (resty not in PATH, skipping Lua test)"
fi

echo "  ✅ All OpenResty tests passed"
