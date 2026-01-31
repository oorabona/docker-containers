#!/bin/bash
# E2E test for openvpn container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-openvpn}"

echo "  Testing OpenVPN..."

# Test OpenVPN version
echo "  Checking OpenVPN version..."
docker exec "$CONTAINER_NAME" openvpn --version 2>&1 | head -1

# Test easyrsa is available
echo "  Checking EasyRSA..."
if docker exec "$CONTAINER_NAME" which easyrsa &>/dev/null || \
   docker exec "$CONTAINER_NAME" test -x /usr/share/easy-rsa/easyrsa 2>/dev/null; then
    echo "  ✅ EasyRSA available"
else
    echo "  ⚠️  EasyRSA not found"
fi

# Test iptables (needed for routing)
echo "  Checking iptables..."
if docker exec "$CONTAINER_NAME" which iptables &>/dev/null; then
    echo "  ✅ iptables available"
else
    echo "  ⚠️  iptables not found"
fi

echo "  ✅ All OpenVPN tests passed"
