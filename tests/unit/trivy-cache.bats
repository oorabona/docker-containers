#!/usr/bin/env bats

# Tests for the cross-subshell file cache in _fetch_trivy_alerts_once
# (helpers/trivy-utils.sh).
#
# All tests run offline: the `gh` CLI is overridden with a function that emits
# canned JSON (or fails loudly as a "poison" sentinel).

setup() {
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

    # Canned single-alert JSON — mimics `gh api --paginate` raw output which is
    # one JSON array per page, NOT an array-of-arrays.  The jq pipeline in
    # _fetch_trivy_alerts_once uses `jq -s '[.[][] | ...]'`, so the input must
    # be a flat array that jq -s wraps into a one-element outer array.
    CANNED_ALERTS='[{"rule":{"id":"CVE-2024-1234","severity":"critical","description":"Test CVE"},"most_recent_instance":{"category":"container-postgres-18-alpine-linux/amd64","created_at":"2026-04-30T10:00:00Z","location":{"path":"usr/lib/libfoo.so"}}}]'
    export CANNED_ALERTS

    # Reset in-process cache vars between tests (re-sourcing resets them too).
    unset _TRIVY_ALERTS_CACHE _TRIVY_SUMMARY_MAP TRIVY_CACHE_FILE
}

# ---------------------------------------------------------------------------
# Helper: install a gh mock that writes to a counter file on each invocation.
# Caller must set GH_COUNTER_FILE to an existing (possibly empty) file.
# ---------------------------------------------------------------------------
_install_gh_counter_mock() {
    gh() {
        local _n
        _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
        echo $(( _n + 1 )) | tee "${GH_COUNTER_FILE}" >/dev/null
        echo "${CANNED_ALERTS}"
    }
    export -f gh
}

# Helper: install a "poison" gh mock — any call appends to GH_COUNTER_FILE
# and exits non-zero so the test assertion catches it.
_install_gh_poison() {
    gh() {
        local _n
        _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
        echo $(( _n + 1 )) | tee "${GH_COUNTER_FILE}" >/dev/null
        echo "POISON: gh was called unexpectedly" >&2
        return 1
    }
    export -f gh
}

# ---------------------------------------------------------------------------

@test "1: TRIVY_CACHE_FILE unset — uses API path, no file I/O" {
    unset TRIVY_CACHE_FILE

    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    _install_gh_counter_mock
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    _fetch_trivy_alerts_once

    # API must have been called exactly once.
    local call_count
    call_count=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
    [[ "$call_count" -eq 1 ]]

    # In-memory map is populated.
    [[ -n "${_TRIVY_SUMMARY_MAP:-}" && "${_TRIVY_SUMMARY_MAP}" != "{}" ]]

    # No TRIVY_CACHE_FILE was set — nothing to write to.
    [[ -z "${TRIVY_CACHE_FILE:-}" ]]

    rm -f "${GH_COUNTER_FILE}"
}

@test "2: empty cache file falls through to API; file is written with JSON" {
    local cache_file
    cache_file=$(mktemp)
    # Truncate to zero bytes (empty = cache miss).
    : > "$cache_file"
    export TRIVY_CACHE_FILE="$cache_file"

    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    _install_gh_counter_mock
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    _fetch_trivy_alerts_once

    # API called (empty file is a cache miss).
    local call_count
    call_count=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
    [[ "$call_count" -eq 1 ]]

    # File was written with a non-empty JSON object.
    [[ -s "$cache_file" ]]
    local written
    written=$(cat -- "$cache_file")
    [[ -n "$written" ]]
    echo "$written" | jq -e 'type == "object"' >/dev/null 2>&1

    rm -f "$cache_file" "${GH_COUNTER_FILE}"
}

@test "3: populated cache file is read; poison gh is NEVER called" {
    local cache_file
    cache_file=$(mktemp)

    # Pre-populate with a compact valid summary map.
    local valid_map
    valid_map=$(jq -cn '{"container-postgres-18-alpine-linux/amd64":{"last_scan":"2026-04-30T10:00:00Z","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[]}}')
    echo "$valid_map" | tee "$cache_file" >/dev/null
    export TRIVY_CACHE_FILE="$cache_file"

    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    _install_gh_poison
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    # Direct call (not `run`) so _TRIVY_SUMMARY_MAP is visible in this scope.
    _fetch_trivy_alerts_once

    # Poison gh must NOT have been called (counter stays 0).
    local call_count
    call_count=$(cat "${GH_COUNTER_FILE}")
    [[ "$call_count" -eq 0 ]]

    # _TRIVY_SUMMARY_MAP must be a valid JSON object matching the file content.
    [[ -n "${_TRIVY_SUMMARY_MAP:-}" && "${_TRIVY_SUMMARY_MAP}" != "{}" ]]
    echo "${_TRIVY_SUMMARY_MAP}" | jq -e 'type == "object"' >/dev/null 2>&1

    # Structural check: the cached key must be present.
    local got_key
    got_key=$(echo "${_TRIVY_SUMMARY_MAP}" | jq -r 'keys[0]')
    [[ "$got_key" == "container-postgres-18-alpine-linux/amd64" ]]

    rm -f "$cache_file" "${GH_COUNTER_FILE}"
}

@test "4: corrupt cache (non-JSON) does NOT leave garbage in _TRIVY_SUMMARY_MAP" {
    local cache_file
    cache_file=$(mktemp)
    echo "not json" | tee "$cache_file" >/dev/null
    export TRIVY_CACHE_FILE="$cache_file"

    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    _install_gh_counter_mock
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    _fetch_trivy_alerts_once

    # After the call, _TRIVY_SUMMARY_MAP must be either empty, "{}", or valid JSON —
    # NEVER the raw "not json" string that would crash downstream jq.
    local map="${_TRIVY_SUMMARY_MAP:-}"
    if [[ -n "$map" && "$map" != "{}" ]]; then
        # If non-empty and non-sentinel, it must parse as a JSON object.
        echo "$map" | jq -e 'type == "object"' >/dev/null 2>&1
    fi

    rm -f "$cache_file" "${GH_COUNTER_FILE}"
}

@test "6: empty API result ({}) is cached cross-subshell — no second API call" {
    local cache_file
    cache_file=$(mktemp)
    : > "$cache_file"
    export TRIVY_CACHE_FILE="$cache_file"

    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    # Override CANNED_ALERTS with an empty array — API returns zero findings.
    export CANNED_ALERTS='[]'

    # First subshell: cache miss — must call gh, compute {} map, write to file.
    (
        gh() {
            local _n
            _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
            echo $(( _n + 1 )) | tee "${GH_COUNTER_FILE}" >/dev/null
            echo "${CANNED_ALERTS}"
        }
        export -f gh
        source "$PROJECT_ROOT/helpers/trivy-utils.sh"
        _fetch_trivy_alerts_once
        # Cache file must have been written (even though map is {}).
        [[ -s "$TRIVY_CACHE_FILE" ]]
        # Map inside this subshell must be a valid JSON object.
        echo "${_TRIVY_SUMMARY_MAP:-}" | jq -e 'type == "object"' >/dev/null 2>&1
    )

    # Second subshell: file is populated with {}; poison gh confirms API not called again.
    local map_in_second
    map_in_second=$(
        gh() {
            local _n
            _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
            echo $(( _n + 1 )) | tee "${GH_COUNTER_FILE}" >/dev/null
            echo "POISON: second subshell must not call gh" >&2
            return 1
        }
        export -f gh
        source "$PROJECT_ROOT/helpers/trivy-utils.sh"
        _fetch_trivy_alerts_once
        echo "${_TRIVY_SUMMARY_MAP:-}"
    )

    # API must have been called exactly once (first subshell only).
    local total_calls
    total_calls=$(cat "${GH_COUNTER_FILE}")
    [[ "$total_calls" -eq 1 ]]

    # Second subshell's map must be a valid JSON object (the cached {}).
    echo "${map_in_second}" | jq -e 'type == "object"' >/dev/null 2>&1

    rm -f "$cache_file" "${GH_COUNTER_FILE}"
}

@test "5: sibling subshells share one API fetch via TRIVY_CACHE_FILE" {
    local cache_file
    cache_file=$(mktemp)
    # Ensure cache file exists but is empty (mktemp creates a non-empty tmp sometimes on some OS).
    : > "$cache_file"
    export TRIVY_CACHE_FILE="$cache_file"

    # File-based counter survives subshell boundaries.
    # Starts empty; mocks use `|| echo 0` fallback so no explicit init needed.
    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    # First subshell: cache file is empty — must call gh and write to cache file.
    (
        gh() {
            local _n
            _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
            echo $(( _n + 1 )) | tee "${GH_COUNTER_FILE}" >/dev/null
            echo "${CANNED_ALERTS}"
        }
        export -f gh
        source "$PROJECT_ROOT/helpers/trivy-utils.sh"
        _fetch_trivy_alerts_once
        # Verify the cache file was written by this subshell.
        [[ -s "$TRIVY_CACHE_FILE" ]]
    )

    # Second subshell: cache file should now be populated; poison gh confirms
    # the API is NOT called again.
    (
        gh() {
            local _n
            _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
            echo $(( _n + 1 )) | tee "${GH_COUNTER_FILE}" >/dev/null
            echo "POISON: second subshell must not call gh" >&2
            return 1
        }
        export -f gh
        source "$PROJECT_ROOT/helpers/trivy-utils.sh"
        _fetch_trivy_alerts_once
        # _TRIVY_SUMMARY_MAP must be non-empty (read from file).
        [[ -n "${_TRIVY_SUMMARY_MAP:-}" && "${_TRIVY_SUMMARY_MAP}" != "{}" ]]
    )

    # API was called exactly once (first subshell only).
    local total_calls
    total_calls=$(cat "${GH_COUNTER_FILE}")
    [[ "$total_calls" -eq 1 ]]

    rm -f "$cache_file" "${GH_COUNTER_FILE}"
}
