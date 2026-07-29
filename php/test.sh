#!/bin/bash
# E2E test for the php container.
#
# Uses the repository's test harness so the exit code is the verdict. The
# extension checks were warnings; every one of them holds on the published image
# and each is a dependency a PHP application will assume, so they are asserted.
# The list is what was measured — pdo_mysql and opcache are not in the image and
# are deliberately not claimed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-php}"

th_init --name "PHP-FPM E2E" --report "${REPORT_FORMAT:-table}"

th_group "Interpreter"

# Was printed and never read.
version=$(docker exec "$CONTAINER_NAME" php -v 2>/dev/null | head -1)
th_assert_contains "php reports its version" "$version" "PHP"

result=$(docker exec "$CONTAINER_NAME" php -r "echo 1 + 1;" 2>/dev/null | tr -d '[:space:]')
th_assert_eq "php evaluates code" "$result" "2"

th_group "Service"

# The process name varies by build (php-fpm, php-fpm8, php-fpm81…), so match the
# prefix rather than an exact name.
if docker exec "$CONTAINER_NAME" pgrep -f "php-fpm" >/dev/null 2>&1; then
    th_pass "a php-fpm master process is running"
else
    th_fail "a php-fpm master process is running" "pgrep -f php-fpm found nothing"
fi

th_group "Extensions"

modules=$(docker exec "$CONTAINER_NAME" php -m 2>/dev/null)
for ext in pdo curl json mbstring mysqli gd; do
    if printf '%s\n' "$modules" | grep -qix "$ext"; then
        th_pass "extension $ext is loaded"
    else
        th_fail "extension $ext is loaded" "not present in php -m"
    fi
done

th_summary
