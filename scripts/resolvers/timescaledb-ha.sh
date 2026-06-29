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

# RETAIN_COUNT: cap the window to the N most-recent versions.
# Must be a positive integer; any other value (unset, empty, non-numeric, zero,
# negative) falls back to the default of 12.
_DEFAULT_RETAIN_COUNT=12
_raw_retain="${RETAIN_COUNT:-}"
if [[ "$_raw_retain" =~ ^[1-9][0-9]*$ ]]; then
    _retain_count="$_raw_retain"
else
    _retain_count="$_DEFAULT_RETAIN_COUNT"
fi

# Escape a value for safe inclusion in a GHA workflow command.
# Prevents %/\r/\n in registry-derived or env-supplied values from injecting
# extra commands (e.g. ::stop-commands::, ::add-mask::) into the runner log.
_esc() { local s="$1"; s="${s//\%/%25}"; s="${s//$'\n'/%0A}"; s="${s//$'\r'/%0D}"; printf '%s' "$s"; }

# Emit error to stderr using GHA annotation format when available
_error() {
    echo "::error::$(_esc "${EXT_NAME}") resolver: $(_esc "$*")" >&2
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
    # CEILING_VERSION is required: an empty ceiling means the caller has no pinned
    # version, which is a configuration error. Fail fast rather than returning an
    # unbounded set that was never validated for build.
    if [[ -z "$CEILING_VERSION" ]]; then
        _error "CEILING_VERSION is required but was not set"
        exit 1
    fi

    # Fetch HA tags (one per line)
    local ha_tags
    if ! ha_tags="$(_resolver_fetch_ha_tags 2>/dev/null)"; then
        _error "failed to fetch HA tags"
        exit 1
    fi

    # Check whether the HA response contains any tags at all (before major filtering).
    # An empty or purely-whitespace response indicates a network failure, registry
    # outage, or an empty fixture — treat as a degraded (network-unavailable) state
    # and fall through to the ceiling-only degrade path.
    # A non-empty response that has no tags for PG_MAJOR indicates an unknown/
    # unsupported major — that is a configuration error, not a transient outage.
    # Use a here-string, NOT `echo "$ha_tags" | grep -q`: under `set -o pipefail`,
    # `grep -q` exits at the first match and closes the pipe, so under scheduler
    # pressure (e.g. CI `bats --jobs`) `echo` can take a SIGPIPE; pipefail then
    # propagates that as a pipeline failure, flipping this to false even when tags
    # ARE present. That mis-routed the resolver to the "empty HA response" branch
    # ~10% of the time under load (#823). A here-string is a single command — no
    # pipe, no SIGPIPE, no pipefail interaction.
    local ha_has_any_tags=false
    if grep -qE "^pg[0-9]+\.[0-9]+-ts[0-9]+" <<< "$ha_tags"; then
        ha_has_any_tags=true
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
        if [[ "$ha_has_any_tags" == "true" ]]; then
            # HA response has data for other PG majors but none for PG_MAJOR.
            # This indicates an unsupported/unknown major — configuration error.
            _error "no HA tags found for PG${PG_MAJOR}"
        else
            # HA response was empty or contained no recognisable tags at all
            # (network outage, registry unavailable, garbled response).
            # The resolver has lost its discovery basis and must NOT silently emit
            # [ceiling]: on a publish run that would drop every retained older
            # version, re-introducing the #558 breakage for existing databases.
            # The ceiling-only degrade belongs to the CALLER under LOCAL_ONLY or
            # PULL_ONLY recovery mode — not here.
            _error "HA response is empty or contains no recognisable tags — fail-closed (use LOCAL_ONLY/PULL_ONLY for recovery)"
        fi
        exit 1
    fi

    # De-duplicate (multiple pg minors may carry the same TS X.Y.Z).
    if [[ -n "$versions" ]]; then
        versions=$(echo "$versions" | sort -V -u)
    fi

    # Apply ceiling filter: drop any HA-discovered version that exceeds the ceiling.
    # HA tags are used ONLY to discover older retained versions. The ceiling is our
    # pinned build version — it does not need to appear in HA to be valid.
    local filtered=""
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        if _semver_le "$ver" "$CEILING_VERSION"; then
            filtered+="${ver}"$'\n'
        fi
    done <<< "$versions"

    # Unconditionally inject the ceiling into the set. This is idempotent when
    # the ceiling was already discovered from HA tags (sort -V -u deduplicates).
    # When HA has not yet published the ceiling (upstream publishing lag) or when
    # the HA response is empty/garbage (degrade path), the ceiling is still included
    # so that build-extensions.sh can always build the configured pinned version.
    filtered+="${CEILING_VERSION}"$'\n'

    # Sort oldest→newest, deduplicate
    local sorted
    sorted=$(echo "$filtered" | grep -v '^$' | sort -V -u)

    # Keep only the N most-recent versions (the highest N by version order).
    # The ceiling is already in the set and is always the last element after sort,
    # so it is guaranteed to be retained regardless of N.
    local windowed
    windowed=$(echo "$sorted" | tail -n "$_retain_count")

    local json_array
    json_array=$(echo "$windowed" | jq -Rsc 'split("\n") | map(select(length > 0))')

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
