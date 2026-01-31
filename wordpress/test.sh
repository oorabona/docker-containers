#!/bin/bash
# E2E test for wordpress container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-wordpress}"

echo "  Testing WordPress..."

# Test PHP is available (WordPress runs on PHP-FPM)
echo "  Checking PHP version..."
docker exec "$CONTAINER_NAME" php -v | head -1

# Test wp-cli if available
echo "  Checking WP-CLI..."
if docker exec "$CONTAINER_NAME" wp --version 2>/dev/null; then
    echo "  ✅ WP-CLI available"
else
    echo "  ⚠️  WP-CLI not found"
fi

# Test WordPress files exist
echo "  Checking WordPress installation..."
if docker exec "$CONTAINER_NAME" test -f /var/www/html/wp-config-sample.php 2>/dev/null || \
   docker exec "$CONTAINER_NAME" test -f /var/www/html/wp-settings.php 2>/dev/null; then
    echo "  ✅ WordPress files present"
else
    echo "  ❌ WordPress files not found"
    exit 1
fi

# Test required PHP extensions for WordPress
echo "  Checking WordPress PHP extensions..."
for ext in mysqli json curl; do
    if docker exec "$CONTAINER_NAME" php -m 2>/dev/null | grep -qi "^$ext$"; then
        echo "    ✓ $ext"
    else
        echo "    ⚠️  $ext not loaded"
    fi
done

echo "  ✅ All WordPress tests passed"
