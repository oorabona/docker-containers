#!/bin/bash
# E2E test for jekyll container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-jekyll}"

echo "  Testing Jekyll..."

# Test Ruby version
echo "  Checking Ruby version..."
docker exec "$CONTAINER_NAME" ruby --version | head -1

# Test Jekyll version
echo "  Checking Jekyll version..."
if docker exec "$CONTAINER_NAME" jekyll --version 2>/dev/null; then
    echo "  ✅ Jekyll available"
else
    echo "  ❌ Jekyll not found"
    exit 1
fi

# Test Bundler
echo "  Checking Bundler..."
if docker exec "$CONTAINER_NAME" bundle --version &>/dev/null; then
    echo "  ✅ Bundler available"
else
    echo "  ⚠️  Bundler not found"
fi

echo "  ✅ All Jekyll tests passed"
