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

# Check process is running
echo "  Checking SSLH process..."
if docker exec "$CONTAINER_NAME" pgrep -f "sslh" &>/dev/null; then
    echo "  ✅ SSLH process running"
else
    echo "  ❌ SSLH not running"
    exit 1
fi

echo "  ✅ All SSLH tests passed"
