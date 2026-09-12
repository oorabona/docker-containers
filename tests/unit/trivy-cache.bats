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
    unset _TRIVY_SUMMARY_MAP TRIVY_CACHE_FILE
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

# Helper: install a failing gh mock whose stderr is supplied by
# GH_FAILURE_MESSAGE. Caller must set GH_COUNTER_FILE and GH_FAILURE_MESSAGE.
_install_gh_failure_mock() {
    gh() {
        local _n
        _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
        printf '%s\n' $(( _n + 1 )) > "${GH_COUNTER_FILE}"
        printf '%s\n' "${GH_FAILURE_MESSAGE}" >&2
        return 1
    }
    export -f gh
}

# ---------------------------------------------------------------------------

@test "TRIVY_CACHE_FILE unset — uses API path, no file I/O" {
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

@test "empty cache file falls through to API; file is written with JSON" {
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

@test "populated cache file is read; poison gh is NEVER called" {
    local cache_file
    cache_file=$(mktemp)

    # Pre-populate with a valid cache envelope carrying a compact summary map.
    local valid_map
    valid_map=$(jq -cn '{"container-postgres-18-alpine-linux/amd64":{"counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[]}}')
    jq -cn --argjson summary_map "$valid_map" \
        '{outcome: "ok", fetched_at: "2026-09-05T14:00:00Z", summary_map: $summary_map}' \
        | tee "$cache_file" >/dev/null
    export TRIVY_CACHE_FILE="$cache_file"

    GH_COUNTER_FILE=$(mktemp)
    export GH_COUNTER_FILE

    _install_gh_poison
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    # Direct call (not `run`) so _TRIVY_SUMMARY_MAP is visible in this scope.
    _fetch_trivy_alerts_once

    # Poison gh must NOT have been called (counter stays 0).
    local call_count
    call_count=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
    [[ "${call_count:-0}" -eq 0 ]]

    # _TRIVY_SUMMARY_MAP must be a valid JSON object matching the file content.
    [[ -n "${_TRIVY_SUMMARY_MAP:-}" && "${_TRIVY_SUMMARY_MAP}" != "{}" ]]
    echo "${_TRIVY_SUMMARY_MAP}" | jq -e 'type == "object"' >/dev/null 2>&1

    # Structural check: the cached key must be present.
    local got_key
    got_key=$(echo "${_TRIVY_SUMMARY_MAP}" | jq -r 'keys[0]')
    [[ "$got_key" == "container-postgres-18-alpine-linux/amd64" ]]

    rm -f "$cache_file" "${GH_COUNTER_FILE}"
}

@test "corrupt cache (non-JSON) does NOT leave garbage in _TRIVY_SUMMARY_MAP" {
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

@test "empty API result ({}) is cached cross-subshell — no second API call" {
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

@test "sibling subshells share one API fetch via TRIVY_CACHE_FILE" {
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

@test "security severity drives counts when SARIF level differs" {
    export CANNED_ALERTS='[
      {"rule":{"id":"HIGH-ERROR","severity":"error","security_severity_level":"high","description":"High finding"},"most_recent_instance":{"category":"container-test-1-linux/amd64","created_at":"2026-04-30T10:00:00Z","location":{"path":"usr/lib/high"}}},
      {"rule":{"id":"CRITICAL-WARNING","severity":"warning","security_severity_level":"critical","description":"Critical finding"},"most_recent_instance":{"category":"container-test-1-linux/amd64","created_at":"2026-04-30T10:01:00Z","location":{"path":"usr/lib/critical"}}},
      {"rule":{"id":"NOTE-NO-SECURITY-SEVERITY","severity":"note","security_severity_level":null,"description":"Informational finding"},"most_recent_instance":{"category":"container-test-1-linux/amd64","created_at":"2026-04-30T10:02:00Z","location":{"path":"usr/lib/info"}}}
    ]'

    _install_gh_counter_mock
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    _fetch_trivy_alerts_once

    local summary actual
    summary=$(jq -c '."container-test-1-linux/amd64"' <<<"$_TRIVY_SUMMARY_MAP")
    actual=$(jq -r '.counts.high' <<<"$summary")
    [[ "$actual" == "1" ]] || { echo "expected counts.high=1, got $actual" >&2; return 1; }
    actual=$(jq -r '.counts.critical' <<<"$summary")
    [[ "$actual" == "1" ]] || { echo "expected counts.critical=1, got $actual" >&2; return 1; }
    actual=$(jq -r '.counts.info' <<<"$summary")
    [[ "$actual" == "1" ]] || { echo "expected counts.info=1, got $actual" >&2; return 1; }
}

@test "every alert enters exactly one severity bucket" {
    export CANNED_ALERTS='[
      {"rule":{"id":"HIGH-ERROR","severity":"error","security_severity_level":"high","description":"High finding"},"most_recent_instance":{"category":"container-test-2-linux/amd64","created_at":"2026-04-30T10:00:00Z","location":{"path":"usr/lib/high"}}},
      {"rule":{"id":"CRITICAL-WARNING","severity":"warning","security_severity_level":"critical","description":"Critical finding"},"most_recent_instance":{"category":"container-test-2-linux/amd64","created_at":"2026-04-30T10:01:00Z","location":{"path":"usr/lib/critical"}}},
      {"rule":{"id":"MEDIUM-NOTE","severity":"note","security_severity_level":"medium","description":"Medium finding"},"most_recent_instance":{"category":"container-test-2-linux/amd64","created_at":"2026-04-30T10:02:00Z","location":{"path":"usr/lib/medium"}}},
      {"rule":{"id":"LOW-WARNING","severity":"warning","security_severity_level":"low","description":"Low finding"},"most_recent_instance":{"category":"container-test-2-linux/amd64","created_at":"2026-04-30T10:03:00Z","location":{"path":"usr/lib/low"}}},
      {"rule":{"id":"NULL-NOTE","severity":"note","security_severity_level":null,"description":"Missing severity finding"},"most_recent_instance":{"category":"container-test-2-linux/amd64","created_at":"2026-04-30T10:04:00Z","location":{"path":"usr/lib/null"}}},
      {"rule":{"id":"UNKNOWN-ERROR","severity":"error","security_severity_level":"unknown","description":"Unknown severity finding"},"most_recent_instance":{"category":"container-test-2-linux/amd64","created_at":"2026-04-30T10:05:00Z","location":{"path":"usr/lib/unknown"}}}
    ]'

    _install_gh_counter_mock
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    _fetch_trivy_alerts_once

    local summary bucket_total
    summary=$(jq -c '."container-test-2-linux/amd64"' <<<"$_TRIVY_SUMMARY_MAP")
    bucket_total=$(jq '[.counts.critical, .counts.high, .counts.medium, .counts.low, .counts.info] | add' <<<"$summary")
    [[ "$bucket_total" == "6" ]] || { echo "expected five-bucket total=6, got $bucket_total" >&2; return 1; }
    local info_count
    info_count=$(jq -r '.counts.info' <<<"$summary")
    [[ "$info_count" == "2" ]] || { echo "expected counts.info=2, got $info_count" >&2; return 1; }
}

@test "advisory severity label uses the count bucket rather than SARIF level" {
    export CANNED_ALERTS='[
      {"rule":{"id":"HIGH-ERROR","severity":"error","security_severity_level":"high","description":"High finding"},"most_recent_instance":{"category":"container-test-3-linux/amd64","created_at":"2026-04-30T10:00:00Z","location":{"path":"usr/lib/high"}}}
    ]'

    _install_gh_counter_mock
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    _fetch_trivy_alerts_once

    local actual
    actual=$(jq -r '."container-test-3-linux/amd64".top_advisories[] | select(.rule_id == "HIGH-ERROR") | .severity' \
        <<<"$_TRIVY_SUMMARY_MAP")
    [[ "$actual" == "high" ]] || { echo "expected HIGH-ERROR advisory severity=high, got ${actual:-empty}" >&2; return 1; }
}

@test "a transport failure containing authentication is retried three times" {
    unset TRIVY_CACHE_FILE
    GH_COUNTER_FILE="$BATS_TEST_TMPDIR/authentication-transport-calls"
    GH_FAILURE_MESSAGE='failed to contact authentication service'
    export GH_COUNTER_FILE GH_FAILURE_MESSAGE
    : > "$GH_COUNTER_FILE"

    _install_gh_failure_mock
    sleep() { :; }
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    _fetch_trivy_alerts_once

    [[ "$(cat "$GH_COUNTER_FILE")" -eq 3 ]]
    [[ "$_TRIVY_FETCH_OUTCOME" == "unavailable" ]]
    [[ "$_TRIVY_SUMMARY_MAP" == "{}" ]]
}

@test "every gh failure shape gets the same three attempts" {
    unset TRIVY_CACHE_FILE
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"
    sleep() { :; }

    local label message
    while IFS='|' read -r label message; do
        GH_COUNTER_FILE="$BATS_TEST_TMPDIR/${label}-calls"
        GH_FAILURE_MESSAGE="$message"
        export GH_COUNTER_FILE GH_FAILURE_MESSAGE
        : > "$GH_COUNTER_FILE"
        _TRIVY_SUMMARY_MAP=''
        _TRIVY_FETCH_OUTCOME=''
        _TRIVY_FETCHED_AT=''
        _install_gh_failure_mock

        _fetch_trivy_alerts_once

        [[ "$(cat "$GH_COUNTER_FILE")" -eq 3 ]] || {
            printf 'expected three calls for %s, got %s\n' "$label" "$(cat "$GH_COUNTER_FILE")" >&2
            return 1
        }
    done <<'FAILURES'
http-401|HTTP 401: Bad credentials
http-403|HTTP 403: Forbidden
http-429|HTTP 429: Too Many Requests
unresolvable-host|could not resolve host: api.github.com
FAILURES
}

@test "a malformed successful response is unavailable without a refetch" {
    unset TRIVY_CACHE_FILE
    GH_COUNTER_FILE="$BATS_TEST_TMPDIR/malformed-success-calls"
    export GH_COUNTER_FILE
    : > "$GH_COUNTER_FILE"

    gh() {
        local _n
        _n=$(cat "${GH_COUNTER_FILE}" 2>/dev/null || echo 0)
        printf '%s\n' $(( _n + 1 )) > "${GH_COUNTER_FILE}"
        printf '%s\n' '{"not":"a paginated alert array"}'
    }
    export -f gh
    source "$PROJECT_ROOT/helpers/trivy-utils.sh"

    _fetch_trivy_alerts_once

    [[ "$(cat "$GH_COUNTER_FILE")" -eq 1 ]]
    [[ "$_TRIVY_FETCH_OUTCOME" == "unavailable" ]]
    [[ "$_TRIVY_SUMMARY_MAP" == "{}" ]]
}
