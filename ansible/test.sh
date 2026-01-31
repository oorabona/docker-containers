#!/bin/bash
# E2E test for ansible container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-ansible}"

echo "  Testing Ansible..."

# Test ansible version
echo "  Checking Ansible version..."
docker exec "$CONTAINER_NAME" ansible --version | head -1

# Test ansible-playbook exists
echo "  Checking ansible-playbook..."
if docker exec "$CONTAINER_NAME" ansible-playbook --version &>/dev/null; then
    echo "  ✅ ansible-playbook available"
else
    echo "  ❌ ansible-playbook not found"
    exit 1
fi

# Test basic module execution
echo "  Testing ping module..."
result=$(docker exec "$CONTAINER_NAME" ansible localhost -m ping -c local 2>/dev/null | grep -c SUCCESS)
if [ "$result" -ge 1 ]; then
    echo "  ✅ Ansible ping module works"
else
    echo "  ❌ Ansible ping module failed"
    exit 1
fi

echo "  ✅ All Ansible tests passed"
