#!/usr/bin/env bash
# Resolver: timescaledb version-set for a given PG major
#
# Inputs (env):
#   PG_MAJOR         (required) — PostgreSQL major version, e.g. 18
#   EXT_NAME         (optional) — extension name, used in error messages
#   CEILING_VERSION  (optional) — maximum version to include (inclusive semver)
#
# Output: compact JSON array of version strings, sorted oldest→newest
# Exit:   0 on success, non-zero on any error (fail-closed, nothing on stdout)
#
# Algorithm: derive the version set directly from HA image tags.
# Real tag format: pg<MAJOR>.<pgminor>-ts<X.Y.Z>[-suffix]
# e.g. pg18.0-ts2.23.0, pg18.4-ts2.27.1, pg17.2-ts2.18.1-oss
# One source (HA registry) enumerates every shipped TS version per PG major.
#
# Test hook:
#   _RESOLVER_HA_TAGS_FIXTURE — path to file; substitutes skopeo call

set -euo pipefail

EXT_NAME="${EXT_NAME:-timescaledb}"
PG_MAJOR="${PG_MAJOR:?PG_MAJOR is required}"
CEILING_VERSION="${CEILING_VERSION:-}"

# Emit error to stderr using GHA annotation format when available
_error() {
    echo "::error::${EXT_NAME} resolver: $*" >&2
}

# Fetch HA image tags — one tag per line
# Test hook: _RESOLVER_HA_TAGS_FIXTURE
_resolver_fetch_ha_tags() {
    if [[ -n "${_RESOLVER_HA_TAGS_FIXTURE:-}" ]]; then
        cat "${_RESOLVER_HA_TAGS_FIXTURE}"
    else
        skopeo list-tags docker://docker.io/timescale/timescaledb-ha \
            | jq -r '.Tags[]'
    fi
}

# Compare two X.Y.Z semver versions; return 0 if a <= b
_semver_le() {
    local a="$1" b="$2"
    local a1 a2 a3 b1 b2 b3
    IFS='.' read -r a1 a2 a3 <<< "$a"
    IFS='.' read -r b1 b2 b3 <<< "$b"
    if (( a1 != b1 )); then (( a1 < b1 )); return; fi
    if (( a2 != b2 )); then (( a2 < b2 )); return; fi
    (( a3 <= b3 ))
}

main() {
    # Fetch HA tags (one per line)
    local ha_tags
    if ! ha_tags="$(_resolver_fetch_ha_tags 2>/dev/null)"; then
        _error "failed to fetch HA tags"
        exit 1
    fi

    # Extract unique X.Y.Z TS versions from real HA tags for this PG_MAJOR.
    # Real tag format: pg<MAJOR>.<pgminor>-ts<X.Y.Z>[-suffix]
    # Only tags matching exactly ^pg${PG_MAJOR}\.[0-9]+-ts[0-9]+\.[0-9]+\.[0-9]+$
    # (anchored: no suffix) are selected; variants like -oss/-all/-dev/-amd64 etc.
    # are excluded by the end-anchor, so de-duplication is automatic.
    local versions
    versions=$(
        { echo "$ha_tags" \
            | grep -E "^pg${PG_MAJOR}\.[0-9]+-ts[0-9]+\.[0-9]+\.[0-9]+$" \
            | sed "s/^pg${PG_MAJOR}\.[0-9]*-ts//"; } 2>/dev/null || true
    )

    if [[ -z "$versions" ]]; then
        _error "no HA tags found for PG${PG_MAJOR}"
        exit 1
    fi

    # De-duplicate (multiple pg minors may carry the same TS X.Y.Z).
    versions=$(echo "$versions" | sort -V -u)

    # Apply ceiling filter when set.
    local filtered=""
    if [[ -n "$CEILING_VERSION" ]]; then
        while IFS= read -r ver; do
            if _semver_le "$ver" "$CEILING_VERSION"; then
                filtered+="${ver}"$'\n'
            fi
        done <<< "$versions"
    else
        filtered="$versions"$'\n'
    fi

    if [[ -z "${filtered// /}" ]] || [[ -z "$(echo "$filtered" | grep -v '^$' || true)" ]]; then
        _error "no versions in range [floor, ${CEILING_VERSION:-∞}]"
        exit 1
    fi

    # Sort oldest→newest and emit compact JSON array
    local sorted
    sorted=$(echo "$filtered" | grep -v '^$' | sort -V)

    local json_array
    json_array=$(echo "$sorted" | jq -Rsc 'split("\n") | map(select(length > 0))')

    # Validate the output is a non-empty JSON array
    local count
    count=$(echo "$json_array" | jq 'length')
    if (( count == 0 )); then
        _error "produced empty JSON array"
        exit 1
    fi

    # Assert the configured pinned version (CEILING_VERSION) is present in the
    # resolved set. An absent ceiling means the config version is a typo or the
    # upstream tag hasn't been published yet — either way the build would silently
    # succeed without ever validating the pinned version.
    if [[ -n "$CEILING_VERSION" ]]; then
        local ceiling_present
        ceiling_present=$(echo "$json_array" | jq --arg v "$CEILING_VERSION" 'map(select(. == $v)) | length')
        if (( ceiling_present == 0 )); then
            _error "configured version ${CEILING_VERSION} not found in upstream HA tags"
            exit 1
        fi
    fi

    printf '%s\n' "$json_array"
}

main "$@"
