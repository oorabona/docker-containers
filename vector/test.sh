#!/bin/bash
# E2E test for the vector container.
#
# Uses the repository's test harness so the exit code is the verdict. This suite
# already had three hard checks; what it lacked was a summary that carried them —
# it printed "All Vector tests passed" whatever happened, and only its own exits
# could contradict that.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-vector}"

th_init --name "Vector E2E" --report "${REPORT_FORMAT:-table}"

th_group "Binary"

version=$(docker exec "$CONTAINER_NAME" vector --version 2>/dev/null | head -1)
th_assert_contains "vector reports its version" "$version" "vector"

th_group "Runtime"

if docker exec "$CONTAINER_NAME" pgrep -f "vector" >/dev/null 2>&1; then
    th_pass "a vector process is running"
else
    th_fail "a vector process is running" "pgrep -f vector found nothing"
fi

# The API is what a consumer polls to know the pipeline is alive, so it is the
# check that matters most here. Matched exactly rather than by substring: the
# obvious `contains "ok"` also accepts a body reading "not ok".
health=$(docker exec "$CONTAINER_NAME" wget -qO- http://localhost:8686/health 2>/dev/null | tr -d '[:space:]')
th_assert_eq "the API health endpoint reports ok on :8686" "$health" '{"ok":true}'

th_summary
