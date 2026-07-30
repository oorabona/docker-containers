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

# Only sslh-ev is in the image — `sslh` is not a file there. The probe takes the
# command, so a binary that prints a plausible banner and then exits non-zero
# fails here instead of satisfying the text assertion. It writes the banner to
# stdout, so nothing needs merging: the probes discard stderr on purpose, and a
# diagnostic must not be able to pass an assertion about a version.
banner=""
version_read=0
if th_capture "sslh-ev reports its version" \
        docker exec "$CONTAINER_NAME" sslh-ev --version; then
    version_read=1
    # `sslh-ev 2.3.1`, then a line per compile-time option. Both checks read the
    # first line only, as the `head -1` this probe replaced did: what appears
    # further down says nothing about which binary answered.
    banner="${TH_OUTPUT%%$'\n'*}"
    th_assert_contains "sslh-ev reports its version" "$banner" "sslh-ev"
fi

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
#
# The comparison stays a substring match, deliberately: turning it into an exact
# one means deciding what an image reference's version IS, and a tag carries a
# flavour suffix, sometimes a prerelease hyphen and sometimes a digest, so every
# stricter rule rejects some legitimate build. Tightening it is #983's work, on
# every suite at once, not a side effect of this one. See #1002.
if [[ "$expected" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    if (( version_read )); then
        th_assert_contains "the binary version matches the image tag ($expected)" \
            "$banner" "$expected"
    else
        # Reported as a skip rather than dropped: a test that leaves the report
        # entirely is indistinguishable from one that was never written.
        th_skip "the binary version matches the image tag" "the version probe failed"
    fi
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
