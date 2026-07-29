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

th_capture "/etc/debian_version identifies the release" \
    docker exec "$CONTAINER_NAME" cat /etc/debian_version &&
    th_assert_not_empty "/etc/debian_version identifies the release" "$TH_OUTPUT"

th_group "Environment"

# Was a warning reading "may be normal for minimal image". It holds on the
# published image, and a base image that loses its UTF-8 locale breaks every
# consumer assuming one, so it is asserted.
th_assert_cmd_contains "a UTF-8 locale is configured" "UTF-8" \
    docker exec "$CONTAINER_NAME" locale

# Also a warning. The image ships a default unprivileged user; if it stops, every
# downstream USER directive naming it breaks.
if docker exec "$CONTAINER_NAME" id debian >/dev/null 2>&1; then
    th_pass "the default 'debian' user exists"
else
    th_fail "the default 'debian' user exists" "id debian failed"
fi

th_group "Core tools"

for tool in bash cat ls; do
    # `command -v` is a POSIX shell builtin; `which` is a separate package that
    # RHEL-family minimal images do not ship.
    if docker exec "$CONTAINER_NAME" sh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"; then
        th_pass "$tool is on PATH"
    else
        th_fail "$tool is on PATH" "command -v $tool found nothing"
    fi
done

th_summary
