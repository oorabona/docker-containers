#!/bin/bash
# E2E test for the wordpress container.
#
# Uses the repository's test harness so the exit code is the verdict. WP-CLI and
# the PHP extensions were warnings; all of them hold on the published image, and
# WordPress cannot talk to its database without mysqli, so they are asserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-wordpress}"

th_init --name "WordPress E2E" --report "${REPORT_FORMAT:-table}"

th_group "Interpreter"

# Was printed and never read.
version=$(docker exec "$CONTAINER_NAME" php -v 2>/dev/null | head -1)
th_assert_contains "php reports its version" "$version" "PHP"

th_group "WordPress"

# The core files are what makes this a WordPress image rather than a PHP one.
if docker exec "$CONTAINER_NAME" test -f /var/www/html/wp-settings.php >/dev/null 2>&1; then
    th_pass "the WordPress core files are in place"
else
    th_fail "the WordPress core files are in place" "/var/www/html/wp-settings.php is absent"
fi

wp=$(docker exec "$CONTAINER_NAME" wp --version --allow-root 2>/dev/null | head -1)
th_assert_contains "wp-cli is installed" "$wp" "WP-CLI"

th_group "Extensions"

# mysqli is how WordPress reaches its database; without it the image cannot serve
# a site at all. It was reported as a warning.
modules=$(docker exec "$CONTAINER_NAME" php -m 2>/dev/null)
for ext in mysqli json curl; do
    if printf '%s\n' "$modules" | grep -qix "$ext"; then
        th_pass "extension $ext is loaded"
    else
        th_fail "extension $ext is loaded" "not present in php -m"
    fi
done

th_summary
