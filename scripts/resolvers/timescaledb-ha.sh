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
# Test hooks:
#   _RESOLVER_HA_TAGS_FIXTURE — path to file; substitutes skopeo call
#   _RESOLVER_TS_TAGS_FIXTURE — path to file; substitutes gh api call

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
_resolver_fetch_ha_minor_tags() {
    if [[ -n "${_RESOLVER_HA_TAGS_FIXTURE:-}" ]]; then
        cat "${_RESOLVER_HA_TAGS_FIXTURE}"
    else
        skopeo list-tags docker://docker.io/timescale/timescaledb-ha \
            | jq -r '.Tags[]'
    fi
}

# Fetch timescaledb GitHub release tag names — one per line
# Test hook: _RESOLVER_TS_TAGS_FIXTURE
_resolver_fetch_ts_tags() {
    if [[ -n "${_RESOLVER_TS_TAGS_FIXTURE:-}" ]]; then
        cat "${_RESOLVER_TS_TAGS_FIXTURE}"
    else
        gh api repos/timescale/timescaledb/tags --paginate \
            --jq '.[].name'
    fi
}

# Compare two X.Y semver minors numerically; return 0 if a >= b
_minor_ge() {
    local a_major a_minor b_major b_minor
    a_major="${1%%.*}"; a_minor="${1#*.}"
    b_major="${2%%.*}"; b_minor="${2#*.}"
    if (( a_major != b_major )); then
        (( a_major > b_major ))
    else
        (( a_minor >= b_minor ))
    fi
}

# Compare two X.Y.Z semver versions; return 0 if a <= b
_semver_le() {
    local a="$1" b="$2"
    # Split into parts and compare numerically
    local a1 a2 a3 b1 b2 b3
    IFS='.' read -r a1 a2 a3 <<< "$a"
    IFS='.' read -r b1 b2 b3 <<< "$b"
    if (( a1 != b1 )); then (( a1 < b1 )); return; fi
    if (( a2 != b2 )); then (( a2 < b2 )); return; fi
    (( a3 <= b3 ))
}

main() {
    # Step 1: derive floor minor from HA tags for this PG_MAJOR
    local ha_tags
    if ! ha_tags="$(_resolver_fetch_ha_minor_tags 2>/dev/null)"; then
        _error "failed to fetch HA tags"
        exit 1
    fi

    # Extract unique X.Y minors from pg${PG_MAJOR}-tsX.Y lines (strip suffixes like -all, -oss).
    # grep exits 1 when there are no matches; use a grouped pipeline so the || true
    # applies to the whole chain and the output still flows to sort/head.
    local floor_minor
    floor_minor=$(
        { echo "$ha_tags" \
            | grep -E "^pg${PG_MAJOR}-ts[0-9]+\.[0-9]+$" \
            | sed "s/^pg${PG_MAJOR}-ts//" \
            | sort -t. -k1,1n -k2,2n \
            | head -1; } 2>/dev/null || true
    )

    if [[ -z "$floor_minor" ]]; then
        _error "no HA tags found for PG${PG_MAJOR}"
        exit 1
    fi

    # Step 2: fetch full TS release tags and filter
    local ts_tags
    if ! ts_tags="$(_resolver_fetch_ts_tags 2>/dev/null)"; then
        _error "failed to fetch TS tags"
        exit 1
    fi

    # Keep only bare semver X.Y.Z (no v-prefix, no -p0, no pre-release suffixes).
    # grep exits 1 when there are no matches; || true prevents set -e from
    # aborting before the explicit emptiness check below emits the actionable error.
    local versions
    versions=$(
        { echo "$ts_tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$'; } 2>/dev/null || true
    )

    if [[ -z "$versions" ]]; then
        _error "no valid semver tags found in TS releases"
        exit 1
    fi

    # Filter: keep versions where X.Y >= floor_minor
    local filtered=""
    while IFS= read -r ver; do
        local minor="${ver%.*}"  # strip patch → X.Y
        if _minor_ge "$minor" "$floor_minor"; then
            # Apply ceiling if set
            if [[ -n "$CEILING_VERSION" ]]; then
                if _semver_le "$ver" "$CEILING_VERSION"; then
                    filtered+="${ver}"$'\n'
                fi
            else
                filtered+="${ver}"$'\n'
            fi
        fi
    done <<< "$versions"

    if [[ -z "$filtered" ]]; then
        _error "no versions in range [${floor_minor}, ${CEILING_VERSION:-∞}]"
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

    printf '%s\n' "$json_array"
}

main "$@"
