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
th_assert_cmd_contains "php reports its version" "PHP" \
    docker exec "$CONTAINER_NAME" php -v

th_capture "php evaluates code" docker exec "$CONTAINER_NAME" php -r "echo 1 + 1;" &&
    th_assert_eq "php evaluates code" "${TH_OUTPUT//[[:space:]]/}" "2"

th_group "Service"

# The process name varies by build (php-fpm, php-fpm8, php-fpm81…), so match the
# prefix rather than an exact name.
if docker exec "$CONTAINER_NAME" pgrep -f "php-fpm" >/dev/null 2>&1; then
    th_pass "a php-fpm master process is running"
else
    th_fail "a php-fpm master process is running" "pgrep -f php-fpm found nothing"
fi

th_group "Extensions"

# Every extension the image advertises, asserted. "Zend OPcache" is the name the
# engine registers, and it comes from the base image's static build rather than
# from an install step — which is exactly what made `zip` and `apcu` go missing
# for a while: asking to install OPcache anyway failed, and everything listed
# after it in the same command was skipped without a word.
#
# The probe asserts the command SUCCEEDED as well as what it printed. Printing
# the expected answer and exiting non-zero are independent: a wrapper that echoes
# `y` and then fails would otherwise pass every check here.
for ext in PDO curl json mbstring mysqli gd zip apcu "Zend OPcache"; do
    th_assert_cmd_contains "extension $ext is loaded" "loaded" \
        docker exec "$CONTAINER_NAME" php -r \
        "echo extension_loaded('$ext') ? 'loaded' : 'absent';"
done

th_summary
