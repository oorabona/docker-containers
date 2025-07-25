#!/bin/bash

echo "🧪 Testing GitHub Actions condition logic..."
echo ""

# Simulate what detect-containers outputs based on your logs
containers='["debian", "wordpress", "php", "sslh", "elasticsearch-conf", "ansible", "es-kopf", "openresty", "openvpn", "postgres", "logstash", "terraform"]'

echo "📋 Simulated containers output:"
echo "$containers"
echo ""

# Test the condition used in auto-build.yaml
echo "🔍 Testing fromJson().length condition:"
length=$(echo "$containers" | jq 'length')
echo "Length: $length"

if [ "$length" -gt 0 ]; then
    echo "✅ Condition would PASS - job should run"
else
    echo "❌ Condition would FAIL - job would be skipped"
fi

echo ""
echo "🔍 Testing if the JSON is valid:"
if echo "$containers" | jq . >/dev/null 2>&1; then
    echo "✅ JSON is valid"
else
    echo "❌ JSON is invalid - this could be the problem!"
fi

echo ""
echo "🔍 Let's check what the actual action might be outputting..."
echo "Based on your logs, detect-containers found these containers but may be outputting them incorrectly."
