#!/usr/bin/env bash

# Attestation helpers for docker-containers dashboard
# Queries GitHub Attestations API to surface SBOM attestation IDs
# Requires: gh CLI authenticated, jq
# Optional: GITHUB_TOKEN (CI always has it)

ATTESTATION_UTILS_OWNER_REPO="oorabona/docker-containers"

# Avoid re-sourcing logging.sh colors (idempotent guard)
if [[ -z "${_LOGGING_LOADED:-}" ]]; then
    _SCRIPT_DIR_ATTEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SCRIPT_DIR_ATTEST/logging.sh"
    _LOGGING_LOADED=1
fi

# get_attestation_id <subject_digest>
# Queries the GitHub Attestations API for the most recent attestation whose
# subject matches the given image digest (sha256:...).
# Returns 0 + prints the attestation ID on stdout if found, 1 otherwise.
# When gh auth is unavailable or the API returns an error, logs a warning and
# returns 1 — callers must handle the empty result gracefully.
get_attestation_id() {
    local digest="$1"
    if [[ -z "$digest" || "$digest" == "null" || "$digest" == "unknown" ]]; then
        return 1
    fi

    local response
    response=$(gh api \
        "repos/${ATTESTATION_UTILS_OWNER_REPO}/attestations?subject_digest=${digest}" \
        2>/dev/null) || {
        log_warning "gh api attestations failed for digest ${digest} (auth or network)"
        return 1
    }

    local id
    id=$(echo "$response" | \
        jq -r '.attestations | sort_by(.created_at) | reverse | .[0].id // empty' \
        2>/dev/null)

    if [[ -z "$id" ]]; then
        return 1
    fi

    echo "$id"
}

# get_attestation_url <attestation_id>
# Returns the public GitHub attestation viewer URL for the given ID.
get_attestation_url() {
    local id="$1"
    if [[ -z "$id" ]]; then
        return 1
    fi
    echo "https://github.com/${ATTESTATION_UTILS_OWNER_REPO}/attestations/${id}"
}
