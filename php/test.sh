#!/bin/bash
# E2E test for php container

set -uo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-e2e-php}"

echo "  Testing PHP-FPM..."

# Test PHP version
echo "  Checking PHP version..."
docker exec "$CONTAINER_NAME" php -v | head -1

# Test PHP-FPM is running (process name varies: php-fpm, php-fpm8, php-fpm81, etc.)
echo "  Checking PHP-FPM process..."
if docker exec "$CONTAINER_NAME" pgrep -f "php-fpm" &>/dev/null; then
    echo "  ✅ PHP-FPM process running"
else
    echo "  ❌ PHP-FPM not running"
    exit 1
fi

# Test basic PHP execution
echo "  Testing PHP execution..."
result=$(docker exec "$CONTAINER_NAME" php -r "echo 1 + 1;" 2>/dev/null)
if [ "$result" = "2" ]; then
    echo "  ✅ PHP execution OK"
else
    echo "  ❌ PHP execution failed"
    exit 1
fi

# Test common extensions
echo "  Checking extensions..."
for ext in pdo curl json mbstring; do
    if docker exec "$CONTAINER_NAME" php -m 2>/dev/null | grep -qi "^$ext$"; then
        echo "    ✓ $ext"
    else
        echo "    ⚠️  $ext not loaded"
    fi
done

echo "  ✅ All PHP tests passed"
