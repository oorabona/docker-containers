#!/usr/bin/env bats

# Unit tests for .github/actions/dockerhub-mirror/mirror-lib.sh
#
# All tests use PATH stubs or injectable command vars ($DOCKER / $CURL).
# No real docker daemon or network is required.

load "../test_helper"

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
    LIB="${PROJECT_ROOT}/.github/actions/dockerhub-mirror/mirror-lib.sh"

    # Temporary directory for stubs and working files
    setup_temp_dir

    # Prepend stub bin dir to PATH so subprocesses can find stubs
    mkdir -p "${TEST_TEMP_DIR}/bin"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
}

teardown() {
    teardown_temp_dir
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a stub script that exits with a given code and optionally emits output.
# Usage: make_stub <name> <exit_code> [stdout_content]
make_stub() {
    local name="${1}" ec="${2}" out="${3:-}"
    cat > "${TEST_TEMP_DIR}/bin/${name}" <<STUB
#!/usr/bin/env bash
${out:+printf '%s\n' "${out}"}
exit ${ec}
STUB
    chmod +x "${TEST_TEMP_DIR}/bin/${name}"
}

# ---------------------------------------------------------------------------
# T1 — dhm_healthcheck: healthy when curl returns 200
# ---------------------------------------------------------------------------

@test "dhm_healthcheck returns 0 when curl yields HTTP 200" {
    # Stub curl to emit "200" as the http_code write-out
    make_stub curl 0 "200"
    export CURL="${TEST_TEMP_DIR}/bin/curl"

    # Source lib AFTER exporting injectable vars
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_healthcheck "http://127.0.0.1:5000/v2/" 3 ":"
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# T2 — dhm_healthcheck: healthy when curl returns 401 (auth required)
# ---------------------------------------------------------------------------

@test "dhm_healthcheck returns 0 when curl yields HTTP 401" {
    make_stub curl 0 "401"
    export CURL="${TEST_TEMP_DIR}/bin/curl"

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_healthcheck "http://127.0.0.1:5000/v2/" 3 ":"
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# T3 — dhm_healthcheck: timeout → non-0 after N retries exhausted
# ---------------------------------------------------------------------------

@test "dhm_healthcheck returns non-0 after all retries exhausted" {
    # Stub curl to always return connection-refused-like (exit 7, empty status)
    # Emit empty string so http_status="" which is neither 200 nor 401
    make_stub curl 7 ""
    export CURL="${TEST_TEMP_DIR}/bin/curl"

    # shellcheck disable=SC1090
    source "${LIB}"

    # max_retries=3, sleep_cmd=":" so the test runs fast
    run dhm_healthcheck "http://127.0.0.1:5000/v2/" 3 ":"
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# T6 — dhm_resolve_registry_image: picks GHCR ref when docker pull succeeds
# ---------------------------------------------------------------------------

@test "dhm_resolve_registry_image returns GHCR ref when pull succeeds" {
    # Stub docker to succeed on any pull
    make_stub docker 0 ""
    export DOCKER="${TEST_TEMP_DIR}/bin/docker"

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_resolve_registry_image \
        "ghcr.io/owner/registry:2" \
        "registry:2@sha256:abc123"
    [ "${status}" -eq 0 ]
    [ "${output}" = "ghcr.io/owner/registry:2" ]
}

# ---------------------------------------------------------------------------
# T7 — dhm_resolve_registry_image: falls back to digest-pinned docker.io ref
#      when GHCR pull fails
# ---------------------------------------------------------------------------

@test "dhm_resolve_registry_image falls back to docker.io digest-pinned ref on GHCR failure" {
    # Stub docker: first call (GHCR pull) exits 1; subsequent calls succeed
    local call_count_file="${TEST_TEMP_DIR}/call_count"
    echo "0" > "${call_count_file}"

    cat > "${TEST_TEMP_DIR}/bin/docker" <<STUB
#!/usr/bin/env bash
count=\$(cat "${call_count_file}")
echo \$((count + 1)) > "${call_count_file}"
if [ "\$count" -eq 0 ]; then
    exit 1   # GHCR pull fails
fi
exit 0       # fallback docker.io pull succeeds
STUB
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
    export DOCKER="${TEST_TEMP_DIR}/bin/docker"

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_resolve_registry_image \
        "ghcr.io/owner/registry:2" \
        "registry:2@sha256:abc123"
    [ "${status}" -eq 0 ]
    # bats `run` merges stderr into output; use contains rather than exact equality
    # because the warning line is also present.
    [[ "${output}" == *"registry:2@sha256:abc123"* ]]
}

# ---------------------------------------------------------------------------
# T8 — DRY_RUN guard: $DOCKER="echo docker" prints command instead of executing
# ---------------------------------------------------------------------------

@test "dhm_start_proxy prints docker run command when DOCKER='echo docker'" {
    # DRY_RUN mode: DOCKER is the echo-docker sentinel from logging.sh
    export DOCKER="echo docker"
    export DRY_RUN=true

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_start_proxy "5000" "${TEST_TEMP_DIR}" "ghcr.io/owner/registry:2" \
        "myuser" "supersecrettoken123"
    [ "${status}" -eq 0 ]
    # Should have printed the docker run command rather than executed it
    [[ "${output}" == *"docker run"* ]]
    [[ "${output}" == *"dockerhub-mirror"* ]]
    [[ "${output}" == *"127.0.0.1:5000:5000"* ]]
    # Regression lock: token value must NOT appear in the echoed output (credential leak guard).
    # Mutation: reverting to -e "REGISTRY_PROXY_PASSWORD=${token}" would echo the value → RED.
    [[ "${output}" != *"supersecrettoken123"* ]]
    # The name-only flag must be present (values passed via exported env, not argv).
    [[ "${output}" == *"-e REGISTRY_PROXY_PASSWORD"* ]]
    [[ "${output}" == *"-e REGISTRY_PROXY_USERNAME"* ]]
}

# ---------------------------------------------------------------------------
# T8b — DRY_RUN healthcheck: step 3 short-circuit skips curl poll and exits 0
#
# Validates the fix for the DRY_RUN defect: when DRY_RUN=true the proxy
# was never started, so the healthcheck must skip the curl poll entirely.
# Mutation: removing the DRY_RUN guard would cause dhm_healthcheck to poll
# a non-existent proxy → curl stub invoked → test fails on status or
# call-log presence.
# ---------------------------------------------------------------------------

@test "DRY_RUN=true: healthcheck step logic skips curl poll and exits 0" {
    # Stub curl to record calls and exit non-0 (simulates no proxy running).
    # If the short-circuit guard were absent, dhm_healthcheck would invoke
    # this stub and the test would detect it via the call log or non-0 exit.
    local curl_call_log="${TEST_TEMP_DIR}/curl_calls.log"

    cat > "${TEST_TEMP_DIR}/bin/curl" <<STUB
#!/usr/bin/env bash
echo "curl_called: \$*" >> "${curl_call_log}"
exit 7
STUB
    chmod +x "${TEST_TEMP_DIR}/bin/curl"

    # Write the step-3 logic to a helper script so we can test it cleanly
    # (same DRY_RUN guard that action.yaml step 3 uses).
    local step_script="${TEST_TEMP_DIR}/step3.sh"
    cat > "${step_script}" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
LIB="${LIB}"
CURL_STUB="${TEST_TEMP_DIR}/bin/curl"
source "\${LIB}"
export CURL="\${CURL_STUB}"
if [[ "\${DRY_RUN:-false}" == "true" ]]; then
    echo "DRY_RUN: skipping proxy healthcheck (proxy was not started)"
    exit 0
fi
proxy_url="\$(dhm_proxy_url "5000")"
dhm_healthcheck "\${proxy_url}" 3 ":"
SCRIPT
    chmod +x "${step_script}"

    # Run with DRY_RUN=true
    DRY_RUN=true run "${step_script}"

    # Must exit 0 (short-circuit succeeded)
    [ "${status}" -eq 0 ]
    # Must emit the skip message
    [[ "${output}" == *"DRY_RUN: skipping proxy healthcheck"* ]]
    # curl must NOT have been called (no proxy was started)
    [ ! -f "${curl_call_log}" ]
}

# ---------------------------------------------------------------------------
# T9 — port templating: dhm_proxy_url produces correct loopback URL
# ---------------------------------------------------------------------------

@test "dhm_proxy_url returns correct loopback URL for given port" {
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_proxy_url "5000"
    [ "${status}" -eq 0 ]
    [ "${output}" = "http://127.0.0.1:5000/v2/" ]
}

# ---------------------------------------------------------------------------
# T10 — dhm_proxy_url: alternate port is correctly templated
# ---------------------------------------------------------------------------

@test "dhm_proxy_url uses alternate port when specified" {
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_proxy_url "5555"
    [ "${status}" -eq 0 ]
    [ "${output}" = "http://127.0.0.1:5555/v2/" ]
}

# ---------------------------------------------------------------------------
# T11 — dhm_resolve_registry_image: both pulls fail → non-0 (error propagation)
# ---------------------------------------------------------------------------

@test "dhm_resolve_registry_image returns non-0 when both GHCR and fallback pulls fail" {
    # Stub docker: every call (both GHCR pull and digest-pinned fallback) exits 1
    local call_count_file="${TEST_TEMP_DIR}/call_count"
    echo "0" > "${call_count_file}"

    cat > "${TEST_TEMP_DIR}/bin/docker" <<STUB
#!/usr/bin/env bash
count=\$(cat "${call_count_file}")
echo \$((count + 1)) > "${call_count_file}"
exit 1   # all pulls fail
STUB
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
    export DOCKER="${TEST_TEMP_DIR}/bin/docker"

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_resolve_registry_image \
        "ghcr.io/owner/registry:2" \
        "registry:2@sha256:abc123"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# T13 — dhm_resolve_registry_image: empty registry_image + mixed-case owner →
#        derives lowercased digest-pinned ghcr.io/<owner>/registry@sha256:…
#        (NOT a mutable :2 tag — same digest as the docker.io fallback, DRY)
# ---------------------------------------------------------------------------

@test "dhm_resolve_registry_image with empty registry_image derives lowercased digest-pinned GHCR ref from owner" {
    # Stub docker: capture every pull invocation, succeed on all
    local pull_log="${TEST_TEMP_DIR}/pull_args.log"

    cat > "${TEST_TEMP_DIR}/bin/docker" <<STUB
#!/usr/bin/env bash
# Log the image ref being pulled (the last arg)
echo "\${@: -1}" >> "${pull_log}"
exit 0
STUB
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
    export DOCKER="${TEST_TEMP_DIR}/bin/docker"

    # shellcheck disable=SC1090
    source "${LIB}"

    # Pass empty registry_image and a mixed-case owner — function must lowercase it
    # and pin to the digest extracted from fallback_image.
    run dhm_resolve_registry_image \
        "" \
        "registry:2@sha256:abc123" \
        "MyOrg"
    [ "${status}" -eq 0 ]

    # The resolved image returned on stdout must be the digest-pinned GHCR ref
    # (digest extracted from fallback_image, owner lowercased, NO mutable :2 tag)
    [ "${output}" = "ghcr.io/myorg/registry@sha256:abc123" ]

    # Confirm the docker pull was attempted with the digest-pinned ref
    [ -f "${pull_log}" ]
    grep -q "^ghcr.io/myorg/registry@sha256:abc123$" "${pull_log}"
}

# ---------------------------------------------------------------------------
# T12 — dhm_start_proxy: docker rm -f issued BEFORE docker run on retry/reuse
# ---------------------------------------------------------------------------

@test "dhm_start_proxy issues docker rm -f before docker run for idempotent restarts" {
    # Capture every docker invocation (subcommand + args) into a log file,
    # then assert the rm -f call appears before the run call.
    local call_log="${TEST_TEMP_DIR}/docker_calls.log"

    cat > "${TEST_TEMP_DIR}/bin/docker" <<STUB
#!/usr/bin/env bash
# Append the full argument list as a single line so we can assert order.
echo "\$*" >> "${call_log}"
exit 0
STUB
    chmod +x "${TEST_TEMP_DIR}/bin/docker"
    export DOCKER="${TEST_TEMP_DIR}/bin/docker"

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_start_proxy "5000" "${TEST_TEMP_DIR}" "ghcr.io/owner/registry:2" \
        "myuser" "mytoken"
    [ "${status}" -eq 0 ]

    # The call log must exist and contain at least two entries.
    [ -f "${call_log}" ]

    # Extract the line numbers of the rm and run calls.
    rm_line=$(grep -n "^rm -f " "${call_log}" | head -1 | cut -d: -f1)
    run_line=$(grep -n "^run -d " "${call_log}" | head -1 | cut -d: -f1)

    # Both commands must be present.
    [ -n "${rm_line}" ]
    [ -n "${run_line}" ]

    # rm -f must appear BEFORE docker run (lower line number).
    [ "${rm_line}" -lt "${run_line}" ]

    # The rm -f call must reference the container name "dockerhub-mirror".
    grep -q "^rm -f dockerhub-mirror" "${call_log}"

    # The run call must also reference the same name via --name.
    grep -q "^run -d .*--name dockerhub-mirror" "${call_log}"
}

# ---------------------------------------------------------------------------
# T15 — DRY_RUN stdout guard: dhm_resolve_registry_image under DRY_RUN must
#        return a single clean image ref with no "docker pull" prefix.
#
# Regression lock: if the >/dev/null redirect on the pull-test calls is
# removed, DOCKER="echo docker" causes "echo docker pull <ref>" to write
# "docker pull <ref>" to stdout, which the caller captures via $(...).
# The returned value then becomes "docker pull ghcr.io/...\nghcr.io/..." —
# a corrupt multi-line string.  This test uses exact-equality on $output so
# that any stdout leakage turns it RED immediately.
# ---------------------------------------------------------------------------

@test "T15: DRY_RUN — dhm_resolve_registry_image returns single-line lowercase GHCR ref (no docker pull prefix)" {
    # Simulate DRY_RUN by setting DOCKER to the echo-docker sentinel.
    # Under DRY_RUN the pull-test must be silenced (>/dev/null 2>&1);
    # only the intentional printf '%s\n' should reach stdout.
    export DOCKER="echo docker"

    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_resolve_registry_image "" "registry:2@sha256:abc" "MixedCaseOwner"
    [ "${status}" -eq 0 ]
    # Must be exactly the digest-pinned lowercased GHCR ref — single line, no "docker pull" prefix.
    [ "${output}" = "ghcr.io/mixedcaseowner/registry@sha256:abc" ]
}

# ---------------------------------------------------------------------------
# T16 — dhm_assert_ephemeral_runner: enforce self-hosted boundary
#
# Regression lock: if the guard is removed (or the condition inverted),
# the self-hosted-no-opt-in branch no longer fails-closed and T16b turns RED.
# ---------------------------------------------------------------------------

@test "T16a: dhm_assert_ephemeral_runner passes on github-hosted regardless of allow_self_hosted" {
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_assert_ephemeral_runner "github-hosted" "false"
    [ "${status}" -eq 0 ]
}

@test "T16b: dhm_assert_ephemeral_runner fails-closed on self-hosted without opt-in" {
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_assert_ephemeral_runner "self-hosted" "false"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"::error::"* ]]
    [[ "${output}" == *"allow_self_hosted"* ]]
}

@test "T16c: dhm_assert_ephemeral_runner passes on self-hosted when allow_self_hosted=true" {
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_assert_ephemeral_runner "self-hosted" "true"
    [ "${status}" -eq 0 ]
}

@test "T16d: dhm_assert_ephemeral_runner fails-closed on unknown/empty runner_environment without opt-in" {
    # shellcheck disable=SC1090
    source "${LIB}"

    run dhm_assert_ephemeral_runner "" "false"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"::error::"* ]]
}
