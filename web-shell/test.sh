#!/bin/bash
# E2E test for the web-shell container.
#
# Uses the repository's test harness so the exit code is the verdict. This suite
# was already the strictest of the unrun ones — five hard checks and no
# warnings — so the change is the summary carrying them, and every check being
# reported rather than the run stopping at the first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-web-shell}"

th_init --name "Web Shell E2E" --report "${REPORT_FORMAT:-table}"

th_group "Terminal service"

version=$(docker exec "$CONTAINER_NAME" ttyd --version 2>/dev/null | head -1)
th_assert_contains "ttyd reports its version" "$version" "ttyd"

# The token endpoint is what a browser fetches before opening the socket, so it
# proves the service is serving rather than merely running.
#
# Matched on shape, not on the word: `contains "token"` would also accept an
# error page that happens to mention it. Not on the value either — with no
# credential configured ttyd answers {"token": ""}, and a deployment that sets one
# would answer differently without being broken.
token=$(docker exec "$CONTAINER_NAME" curl -fsS http://localhost:7681/token 2>/dev/null | tr -d '[:space:]')
th_assert_matches "the token endpoint answers JSON on :7681" "$token" '^\{"token":'

th_group "Shell environment"

# The image names its unprivileged shell user in the environment; a terminal
# whose user does not exist opens onto nothing.
shell_user=$(docker exec "$CONTAINER_NAME" printenv SHELL_USER 2>/dev/null)
th_assert_not_empty "SHELL_USER is set in the image" "$shell_user"

if [ -n "$shell_user" ] && docker exec "$CONTAINER_NAME" id "$shell_user" >/dev/null 2>&1; then
    th_pass "the shell user '$shell_user' exists"
else
    th_fail "the shell user exists" "id '${shell_user:-<unset>}' failed"
fi

th_group "Tools"

for tool in bash git curl jq htop; do
    if docker exec "$CONTAINER_NAME" which "$tool" >/dev/null 2>&1; then
        th_pass "$tool is on PATH"
    else
        th_fail "$tool is on PATH" "which $tool failed"
    fi
done

th_summary
