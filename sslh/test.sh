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
# shellcheck source=../test-harness/image-identity.sh
source "${SCRIPT_DIR}/../test-harness/image-identity.sh"

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

# The harness resolves the reference to one declared cell before this suite
# starts.  Compare the exact binary token: a substring lets 2.2.4 pass 12.2.40
# and lets 3.1 pass 2.3.1.  Hyphenated prereleases remain one token.
if (( version_read )); then
    if [[ "$banner" =~ ^sslh-ev[[:space:]]+([^[:space:]]+) ]]; then
        e2e_assert_reported_component_version "${BASH_REMATCH[1]}"
    else
        th_fail "sslh-ev reports a parseable version token" "first line: '$banner'"
    fi
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
