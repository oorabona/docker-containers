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

th_assert_cmd_contains "ttyd reports its version" "ttyd" \
    docker exec "$CONTAINER_NAME" ttyd --version

# The token endpoint is what a browser fetches before opening the socket, so it
# proves the service is serving rather than merely running.
#
# Parsed, not pattern-matched: `contains "token"` would accept an error page that
# happens to mention it, and a `^\{"token":` prefix would accept `{"token":garbage`
# or a body truncated at that exact point — which is what a curl partial transfer
# produces. Parsing also catches the failed transfer that a discarded exit status
# would otherwise let through.
#
# The value is deliberately not asserted, only its type: with no credential
# configured ttyd answers an empty token, and that is the configuration the e2e
# runs — the harness starts the image with no TTYD_CREDENTIAL, no TLS and the
# default port. This probe is written for exactly that shape and is not valid
# against an authenticated, TLS or alternate-port deployment; the image's own
# healthcheck is what handles those.
token_check="the token endpoint answers a JSON object with a string token"
if th_capture "$token_check" \
        docker exec "$CONTAINER_NAME" curl -fsS --connect-timeout 5 --max-time 15 \
        http://localhost:7681/token; then
    if printf '%s' "$TH_OUTPUT" | jq -e 'has("token") and (.token | type == "string")' \
            >/dev/null 2>&1; then
        th_pass "$token_check"
    else
        # The body is described, never echoed: on a deployment that does configure
        # a credential, a malformed response could carry a live token straight
        # into the CI log. Length is enough to tell the failures apart.
        th_fail "$token_check" \
            "response of ${#TH_OUTPUT} bytes did not parse as {\"token\": <string>}"
    fi
fi

th_group "Shell environment"

# The image names its unprivileged shell user in the environment; a terminal
# whose user does not exist opens onto nothing.
shell_user=""
if th_capture "SHELL_USER is set in the image" \
        docker exec "$CONTAINER_NAME" printenv SHELL_USER; then
    shell_user=$TH_OUTPUT
    th_assert_not_empty "SHELL_USER is set in the image" "$shell_user"
fi

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
