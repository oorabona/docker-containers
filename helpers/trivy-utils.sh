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
    # Side-channel takes precedence over API when present. The Code Scanning
    # API indexes SARIF uploads asynchronously and can lag the in-pipeline
    # scan by minutes; the side-channel was written by THIS very pipeline run
    # and is therefore the authoritative source of truth for "what did this
    # scan produce". When the side-channel exists we synthesize the entire
    # summary from `_TRIVY_EMPTY` and overlay side-channel fields, so any stale
    # API data (e.g. old open advisories that the latest scan no longer flags)
    # is dropped. The SARIF upload is CRITICAL-only by policy (see
    # `/verify-images/`), so `alert_count` IS the critical count by definition;
    # high/medium/low/info stay zero and top_advisories stays empty.
    if [[ -n "$sc_last_scan" ]]; then
        local sc_alert_count
        sc_alert_count=$(jq -r '.alert_count // 0' "$sc_file" 2>/dev/null || echo 0)
        echo "$_TRIVY_EMPTY" | jq \
            --arg ls "$sc_last_scan" \
            --argjson ac "$sc_alert_count" \
            '.last_scan = $ls | .counts.critical = $ac'
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

    echo "All self-tests passed."
fi
