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

# Report the version the image carries. This does not compare it to the tag —
# rolling package repositories plus version_retention make installed-equals-
# declared false by construction here — but nginx failing to answer at all is a
# broken image, not a line to skip.
echo "  Checking OpenResty version..."
if ! docker exec "$CONTAINER_NAME" nginx -v 2>&1; then
    echo "  ❌ nginx could not report its version"
    exit 1
fi

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

# Lua is what makes this OpenResty rather than nginx, so its absence is a
# failure and not something to skip past. Treating it as optional let the suite
# print "All OpenResty tests passed" for an image with no `resty` at all.
echo "  Testing Lua module..."
if ! docker exec "$CONTAINER_NAME" which resty >/dev/null 2>&1; then
    echo "  ❌ resty is not in PATH — the image does not ship the Lua CLI it advertises"
    exit 1
fi
lua_test=$(docker exec "$CONTAINER_NAME" resty -e 'print(1+1)' 2>/dev/null) || lua_test=""
if [ "$lua_test" != "2" ]; then
    echo "  ❌ resty ran but did not evaluate Lua: expected '2', got '$lua_test'"
    exit 1
fi
echo "  ✅ Lua/resty working"

echo "  ✅ All OpenResty tests passed"
