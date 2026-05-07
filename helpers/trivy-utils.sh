#!/usr/bin/env bash

# Trivy vulnerability summary helpers for docker-containers dashboard
# Queries the GitHub Code Scanning Alerts API (Trivy SARIF uploads) to surface
# per-variant CVE counts and top advisories.
#
# Trivy SARIF categories have the format:
#   container-<name>-<tag>-<platform>
# e.g.: container-postgres-18-alpine-linux/amd64
#
# Requires: gh CLI (authenticated in CI via GITHUB_TOKEN), jq

TRIVY_UTILS_OWNER_REPO="oorabona/docker-containers"

# Avoid re-sourcing logging.sh colors (idempotent guard)
if [[ -z "${_LOGGING_LOADED:-}" ]]; then
    _SCRIPT_DIR_TRIVY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$_SCRIPT_DIR_TRIVY/logging.sh"
    _LOGGING_LOADED=1
fi

# Empty Trivy summary emitted when data is unavailable
_TRIVY_EMPTY='{"last_scan":null,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[]}'

# In-process cache for the full alerts list — populated once per dashboard run.
# Avoids one paginated gh API call per variant (21 calls for postgres alone).
_TRIVY_ALERTS_CACHE=""

# Precomputed per-category summary map (JSON object) — built once by _fetch_trivy_alerts_once.
# get_trivy_summary does a cheap jq key-lookup against this map instead of re-processing
# the full alerts list on every call.
_TRIVY_SUMMARY_MAP=""

# _fetch_trivy_alerts_once
# Populates _TRIVY_ALERTS_CACHE and _TRIVY_SUMMARY_MAP on first call; subsequent
# calls are no-ops. On auth/network failure, sets caches to empty sentinels and
# logs a warning once.
#
# Cross-subshell cache: generate-dashboard.sh runs collect_variant_json in $()
# subshells; the in-memory variables are lost when each subshell exits. When
# TRIVY_CACHE_FILE is set, the computed map is persisted to disk so sibling
# subshells can read it without re-hitting the API.
# NOTE: No locking is needed here — dashboard generation is single-threaded
# (subshells are sequential, not concurrent).
_fetch_trivy_alerts_once() {
    # Already populated in this shell? Done.
    [[ -n "${_TRIVY_ALERTS_CACHE:-}" ]] && return 0

    # Cross-subshell cache — populated by an earlier subshell of this run.
    if [[ -n "${TRIVY_CACHE_FILE:-}" && -s "${TRIVY_CACHE_FILE}" ]]; then
        local _cached_map
        _cached_map=$(cat -- "${TRIVY_CACHE_FILE}" 2>/dev/null || true)
        # Validate: must be a non-empty JSON object.
        if [[ -n "${_cached_map}" ]] \
            && echo "${_cached_map}" | jq -e 'type == "object"' >/dev/null 2>&1; then
            _TRIVY_SUMMARY_MAP="${_cached_map}"
            # Synthesise a non-empty sentinel so the in-shell guard fires next call.
            _TRIVY_ALERTS_CACHE="[cached]"
            return 0
        fi
        # Fall through: file present but empty or non-JSON object — fetch fresh.
    fi

    local raw
    raw=$(gh api --paginate \
        "repos/${TRIVY_UTILS_OWNER_REPO}/code-scanning/alerts?tool_name=Trivy&state=open&per_page=100" \
        2>/dev/null) || {
        log_warning "gh api code-scanning/alerts failed (auth or network) — Trivy summaries will be empty"
        _TRIVY_ALERTS_CACHE="[]"
        _TRIVY_SUMMARY_MAP="{}"
        return 0
    }
    _TRIVY_ALERTS_CACHE="$raw"

    # Precompute per-category summaries in ONE jq pass so get_trivy_summary is a cheap lookup.
    # --paginate emits a stream of arrays; jq -s flattens them before grouping.
    _TRIVY_SUMMARY_MAP=$(echo "$_TRIVY_ALERTS_CACHE" | jq -s '
        [.[][] | select(.most_recent_instance.category != null)]
        | group_by(.most_recent_instance.category)
        | map({
            key: .[0].most_recent_instance.category,
            value: {
              last_scan: ([.[].most_recent_instance.created_at] | sort | reverse | .[0]),
              counts: {
                critical: (map(select(.rule.severity == "critical")) | length),
                high:     (map(select(.rule.severity == "high"))     | length),
                medium:   (map(select(.rule.severity == "medium"))   | length),
                low:      (map(select(.rule.severity == "low"))      | length),
                info:     (map(select(.rule.severity == "warning" or .rule.severity == "note")) | length)
              },
              top_advisories: (
                sort_by(
                  if   .rule.severity == "critical" then 0
                  elif .rule.severity == "high"     then 1
                  elif .rule.severity == "medium"   then 2
                  elif .rule.severity == "low"      then 3
                  else 4 end
                )
                | .[0:5]
                | map({
                    rule_id:      .rule.id,
                    severity:     .rule.severity,
                    title:        .rule.description,
                    package_name: ((.most_recent_instance.location.path // "") | split("/") | .[-1])
                  })
              )
            }
          })
        | from_entries
    ' 2>/dev/null) || _TRIVY_SUMMARY_MAP="{}"

    # Persist to file cache for sibling subshells. Write failure is non-fatal.
    # Reaching here always means the API call succeeded (failure path returns early above).
    if [[ -n "${TRIVY_CACHE_FILE:-}" && -n "${_TRIVY_SUMMARY_MAP}" ]]; then
        printf '%s' "${_TRIVY_SUMMARY_MAP}" > "${TRIVY_CACHE_FILE}" 2>/dev/null || true
    fi
}

# get_trivy_summary <category>
# Returns a JSON summary for the given SARIF category using the cached alerts list:
#   {
#     "last_scan": "<ISO8601 or null>",
#     "counts": {"critical": N, "high": N, "medium": N, "low": N, "info": N},
#     "top_advisories": [
#       {"rule_id": "...", "severity": "...", "title": "...", "package_name": "..."},
#       ...  (up to 5, sorted critical→high→medium→low)
#     ]
#   }
# On auth/network failure: returns the empty form.
# Callers must not crash when fields are null or arrays are empty.
get_trivy_summary() {
    local category="$1"
    if [[ -z "$category" ]]; then
        echo "$_TRIVY_EMPTY"
        return 0
    fi

    _fetch_trivy_alerts_once

    # --- Side-channel: read scan-history file if available ---
    # Category format: container-<name>-<tag>-<platform>  (platform contains '/')
    # e.g. container-postgres-18-alpine-linux/amd64
    # Strip the leading "container-" prefix, then replace '/' with '-' for the filename.
    # Resolve under the parent script's SCRIPT_DIR (the repo root) when set —
    # generate-dashboard.sh works from any cwd, so this lookup must too. Fall
    # back to cwd when sourced standalone (e.g. self-test).
    local sc_root sc_relative sc_file sc_last_scan
    sc_root="${SCRIPT_DIR:-.}"
    sc_relative="${category#container-}"         # postgres-18-alpine-linux/amd64
    sc_file="$sc_root/.trivy-scan-history/${sc_relative//\//-}.json"   # postgres-18-alpine-linux-amd64.json
    sc_last_scan=""
    if [[ -f "$sc_file" ]]; then
        sc_last_scan=$(jq -r '.last_scan // empty' "$sc_file" 2>/dev/null || true)
    fi

    # Fast lookup: the full jq processing was done once in _fetch_trivy_alerts_once.
    # _TRIVY_SUMMARY_MAP is a JSON object keyed by SARIF category.
    local result
    if [[ -z "${_TRIVY_SUMMARY_MAP:-}" || "$_TRIVY_SUMMARY_MAP" == "{}" ]]; then
        result=""
    else
        result=$(echo "$_TRIVY_SUMMARY_MAP" | jq --arg cat "$category" '.[$cat] // empty' 2>/dev/null)
    fi

    # Defensive: ensure result is a JSON object before emitting. If the cache is
    # in a partial/corrupt state (e.g. subshell raced an API outage and stored
    # an array), returning a non-object here would crash downstream jq with
    # "Cannot index array with string 'last_scan'", silently blanking the
    # entire variant entry in containers.yml. Force the empty form on any
    # type mismatch.
    # Option C overlay model (see ADR-008): the Code Scanning API indexes SARIF
    # uploads asynchronously and can lag the in-pipeline scan by minutes; the
    # side-channel was written by THIS very pipeline run and is authoritative for
    # "what did this scan produce". When the side-channel exists we overlay its
    # fields onto the API result (base), so the dashboard shows THIS pipeline's
    # fresh counts while preserving top_advisories from the API. The API result
    # is the base when it is a valid object; _TRIVY_EMPTY is the fallback.
    # New scan-history files (Option C, post-ADR-008) carry a `counts` object
    # covering all severities; legacy files carry only `alert_count` (= critical
    # count by old CRITICAL-only policy). Back-compat: absence of `counts` in
    # the side-channel triggers the legacy path which sets only counts.critical.
    if [[ -n "$sc_last_scan" ]]; then
        local base
        if [[ -n "$result" ]] && echo "$result" | jq -e 'type == "object"' >/dev/null 2>&1; then
            base="$result"
        else
            base="$_TRIVY_EMPTY"
        fi

        local sc_counts sc_alert_count
        sc_counts=$(jq -c '.counts // empty' "$sc_file" 2>/dev/null || true)
        sc_alert_count=$(jq -r '.alert_count // 0' "$sc_file" 2>/dev/null || echo 0)

        if [[ -n "$sc_counts" ]]; then
            # New format (Option C): partial-overlay merge onto base.
            # (.counts + $sc) merges objects: keys present in $sc override the
            # corresponding keys in base; keys absent from $sc are preserved from
            # base (API). Today's writer always emits all 5 keys, so partial
            # overlay is forward-compat for future writers that may emit subsets
            # (e.g. only counts.critical). Side-channel is authoritative only for
            # the keys it supplies; remaining keys fall back to the API result.
            echo "$base" | jq \
                --arg ls "$sc_last_scan" \
                --argjson sc "$sc_counts" \
                '.last_scan = $ls | .counts = (.counts + $sc)'
        else
            # Legacy format (pre-Option-C): only alert_count = critical count.
            echo "$base" | jq \
                --arg ls "$sc_last_scan" \
                --argjson ac "$sc_alert_count" \
                '.last_scan = $ls | .counts.critical = $ac'
        fi
        return 0
    fi

    # No side-channel data — fall back to API result (or empty form on failure).
    if [[ -z "$result" ]] || ! echo "$result" | jq -e 'type == "object"' >/dev/null 2>&1; then
        [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
            echo "[debug] trivy summary empty for category=$category (no side-channel file, no API result)" >&2
        echo "$_TRIVY_EMPTY"
        return 0
    fi

    # Re-validate after potential mutation
    if [[ -z "$result" ]] || ! echo "$result" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "$_TRIVY_EMPTY"
    else
        echo "$result"
    fi
}

# build_trivy_category <container> <tag> <platform>
# Produces the SARIF category string used by the build-container action:
#   container-<name>-<tag>-<platform>
# e.g.: container-postgres-18-alpine-linux/amd64
# <platform> should be the full platform string (linux/amd64 or linux/arm64).
build_trivy_category() {
    local container="$1" tag="$2" platform="$3"
    echo "container-${container}-${tag}-${platform}"
}

# ---------------------------------------------------------------------------
# Self-test (runs only when script is executed directly: bash helpers/trivy-utils.sh)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail

    echo "Running trivy-utils self-test..."

    # Create a temporary scan-history directory and fake file
    _test_dir=$(mktemp -d)
    trap 'rm -rf "$_test_dir"' EXIT

    mkdir -p "$_test_dir/.trivy-scan-history"
    printf '{"last_scan":"2026-04-30T10:00:00Z","alert_count":0,"status":"clean"}\n' \
        > "$_test_dir/.trivy-scan-history/container-fake-1.0-linux-amd64.json"

    # Change into the temp dir so the relative path ".trivy-scan-history/..." resolves
    pushd "$_test_dir" > /dev/null

    # Simulate empty API: override the cache map so _fetch_trivy_alerts_once is a no-op
    _TRIVY_ALERTS_CACHE="[]"
    _TRIVY_SUMMARY_MAP="{}"

    result=$(get_trivy_summary "container-container-fake-1.0-linux/amd64")

    popd > /dev/null

    last_scan=$(echo "$result" | jq -r '.last_scan')

    if [[ "$last_scan" == "2026-04-30T10:00:00Z" ]]; then
        echo "PASS test-1: last_scan = $last_scan (non-null, correct value)"
    else
        echo "FAIL test-1: expected last_scan=2026-04-30T10:00:00Z, got: $last_scan"
        echo "Full result: $result"
        exit 1
    fi
    critical=$(echo "$result" | jq -r '.counts.critical')
    if [[ "$critical" == "0" ]]; then
        echo "PASS test-1: counts.critical = 0 (clean scan, correct)"
    else
        echo "FAIL test-1: expected counts.critical=0 for clean scan, got: $critical"
        echo "Full result: $result"
        exit 1
    fi

    # Test 2: side-channel has alert_count=3 (dirty CRITICAL scan), API map is empty.
    # Expected: last_scan non-null AND counts.critical == 3.
    printf '{"last_scan":"2026-04-30T11:00:00Z","alert_count":3,"status":"dirty","scanned_severity":"CRITICAL"}\n' \
        > "$_test_dir/.trivy-scan-history/container-dirty-2.0-linux-amd64.json"

    pushd "$_test_dir" > /dev/null

    _TRIVY_ALERTS_CACHE="[]"
    _TRIVY_SUMMARY_MAP="{}"

    result2=$(get_trivy_summary "container-container-dirty-2.0-linux/amd64")

    popd > /dev/null

    last_scan2=$(echo "$result2" | jq -r '.last_scan')
    critical2=$(echo "$result2" | jq -r '.counts.critical')

    if [[ "$last_scan2" == "2026-04-30T11:00:00Z" ]]; then
        echo "PASS test-2: last_scan = $last_scan2 (non-null, correct value)"
    else
        echo "FAIL test-2: expected last_scan=2026-04-30T11:00:00Z, got: $last_scan2"
        echo "Full result: $result2"
        exit 1
    fi
    if [[ "$critical2" == "3" ]]; then
        echo "PASS test-2: counts.critical = $critical2 (side-channel alert_count propagated correctly)"
    else
        echo "FAIL test-2: expected counts.critical=3, got: $critical2"
        echo "Full result: $result2"
        exit 1
    fi

    # Test 3: side-channel with new Option C shape (counts object), API map empty.
    # Expected: all five severity counts propagated from side-channel.
    printf '{"last_scan":"2026-05-07T09:00:00Z","alert_count":11,"status":"dirty","counts":{"critical":5,"high":3,"medium":2,"low":1,"info":0},"scanned_severities":["UNKNOWN","LOW","MEDIUM","HIGH","CRITICAL"]}\n' \
        > "$_test_dir/.trivy-scan-history/container-allsev-3.0-linux-amd64.json"

    pushd "$_test_dir" > /dev/null

    _TRIVY_ALERTS_CACHE="[]"
    _TRIVY_SUMMARY_MAP="{}"

    result3=$(get_trivy_summary "container-container-allsev-3.0-linux/amd64")

    popd > /dev/null

    critical3=$(echo "$result3" | jq -r '.counts.critical')
    high3=$(echo "$result3" | jq -r '.counts.high')
    medium3=$(echo "$result3" | jq -r '.counts.medium')
    low3=$(echo "$result3" | jq -r '.counts.low')

    if [[ "$critical3" == "5" && "$high3" == "3" && "$medium3" == "2" && "$low3" == "1" ]]; then
        echo "PASS test-3: all severity counts propagated (critical=$critical3 high=$high3 medium=$medium3 low=$low3)"
    else
        echo "FAIL test-3: expected critical=5 high=3 medium=2 low=1, got: critical=$critical3 high=$high3 medium=$medium3 low=$low3"
        echo "Full result: $result3"
        exit 1
    fi

    # Test 4: API map has counts for category X; side-channel for X has new-format counts.
    # Side-channel is authoritative for ALL severities (full-object replace of .counts).
    # Expected: side-channel counts win entirely; last_scan from side-channel (fresh).
    mkdir -p "$_test_dir/.trivy-scan-history"
    printf '{"last_scan":"2026-05-07T10:00:00Z","alert_count":1,"status":"dirty","counts":{"critical":1,"high":0,"medium":0,"low":0,"info":0},"scanned_severities":["UNKNOWN","LOW","MEDIUM","HIGH","CRITICAL"]}\n' \
        > "$_test_dir/.trivy-scan-history/container-apiovrl-4.0-linux-amd64.json"

    pushd "$_test_dir" > /dev/null

    _TRIVY_ALERTS_CACHE="[]"
    # Inject API result for category X (simulates pre-existing Code Scanning data)
    _TRIVY_SUMMARY_MAP=$(jq -nc '{
        "container-container-apiovrl-4.0-linux/amd64": {
            "last_scan": "2026-05-06T08:00:00Z",
            "counts": {"critical": 0, "high": 4, "medium": 2, "low": 0, "info": 0},
            "top_advisories": [{"rule_id":"CVE-2025-0001","severity":"high","title":"test","package_name":"libfoo"}]
        }
    }')

    result4=$(get_trivy_summary "container-container-apiovrl-4.0-linux/amd64")

    popd > /dev/null

    critical4=$(echo "$result4" | jq -r '.counts.critical')
    high4=$(echo "$result4" | jq -r '.counts.high')
    last_scan4=$(echo "$result4" | jq -r '.last_scan')

    if [[ "$critical4" == "1" && "$high4" == "0" && "$last_scan4" == "2026-05-07T10:00:00Z" ]]; then
        echo "PASS test-4: side-channel counts override API entirely (critical=$critical4 high=$high4 last_scan=$last_scan4)"
    else
        echo "FAIL test-4: expected critical=1 high=0 last_scan=2026-05-07T10:00:00Z"
        echo "  got: critical=$critical4 high=$high4 last_scan=$last_scan4"
        echo "Full result: $result4"
        exit 1
    fi

    # Test 5: no side-channel file for category Y, but API map has counts for Y.
    # Expected: API counts surface unchanged.
    pushd "$_test_dir" > /dev/null

    _TRIVY_ALERTS_CACHE="[]"
    _TRIVY_SUMMARY_MAP=$(jq -nc '{
        "container-container-apionly-5.0-linux/amd64": {
            "last_scan": "2026-05-07T07:00:00Z",
            "counts": {"critical": 0, "high": 2, "medium": 3, "low": 1, "info": 0},
            "top_advisories": []
        }
    }')

    result5=$(get_trivy_summary "container-container-apionly-5.0-linux/amd64")

    popd > /dev/null

    high5=$(echo "$result5" | jq -r '.counts.high')
    medium5=$(echo "$result5" | jq -r '.counts.medium')

    if [[ "$high5" == "2" && "$medium5" == "3" ]]; then
        echo "PASS test-5: API-only category returns API counts unchanged (high=$high5 medium=$medium5)"
    else
        echo "FAIL test-5: expected high=2 medium=3 from API, got: high=$high5 medium=$medium5"
        echo "Full result: $result5"
        exit 1
    fi

    # Test 6: partial side-channel counts (only critical) — API high/medium MUST be preserved.
    # Locks the partial-overlay merge contract: keys absent from side-channel are kept from API.
    mkdir -p "$_test_dir/.trivy-scan-history"
    printf '{"last_scan":"2026-05-07T12:00:00Z","alert_count":1,"status":"dirty","counts":{"critical":1}}\n' \
        > "$_test_dir/.trivy-scan-history/container-partial-6.0-linux-amd64.json"

    pushd "$_test_dir" > /dev/null

    _TRIVY_ALERTS_CACHE="[]"
    _TRIVY_SUMMARY_MAP=$(jq -nc '{
        "container-container-partial-6.0-linux/amd64": {
            "last_scan": "2026-05-06T08:00:00Z",
            "counts": {"critical": 0, "high": 4, "medium": 2, "low": 0, "info": 0},
            "top_advisories": []
        }
    }')

    result6=$(get_trivy_summary "container-container-partial-6.0-linux/amd64")

    popd > /dev/null

    critical6=$(echo "$result6" | jq -r '.counts.critical')
    high6=$(echo "$result6" | jq -r '.counts.high')
    medium6=$(echo "$result6" | jq -r '.counts.medium')
    last_scan6=$(echo "$result6" | jq -r '.last_scan')

    if [[ "$critical6" == "1" && "$high6" == "4" && "$medium6" == "2" && "$last_scan6" == "2026-05-07T12:00:00Z" ]]; then
        echo "PASS test-6: partial side-channel overlay (critical=$critical6 overridden; high=$high6 medium=$medium6 preserved from API; last_scan=$last_scan6)"
    else
        echo "FAIL test-6: expected critical=1 high=4 medium=2 last_scan=2026-05-07T12:00:00Z"
        echo "  got: critical=$critical6 high=$high6 medium=$medium6 last_scan=$last_scan6"
        echo "Full result: $result6"
        exit 1
    fi

    echo "All self-tests passed."
fi
