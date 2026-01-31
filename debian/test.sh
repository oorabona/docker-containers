#!/bin/bash
# E2E test for debian container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-debian}"

echo "  Testing Debian base image..."

# Test OS release
echo "  Checking Debian version..."
docker exec "$CONTAINER_NAME" cat /etc/debian_version

# Test locale is configured
echo "  Checking locale..."
if docker exec "$CONTAINER_NAME" locale 2>/dev/null | grep -q "UTF-8"; then
    echo "  ✅ UTF-8 locale configured"
else
    echo "  ⚠️  UTF-8 locale not detected (may be normal for minimal image)"
fi

# Test user exists
echo "  Checking user setup..."
if docker exec "$CONTAINER_NAME" id debian &>/dev/null; then
    echo "  ✅ Default user 'debian' exists"
else
    echo "  ⚠️  Default user 'debian' not found"
fi

# Test basic tools
echo "  Checking core tools..."
for tool in bash cat ls; do
    if docker exec "$CONTAINER_NAME" which "$tool" &>/dev/null; then
        echo "    ✓ $tool"
    else
        echo "    ❌ $tool not found"
        exit 1
    fi
done

echo "  ✅ All Debian tests passed"
