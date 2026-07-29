#!/bin/bash
# E2E test for vector container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-vector}"

echo "  Testing Vector observability pipeline..."

# Test vector binary exists and version
echo "  Checking Vector version..."
if docker exec "$CONTAINER_NAME" vector --version 2>/dev/null; then
    echo "  ✅ Vector binary found"
else
    echo "  ❌ Vector binary not found"
    exit 1
fi

# Check Vector API is responding (health endpoint)
echo "  Checking Vector API health..."
if docker exec "$CONTAINER_NAME" wget -qO- http://localhost:8686/health 2>/dev/null | grep -q "ok"; then
    echo "  ✅ Vector API healthy"
else
    echo "  ❌ Vector API not responding"
    exit 1
fi

# Check process is running
echo "  Checking Vector process..."
if docker exec "$CONTAINER_NAME" pgrep -f "vector" &>/dev/null; then
    echo "  ✅ Vector process running"
else
    echo "  ❌ Vector not running"
    exit 1
fi

echo "  ✅ All Vector tests passed"
