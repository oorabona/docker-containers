#!/usr/bin/env bash
# mirror-lib.sh — Testable decision-logic library for the dockerhub-mirror action.
#
# Design: pure functions where possible; side-effecting commands go through
# injectable vars so bats can stub without touching the network or docker daemon.
#
#   DOCKER  — defaults to the $DOCKER set by helpers/logging.sh (or "docker")
#   CURL    — defaults to "curl"
#
# Source this file; do NOT execute it directly.

set -euo pipefail

# ---------------------------------------------------------------------------
# Injectable command vars (match helpers/logging.sh pattern for $DOCKER)
# ---------------------------------------------------------------------------
# $DOCKER is expected to be set by the caller (sourcing helpers/logging.sh
# or the inline DRY_RUN guard in action.yaml).  If it is not set, fall back
# to "docker" — same convention as logging.sh.
: "${DOCKER:=docker}"
# $CURL injectable for bats stubs (no DRY_RUN echo-wrapper needed; healthcheck
# uses curl only for probing, not for side effects that must be suppressed).
: "${CURL:=curl}"

# ---------------------------------------------------------------------------
# dhm_resolve_registry_image <registry_image> <fallback_image> [owner]
#
# Resolve the registry:2 sidecar image reference and pull it.
#
# <registry_image>: explicit image ref to use.  When empty (the default input),
#   the GHCR candidate is derived from <fallback_image>'s digest and <owner>:
#   ghcr.io/<owner-lowercased>/registry@<digest>
#   where <digest> is extracted from the <fallback_image> arg (must contain @sha256:…).
#   Using the same digest for both GHCR and docker.io is correct: B5 seeds GHCR
#   from that exact docker.io digest, so the GHCR manifest resolves to it.
# <fallback_image>: digest-pinned docker.io image used when the GHCR pull fails.
#                   Must include a digest (@sha256:…) — used as the canonical pin
#                   for both the GHCR candidate ref and the docker.io fallback.
# [owner]:          GitHub repository owner — required when <registry_image> is
#                   empty, optional otherwise (ignored when registry_image is set).
#
# stdout: the image reference that was successfully pulled
# stderr: progress / warning messages
# exit:   0 on success, non-0 if both pulls fail (propagates from $DOCKER pull)
# ---------------------------------------------------------------------------
dhm_resolve_registry_image() {
    local registry_image="${1}"           # may be empty
    local fallback_image="${2:?fallback_image required}"
    local owner="${3:-}"                  # GITHUB_REPOSITORY_OWNER, required when registry_image is empty

    # When registry_image is not provided, derive the GHCR candidate from owner.
    # GHCR requires lowercase owner names.  Pin to the same digest as fallback_image
    # (DRY: single digest source; B5 seeds GHCR from that exact docker.io digest).
    if [[ -z "${registry_image}" ]]; then
        if [[ -z "${owner}" ]]; then
            echo "::error::dhm_resolve_registry_image: registry_image is empty and no owner supplied" >&2
            return 1
        fi
        # Extract digest from fallback_image (everything after '@')
        local digest="${fallback_image##*@}"
        # Bash 4+ parameter expansion lowercase: ${var,,}
        registry_image="ghcr.io/${owner,,}/registry@${digest}"
    fi

    # shellcheck disable=SC2086
    # $DOCKER is intentionally word-split ("echo docker" in DRY_RUN mode).
    # Redirect BOTH stdout and stderr to /dev/null so that under DRY_RUN
    # ("echo docker pull <ref>") the echoed command does not pollute the
    # function's stdout contract (callers capture output via command substitution).
    if $DOCKER pull "${registry_image}" >/dev/null 2>&1; then
        printf '%s\n' "${registry_image}"
    else
        echo "::warning::GHCR registry image ${registry_image} not yet available; falling back to digest-pinned docker.io image" >&2
        # shellcheck disable=SC2086
        $DOCKER pull "${fallback_image}" >/dev/null 2>&1 || return $?
        printf '%s\n' "${fallback_image}"
    fi
}

# ---------------------------------------------------------------------------
# dhm_assert_ephemeral_runner <runner_environment> <allow_self_hosted>
#
# Safety gate: REGISTRY_PROXY_PASSWORD is visible via docker inspect; it is
# only safe on ephemeral GitHub-hosted runners.  Fail-closed on self-hosted
# unless the caller has explicitly opted in.
#
# <runner_environment>: value of $RUNNER_ENVIRONMENT ("github-hosted" or
#                       "self-hosted"; empty string treated as unknown).
# <allow_self_hosted>:  explicit opt-in flag ("true" skips the block).
#
# stdout: nothing
# stderr: ::error:: message on violation
# exit:   0 when safe to proceed, 1 when blocked
# ---------------------------------------------------------------------------
dhm_assert_ephemeral_runner() {
    local runner_environment="${1:-}"
    local allow_self_hosted="${2:-false}"

    if [[ "${runner_environment}" != "github-hosted" && "${allow_self_hosted}" != "true" ]]; then
        echo "::error::dockerhub-mirror: REGISTRY_PROXY_PASSWORD is visible via docker inspect; only safe on ephemeral GitHub-hosted runners. Set allow_self_hosted: true to override on a trusted single-tenant runner." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# dhm_start_proxy <port> <runner_temp> <registry_image>
#                 <dockerhub_username> <dockerhub_token>
#
# Start the registry:2 pull-through sidecar container.
# Uses $DOCKER (injectable for DRY_RUN / stubs).
#
# exit: 0 on success (propagates $DOCKER run exit code)
# ---------------------------------------------------------------------------
dhm_start_proxy() {
    local port="${1:?port required}"
    local runner_temp="${2:?runner_temp required}"
    local registry_image="${3:?registry_image required}"
    local dockerhub_username="${4:?dockerhub_username required}"
    local dockerhub_token="${5:?dockerhub_token required}"

    local container_name="dockerhub-mirror"

    mkdir -p "${runner_temp}/registry-mirror"

    # Export creds so docker passes them by NAME only — the values never appear
    # on the command line (no argv leak, no dry-run echo leak).
    export REGISTRY_PROXY_USERNAME="${dockerhub_username}"
    export REGISTRY_PROXY_PASSWORD="${dockerhub_token}"

    # Remove any pre-existing container of the same name so retries and
    # reused self-hosted runners do not fail with "name already in use".
    # shellcheck disable=SC2086
    # $DOCKER intentionally word-split (see top of file)
    $DOCKER rm -f "${container_name}" >/dev/null 2>&1 || true

    # shellcheck disable=SC2086
    $DOCKER run -d --name "${container_name}" --restart=no \
        -p "127.0.0.1:${port}:5000" \
        -v "${runner_temp}/registry-mirror:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
        -e REGISTRY_PROXY_USERNAME \
        -e REGISTRY_PROXY_PASSWORD \
        -e REGISTRY_PROXY_TTL=168h \
        "${registry_image}"
    # NB: REGISTRY_PROXY_TTL is ignored by registry:2 v2.8.3 (proxy manifest TTL default is already
    # 168h); kept as an intent marker for future versions.
}

# ---------------------------------------------------------------------------
# dhm_healthcheck <proxy_url> <max_retries> [sleep_cmd]
#
# Poll <proxy_url> up to <max_retries> times (1 s apart).
# /v2/ returns 200 (no auth) or 401 (auth required) — both mean proxy is up.
# Uses $CURL (injectable for bats stubs).
#
# <sleep_cmd>: optional override for the sleep between retries (default: "sleep").
#              Pass "true" or ":" in tests to skip real sleeps.
#
# stdout: nothing (progress messages on stderr)
# exit:   0 if healthy before timeout, 1 if all retries exhausted
# ---------------------------------------------------------------------------
dhm_healthcheck() {
    local proxy_url="${1:?proxy_url required}"
    local max_retries="${2:?max_retries required}"
    local sleep_cmd="${3:-sleep}"

    local i healthy=false

    for i in $(seq 1 "${max_retries}"); do
        local http_status
        # $CURL injectable; capture HTTP status code via -w; suppress body; -f makes
        # curl exit non-0 on 4xx/5xx but we want 401 to count as healthy — so we
        # capture the status code manually instead of relying on curl's exit code.
        http_status=$(
            # shellcheck disable=SC2086
            $CURL -sS -o /dev/null -w "%{http_code}" "${proxy_url}" 2>/dev/null
        ) || true  # curl may exit non-0 on connection refused — that's fine; check status below

        if [[ "${http_status}" == "200" ]] || [[ "${http_status}" == "401" ]]; then
            healthy=true
            echo "::notice::Docker Hub mirror proxy is healthy on ${proxy_url} (HTTP ${http_status}, attempt ${i})" >&2
            break
        fi

        echo "Waiting for mirror proxy (attempt ${i}/${max_retries}, HTTP ${http_status})..." >&2
        ${sleep_cmd} 1
    done

    if [[ "${healthy}" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# dhm_proxy_url <port>
#
# Print the proxy health-check URL for the given port.
# Pure function — no side effects.
# ---------------------------------------------------------------------------
dhm_proxy_url() {
    local port="${1:?port required}"
    printf 'http://127.0.0.1:%s/v2/\n' "${port}"
}
