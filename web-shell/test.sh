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
# Parsed, not pattern-matched: `contains "token"` would accept an error page that
# happens to mention it, and a `^\{"token":` prefix would accept `{"token":garbage`
# or a body truncated at that exact point — which is what a curl partial transfer
# produces. Parsing also catches the failed transfer that a discarded exit status
# would otherwise let through.
#
# The value is deliberately not asserted: with no credential configured ttyd
# answers {"token": ""}, and a deployment that sets one answers differently
# without being broken. The type is the contract.
token=$(docker exec "$CONTAINER_NAME" curl -fsS http://localhost:7681/token 2>/dev/null)
if printf '%s' "$token" | jq -e 'has("token") and (.token | type == "string")' >/dev/null 2>&1; then
    th_pass "the token endpoint answers a JSON object with a string token"
else
    # The body is described, never echoed: on a deployment that does configure a
    # credential, a malformed response could carry a live token straight into the
    # CI log. Length and parse status are enough to tell the failures apart.
    th_fail "the token endpoint answers a JSON object with a string token" \
        "response of ${#token} bytes did not parse as {\"token\": <string>}"
fi

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
    # `command -v` is a POSIX shell builtin; `which` is a separate package the
    # rocky variant does not ship, so testing with it failed every tool there.
    if docker exec "$CONTAINER_NAME" sh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"; then
        th_pass "$tool is on PATH"
    else
        th_fail "$tool is on PATH" "command -v $tool found nothing"
    fi
done

th_summary
