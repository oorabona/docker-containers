#!/usr/bin/env bash
# Release-artifact helpers.
#
# A container may declare, in config.yaml, the URL of the upstream artifact its
# Dockerfile downloads:
#
#   artifact_url: "https://example.org/rel/${UPSTREAM_VERSION}/tool-${RELEASE_VERSION}.tar.gz"
#   artifact_signature_suffix: ".asc"      # optional: also require URL + suffix
#
# That single declaration feeds both consumers, so they cannot drift apart:
#   - the build receives the resolved URL as --build-arg ARTIFACT_URL
#   - `make check-updates` only proposes a new version once the URL answers
#
# Placeholders: ${UPSTREAM_VERSION} is the raw output of `version.sh --upstream`
# (e.g. v2.7.8); ${RELEASE_VERSION} is the same without a leading "v".
#
# Without `artifact_url` nothing changes for the container.

# Read a top-level scalar from <dir>/config.yaml (empty when absent).
# Usage: artifact_config_value <dir> <key>
artifact_config_value() {
    local dir="$1" key="$2"
    [[ -f "$dir/config.yaml" ]] || return 0
    yq -r ".${key} // \"\"" "$dir/config.yaml" 2>/dev/null || true
}

# Resolve the URL template for a given upstream version.
# Usage: resolve_artifact_url <template> <upstream_version>
# Fails (non-zero, nothing on stdout) on an empty version or when the result is
# not a plain https URL: the value ends up in a docker argument list.
resolve_artifact_url() {
    local template="$1" upstream="$2"
    [[ -n "$template" && -n "$upstream" ]] || return 1

    local url="${template//\$\{UPSTREAM_VERSION\}/$upstream}"
    url="${url//\$\{RELEASE_VERSION\}/${upstream#v}}"

    [[ "$url" =~ ^https://[A-Za-z0-9._~:/?@%+,=-]+$ ]] || return 1
    printf '%s\n' "$url"
}

# Succeeds when the URL answers 2xx after redirects (HEAD request).
# Usage: artifact_reachable <url>
artifact_reachable() {
    curl -fsSIL --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 60 \
        -o /dev/null "$1" 2>/dev/null
}

# Is the artifact declared by <dir>/config.yaml downloadable for <upstream>?
#   0 = ready, or nothing declared (the gate is opt-in)
#   1 = declared but not downloadable yet (the caller treats it as "not yet")
# A declaration that cannot be resolved also returns 1: proposing a version
# whose artifact cannot even be located is the failure this gate exists for.
# Usage: artifact_ready <dir> <upstream_version>
artifact_ready() {
    local dir="$1" upstream="$2"
    local template
    template=$(artifact_config_value "$dir" artifact_url)
    [[ -n "$template" ]] || return 0

    local url
    if ! url=$(resolve_artifact_url "$template" "$upstream"); then
        return 1
    fi
    artifact_reachable "$url" || return 1

    local sig_suffix
    sig_suffix=$(artifact_config_value "$dir" artifact_signature_suffix)
    if [[ -n "$sig_suffix" ]]; then
        artifact_reachable "${url}${sig_suffix}" || return 1
    fi
    return 0
}
