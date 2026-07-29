#!/bin/bash
# E2E test for the sslh container.
#
# Uses the repository's test harness so the exit code is the verdict.
#
# The image is FROM scratch: no shell, no pgrep, no coreutils. Every check has to
# go through a binary the image actually ships — sslh-ev itself, and the busybox
# applet the container's own HEALTHCHECK uses.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../test-harness/test-harness.sh
source "${SCRIPT_DIR}/../test-harness/test-harness.sh"

CONTAINER_NAME="${CONTAINER_NAME:-e2e-sslh}"

th_init --name "SSLH E2E" --report "${REPORT_FORMAT:-table}"

th_group "Binary"

# The old version check tried sslh-ev, fell back to a plain `sslh`, and shrugged
# if both failed. Only sslh-ev is in the image — `sslh` is not a file there — so
# the fallback was dead and the shrug hid a real failure.
version=$(docker exec "$CONTAINER_NAME" sslh-ev --version 2>&1 | head -1)
th_assert_contains "sslh-ev reports its version" "$version" "sslh-ev"

# The tag carries the upstream version, so the binary disagreeing with it means
# the image was assembled from something other than what it claims.
expected="${SSLH_EXPECTED_VERSION:-}"
if [ -z "$expected" ] && [ -n "${E2E_IMAGE:-}" ]; then
    # ghcr.io/owner/sslh:v2.3.1-alpine → 2.3.1
    expected="${E2E_IMAGE##*:}"
    expected="${expected%%-*}"
    expected="${expected#v}"
fi
# Only a tag that carries a version can be compared against one. A moving tag
# such as `latest` says nothing about the binary, and asserting on it would fail
# for a reason that has nothing to do with the image.
if [[ "$expected" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    th_assert_contains "the binary version matches the image tag ($expected)" "$version" "$expected"
else
    th_skip "the binary version matches the image tag" "tag '${expected:-none}' carries no version"
fi

th_group "Multiplexer"

# FROM scratch leaves nothing to inspect a process with, so liveness is proven by
# connecting to the listen port with the busybox nc applet that ships in the
# image — the same tool the HEALTHCHECK uses.
if docker exec "$CONTAINER_NAME" /bin/busybox nc -z 127.0.0.1 443 >/dev/null 2>&1; then
    th_pass "sslh accepts connections on 443"
else
    th_fail "sslh accepts connections on 443" "busybox nc -z 127.0.0.1 443 failed"
fi

th_summary
