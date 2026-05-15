#!/usr/bin/env bash

# Shared registry API utilities for Docker Hub and GHCR
# Eliminates duplication across ./make and generate-dashboard.sh
# Requires: curl, jq
# Optional: gh (for authenticated GHCR access)

# --- GHCR (GitHub Container Registry) ---

# Get a GHCR registry token
# Tries authenticated (gh auth) first, falls back to anonymous
# Usage: ghcr_get_token "owner/repo"
# Output: bearer token string or ""
ghcr_get_token() {
    local image_path="$1"  # owner/repo (without ghcr.io/ prefix)
    local token=""

    # Try authenticated token via gh CLI
    local gh_token
    if gh_token=$(gh auth token 2>/dev/null) && [[ -n "$gh_token" ]]; then
        local owner
        owner=$(echo "$image_path" | cut -d'/' -f1)
        token=$(curl -s --connect-timeout 5 --max-time 10 \
            "https://ghcr.io/token?service=ghcr.io&scope=repository:${image_path}:pull" \
            -u "${owner}:${gh_token}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
    fi

    # Fall back to anonymous token
    if [[ -z "$token" ]]; then
        token=$(curl -s --connect-timeout 5 --max-time 10 \
            "https://ghcr.io/token?scope=repository:${image_path}:pull" 2>/dev/null | \
            jq -r '.token // empty' 2>/dev/null)
    fi

    echo "$token"
}

# Get manifest sizes for a GHCR image (all architectures)
# Output: one line per arch, format "arch:total_bytes"
# Usage: ghcr_get_manifest_sizes "owner/repo" "tag"
ghcr_get_manifest_sizes() {
    local image_path="$1"  # owner/repo (without ghcr.io/ prefix)
    local tag="${2:-latest}"

    local token
    token=$(ghcr_get_token "$image_path")
    [[ -z "$token" ]] && return 1

    # Get manifest list (accept both Docker and OCI formats)
    local manifest
    manifest=$(curl -s --connect-timeout 5 --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://ghcr.io/v2/${image_path}/manifests/${tag}" 2>/dev/null)

    [[ -z "$manifest" ]] && return 1

    # Check for errors
    if echo "$manifest" | jq -e '.errors' >/dev/null 2>&1; then
        return 1
    fi

    # Multi-platform manifest list
    if echo "$manifest" | jq -e '.manifests' >/dev/null 2>&1; then
        local manifests_data
        manifests_data=$(echo "$manifest" | jq -r '.manifests[] | "\(.platform.architecture):\(.digest)"' 2>/dev/null)

        while IFS=':' read -r arch digest_prefix digest_hash; do
            [[ -z "$arch" || -z "$digest_hash" ]] && continue
            [[ "$arch" == "unknown" ]] && continue

            local platform_manifest
            platform_manifest=$(curl -s --connect-timeout 5 --max-time 10 \
                -H "Authorization: Bearer $token" \
                -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
                "https://ghcr.io/v2/${image_path}/manifests/${digest_prefix}:${digest_hash}" 2>/dev/null)

            local total_size
            total_size=$(echo "$platform_manifest" | jq '[.config.size // 0] + [.layers[]?.size // 0] | add // 0' 2>/dev/null)
            echo "${arch}:${total_size:-0}"
        done <<< "$manifests_data"
    else
        # Single manifest (no manifest list)
        local total_size
        total_size=$(echo "$manifest" | jq '[.config.size // 0] + [.layers[]?.size // 0] | add // 0' 2>/dev/null)
        echo "amd64:${total_size:-0}"
    fi
}

# Get multi-arch index digest + per-platform manifest digests for a GHCR image.
# Usage: ghcr_get_multi_arch_digests "<owner>/<image>" "<tag>"
# Output (JSON to stdout):
#   {
#     "index_digest": "sha256:...",          // index manifest digest
#     "manifest_digest_amd64": "sha256:...", // null if not present in index
#     "manifest_digest_arm64": "sha256:..."  // null if not present in index
#   }
# For single-arch images (no .manifests array), emits:
#   {"index_digest": "<digest>", "manifest_digest_amd64": null, "manifest_digest_arm64": null}
# On API failure: emits all-null JSON. Never exits non-zero. Always emits valid JSON.
ghcr_get_multi_arch_digests() {
    local image="$1"  # e.g. "oorabona/postgres"
    local tag="$2"    # e.g. "18-alpine"

    local token
    token=$(ghcr_get_token "$image" 2>/dev/null) || {
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    }

    if [[ -z "$token" ]]; then
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    fi

    # Fetch the manifest, capturing BOTH response headers AND body.
    # The Docker-Content-Digest header is the digest of the fetched object
    # (the index, when Accept includes the index media type).
    local response headers body index_digest
    response=$(curl -sS -D - --max-time 15 \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/${image}/manifests/${tag}" 2>/dev/null || true)

    if [[ -z "$response" ]]; then
        echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
        return 0
    fi

    # Split headers / body at the first blank line.
    headers=$(printf '%s' "$response" | sed -n '1,/^\r\?$/p')
    body=$(printf '%s' "$response" | sed -n '/^\r\?$/,$p' | sed '1d')

    # Index digest from the Docker-Content-Digest header.
    # || true guards against grep returning 1 (no match) under set -euo pipefail.
    index_digest=$(printf '%s' "$headers" | grep -iE '^docker-content-digest:' 2>/dev/null | awk '{print $2}' | tr -d '\r' | head -1 || true)
    [[ -z "$index_digest" ]] && index_digest="null"

    # Per-arch manifest digests from the body (.manifests[].{platform.architecture, digest}).
    # jq returns empty output (not "null") when the key is absent, so we test with [[ -z ]].
    local amd64_digest arm64_digest
    amd64_digest=$(printf '%s' "$body" | jq -r 'if .manifests then (.manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux") | .digest) else empty end' 2>/dev/null | head -1 || true)
    arm64_digest=$(printf '%s' "$body" | jq -r 'if .manifests then (.manifests[] | select(.platform.architecture == "arm64" and .platform.os == "linux") | .digest) else empty end' 2>/dev/null | head -1 || true)
    [[ -z "$amd64_digest" ]] && amd64_digest="null"
    [[ -z "$arm64_digest" ]] && arm64_digest="null"

    # Emit compact JSON. jq maps the sentinel "null" string → JSON null.
    jq -nc \
        --arg idx "$index_digest" \
        --arg amd "$amd64_digest" \
        --arg arm "$arm64_digest" \
        '{
            index_digest: (if $idx == "null" then null else $idx end),
            manifest_digest_amd64: (if $amd == "null" then null else $amd end),
            manifest_digest_arm64: (if $arm == "null" then null else $arm end)
        }' 2>/dev/null || echo '{"index_digest":null,"manifest_digest_amd64":null,"manifest_digest_arm64":null}'
}

# --- Docker Hub ---

# Get per-tag manifest sizes from Docker Hub
# Output: one line per arch, format "arch:total_bytes"
# Usage: dockerhub_get_tag_sizes "username" "repo" "tag"
dockerhub_get_tag_sizes() {
    local username="$1"
    local repo="$2"
    local tag="$3"

    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://hub.docker.com/v2/repositories/${username}/${repo}/tags/${tag}" 2>/dev/null) || return 1

    if echo "$response" | jq -e '.errinfo' >/dev/null 2>&1; then
        return 1
    fi

    echo "$response" | jq -r '.images[]? | "\(.architecture):\(.size)"' 2>/dev/null
}

# Get repository stats from Docker Hub (pull count, star count)
# Output: "pulls:N stars:M"
# Usage: dockerhub_get_repo_stats "username" "repo"
dockerhub_get_repo_stats() {
    local username="$1"
    local repo="$2"
    local response pulls stars

    response=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://hub.docker.com/v2/repositories/${username}/${repo}" 2>/dev/null)

    if [[ -n "$response" ]]; then
        pulls=$(echo "$response" | jq -r '.pull_count // 0' 2>/dev/null)
        stars=$(echo "$response" | jq -r '.star_count // 0' 2>/dev/null)
    fi

    [[ -z "$pulls" || "$pulls" == "null" ]] && pulls="0"
    [[ -z "$stars" || "$stars" == "null" ]] && stars="0"

    echo "pulls:$pulls stars:$stars"
}
