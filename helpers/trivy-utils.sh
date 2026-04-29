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
        return 0
    }
    _TRIVY_ALERTS_CACHE="$raw"
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

    # --paginate emits a stream of arrays; jq -s '.[0]' reduces multi-page output.
    # Filter to the requested category, build summary.
    echo "$_TRIVY_ALERTS_CACHE" | jq -s --arg cat "$category" '
        # Flatten paginated arrays and filter to the target category
        [.[][] | select(.most_recent_instance.category == $cat)] as $alerts
        | {
            last_scan: (
                [$alerts[].most_recent_instance.created_at] | sort | reverse | .[0]
            ),
            counts: {
                critical: ([$alerts[] | select(.rule.severity == "critical")] | length),
                high:     ([$alerts[] | select(.rule.severity == "high")]     | length),
                medium:   ([$alerts[] | select(.rule.severity == "medium")]   | length),
                low:      ([$alerts[] | select(.rule.severity == "low")]      | length),
                info:     ([$alerts[] | select(
                                .rule.severity == "warning" or .rule.severity == "note"
                            )] | length)
            },
            top_advisories: (
                $alerts
                | sort_by(
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
    ' 2>/dev/null || echo "$_TRIVY_EMPTY"
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
