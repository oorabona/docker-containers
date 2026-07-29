#!/bin/bash
# E2E test for the openresty container.
#
# Uses the repository's test harness so the exit code is the verdict. The Lua
# check was optional twice over — skipped if resty was absent, a warning if it
# returned the wrong answer. Both hold on the published image, and Lua is what
# distinguishes OpenResty from nginx, so both are asserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-openresty}"

th_init --name "OpenResty E2E" --report "${REPORT_FORMAT:-table}"

th_group "Configuration"

if docker exec "$CONTAINER_NAME" nginx -t >/dev/null 2>&1; then
    th_pass "the shipped nginx configuration is valid"
else
    th_fail "the shipped nginx configuration is valid" \
        "$(docker exec "$CONTAINER_NAME" nginx -t 2>&1 | tail -2)"
fi

# Was printed and discarded with `|| true`. nginx writes its banner to stderr, so
# that stream is the one to read — and the line is selected rather than taken by
# position, since anything else a runtime chooses to print there would otherwise
# be mistaken for it.
banner=$(docker exec "$CONTAINER_NAME" nginx -v 2>&1 | grep -i 'nginx version' | head -1)
th_assert_contains "nginx reports an openresty build" "$banner" "openresty"

th_group "HTTP"

# The non-root default server listens on 8080; curl is not in the runtime image,
# so this uses the busybox wget that is.
if docker exec "$CONTAINER_NAME" wget -q -O /dev/null "http://localhost:8080/" >/dev/null 2>&1; then
    th_pass "the default server answers on :8080"
else
    th_fail "the default server answers on :8080" "wget returned non-zero"
fi

th_group "Lua"

# What makes this OpenResty rather than nginx.
lua=$(docker exec "$CONTAINER_NAME" resty -e 'print(1+1)' 2>/dev/null | tr -d '[:space:]')
th_assert_eq "resty evaluates Lua" "$lua" "2"

th_summary
