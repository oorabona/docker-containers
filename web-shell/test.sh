#!/bin/bash
# E2E test for web-shell container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-web-shell}"

echo "  Testing Web Shell..."

# Test ttyd binary exists and version
echo "  Checking ttyd version..."
if docker exec "$CONTAINER_NAME" ttyd --version 2>/dev/null; then
    echo "  ✅ ttyd binary found"
else
    echo "  ❌ ttyd binary not found"
    exit 1
fi

# Check ttyd is listening (web terminal)
echo "  Checking web terminal..."
if docker exec "$CONTAINER_NAME" curl -fsS http://localhost:7681/token 2>/dev/null | grep -q "token"; then
    echo "  ✅ Web terminal responding"
else
    echo "  ❌ Web terminal not responding"
    exit 1
fi

# Check common tools are installed
echo "  Checking installed tools..."
TOOLS="bash git curl jq htop"
for tool in $TOOLS; do
    if docker exec "$CONTAINER_NAME" which "$tool" &>/dev/null; then
        echo "    ✓ $tool"
    else
        echo "  ❌ Missing tool: $tool"
        exit 1
    fi
done

# Check shell user exists
echo "  Checking shell user..."
if docker exec "$CONTAINER_NAME" id debian &>/dev/null; then
    echo "  ✅ Shell user 'debian' exists"
else
    echo "  ❌ Shell user 'debian' not found"
    exit 1
fi

echo "  ✅ All Web Shell tests passed"
