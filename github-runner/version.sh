#!/usr/bin/env bash
# github-runner/version.sh
# Discover the latest upstream GitHub Actions runner version.
#
# Supports multiple output formats:
#   version.sh                 → plain version (e.g., 2.332.0)
#   version.sh --upstream      → same (alias for compatibility)
#   version.sh --registry-pattern → regex for published version matching
#
# Environment:
#   GITHUB_TOKEN — optional PAT for higher API rate limits

set -euo pipefail
source "$(dirname "$0")/../helpers/logging.sh"

REPO="actions/runner"
API="https://api.github.com/repos/${REPO}/releases/latest"

case "${1:-}" in
    --registry-pattern)
        echo "^[0-9]+\.[0-9]+\.[0-9]+$"
        exit 0
        ;;
esac

# Build curl arguments — inject Authorization header only when GITHUB_TOKEN is set
curl_args=(-sf -H "Accept: application/vnd.github+json")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

response=$(curl "${curl_args[@]}" "${API}") || {
    log_error "Failed to reach GitHub API for ${REPO}"
    exit 1
}

version=$(echo "${response}" | jq -r '.tag_name | ltrimstr("v")')

if [[ -z "${version}" || "${version}" == "null" ]]; then
    log_error "Could not parse version from GitHub API response"
    exit 1
fi

echo "${version}"
