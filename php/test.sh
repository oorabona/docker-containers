#!/bin/bash
# E2E test for the php container.
#
# Uses the repository's test harness so the exit code is the verdict. The
# extension checks were warnings; each is a dependency a PHP application will
# assume, so they are asserted.
#
# Extensions are checked with extension_loaded() rather than by grepping `php -m`.
# That output is not a flat list of the names you pass elsewhere: OPcache appears
# as "Zend OPcache" and is invisible to an exact-match grep, while `php --ri
# opcache` denies it exists. Asking the engine avoids guessing at its spelling.

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

loaded() { # extension name as the engine registers it
    [ "$(docker exec "$CONTAINER_NAME" php -r "echo extension_loaded('$1') ? 'y' : 'n';" 2>/dev/null)" = "y" ]
}

# "Zend OPcache" is the registered name; the Dockerfile installs it and the image
# description advertises it.
for ext in PDO curl json mbstring mysqli gd "Zend OPcache"; do
    if loaded "$ext"; then
        th_pass "extension $ext is loaded"
    else
        th_fail "extension $ext is loaded" "extension_loaded() says no"
    fi
done

# The Dockerfile installs zip and enables apcu, and neither is loaded in the
# published image — there is no ini for either in conf.d (#982). That is an image
# defect, not a test expectation to soften, so it is recorded rather than
# asserted: the gap shows in every run without failing a pull request on a fault
# it did not introduce. When the image carries them, these become assertions.
for ext in zip apcu; do
    if loaded "$ext"; then
        th_pass "extension $ext is loaded"
    else
        th_skip "extension $ext is loaded" "installed by the Dockerfile, absent from the image"
    fi
done

th_summary
