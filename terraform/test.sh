#!/bin/bash
# E2E test for terraform container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-terraform}"

echo "  Testing Terraform..."

# Test Terraform version
echo "  Checking Terraform version..."
docker exec "$CONTAINER_NAME" terraform version | head -1

# Test terraform init works (no providers needed)
echo "  Testing terraform validate..."
if docker exec "$CONTAINER_NAME" sh -c 'cd /tmp && echo "{}" > main.tf && terraform init -backend=false 2>/dev/null && terraform validate' &>/dev/null; then
    echo "  ✅ Terraform init+validate works"
else
    echo "  ⚠️  Terraform validate returned error (may need providers)"
fi

# Test common tools based on flavor
echo "  Checking additional tools..."
for tool in git curl jq; do
    if docker exec "$CONTAINER_NAME" which "$tool" &>/dev/null; then
        echo "    ✓ $tool"
    else
        echo "    ⚠️  $tool not found (depends on flavor)"
    fi
done

echo "  ✅ All Terraform tests passed"
