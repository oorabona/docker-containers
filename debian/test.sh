#!/bin/bash
# E2E test for the debian base image.
#
# Uses the repository's test harness so the exit code is the verdict. Two checks
# that were warnings are now assertions: each was measured against the published
# image and holds, so each is a regression lock rather than a hope.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-debian}"

th_init --name "Debian base image E2E" --report "${REPORT_FORMAT:-table}"

th_group "Release"

release=$(docker exec "$CONTAINER_NAME" cat /etc/debian_version 2>/dev/null)
th_assert_not_empty "/etc/debian_version identifies the release" "$release"

th_group "Environment"

# Was a warning reading "may be normal for minimal image". It holds on the
# published image, and a base image that loses its UTF-8 locale breaks every
# consumer assuming one, so it is asserted.
locale_out=$(docker exec "$CONTAINER_NAME" locale 2>/dev/null)
th_assert_contains "a UTF-8 locale is configured" "$locale_out" "UTF-8"

# Also a warning. The image ships a default unprivileged user; if it stops, every
# downstream USER directive naming it breaks.
if docker exec "$CONTAINER_NAME" id debian >/dev/null 2>&1; then
    th_pass "the default 'debian' user exists"
else
    th_fail "the default 'debian' user exists" "id debian failed"
fi

th_group "Core tools"

for tool in bash cat ls; do
    if docker exec "$CONTAINER_NAME" which "$tool" >/dev/null 2>&1; then
        th_pass "$tool is on PATH"
    else
        th_fail "$tool is on PATH" "which $tool failed"
    fi
done

th_summary
