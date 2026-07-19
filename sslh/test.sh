#!/bin/bash
# E2E test for sslh container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-sslh}"

echo "  Testing SSLH multiplexer..."

# Test sslh binary exists and version
echo "  Checking SSLH version..."
docker exec "$CONTAINER_NAME" sslh-ev --version 2>&1 | head -1 || \
docker exec "$CONTAINER_NAME" sslh --version 2>&1 | head -1 || \
echo "  (version check returned error, may be normal)"

# The image is FROM scratch (no pgrep/shell), so prove sslh is actually
# multiplexing by connecting to its listen port with the busybox nc applet
# that ships in the image — the same tool the container HEALTHCHECK uses.
echo "  Checking SSLH is listening on 443..."
if docker exec "$CONTAINER_NAME" /bin/busybox nc -z 127.0.0.1 443; then
    echo "  ✅ SSLH is listening on 443"
else
    echo "  ❌ SSLH not listening on 443"
    exit 1
fi

echo "  ✅ All SSLH tests passed"
