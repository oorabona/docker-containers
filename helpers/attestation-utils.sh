#!/usr/bin/env bash

# Attestation helpers for docker-containers dashboard
# Queries GitHub Attestations API to surface SBOM attestation IDs
# Requires: gh CLI authenticated, jq
# Optional: GITHUB_TOKEN (CI always has it)

ATTESTATION_UTILS_OWNER_REPO="oorabona/docker-containers"

# In-process memoization cache for attestation lookups keyed by image digest.
# Value "__MISS__" means the digest was queried and no attestation was found.
# Avoids redundant gh API calls when multiple variants share the same build digest.
declare -A _ATTESTATION_CACHE=() 2>/dev/null || true

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

    # Cache hit — avoids redundant API calls for variants sharing the same digest
    if [[ -v _ATTESTATION_CACHE["$digest"] ]]; then
        local cached="${_ATTESTATION_CACHE[$digest]}"
        if [[ "$cached" == "__MISS__" ]]; then
            return 1
        fi
        echo "$cached"
        return 0
    fi

    # Cache miss — query GitHub Attestations API
    local response
    response=$(gh api \
        "repos/${ATTESTATION_UTILS_OWNER_REPO}/attestations?subject_digest=${digest}" \
        2>/dev/null) || {
        log_warning "gh api attestations failed for digest ${digest} (auth or network)"
        _ATTESTATION_CACHE["$digest"]="__MISS__"
        return 1
    }

    local id
    id=$(echo "$response" | \
        jq -r '.attestations | sort_by(.created_at) | reverse | .[0].id // empty' \
        2>/dev/null)

    if [[ -z "$id" ]]; then
        # No attestation found for this digest — expected for builds with SBOM step skipped
        _ATTESTATION_CACHE["$digest"]="__MISS__"
        return 1
    fi

    _ATTESTATION_CACHE["$digest"]="$id"
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
