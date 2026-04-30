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
# Populates _TRIVY_ALERTS_CACHE on first call; subsequent calls are no-ops.
# On auth/network failure, sets cache to "[]" and logs a warning once.
_fetch_trivy_alerts_once() {
    [[ -n "$_TRIVY_ALERTS_CACHE" ]] && return 0
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

    # Fast lookup: the full jq processing was done once in _fetch_trivy_alerts_once.
    # _TRIVY_SUMMARY_MAP is a JSON object keyed by SARIF category.
    if [[ -z "${_TRIVY_SUMMARY_MAP:-}" || "$_TRIVY_SUMMARY_MAP" == "{}" ]]; then
        echo "$_TRIVY_EMPTY"
        return 0
    fi

    local result
    result=$(echo "$_TRIVY_SUMMARY_MAP" | jq --arg cat "$category" '.[$cat] // empty' 2>/dev/null)

    # Defensive: ensure result is a JSON object before emitting. If the cache is
    # in a partial/corrupt state (e.g. subshell raced an API outage and stored
    # an array), returning a non-object here would crash downstream jq with
    # "Cannot index array with string 'last_scan'", silently blanking the
    # entire variant entry in containers.yml. Force the empty form on any
    # type mismatch.
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
