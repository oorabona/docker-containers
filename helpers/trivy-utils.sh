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

# trivy_rfc3339_jq
#
# Emits the shared jq definition for RFC3339 date-time syntax and calendar
# validity.  It deliberately accepts -00:00 for record validation; that zone
# states an unknown local offset, so freshness comparison callers must not treat
# it as establishing an instant.
trivy_rfc3339_jq() {
    cat <<'JQ'
def rfc3339_parts:
  [try (
     capture("^(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})(?<fraction>\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$")
     | . as $parts
     | (.year | tonumber) as $year
     | (.month | tonumber) as $month
     | (.day | tonumber) as $day
     | (.hour | tonumber) as $hour
     | (.minute | tonumber) as $minute
     | (.second | tonumber) as $second
     | (if .zone == "Z" then 0 else (.zone[1:3] | tonumber) end) as $zone_hour
     | (if .zone == "Z" then 0 else (.zone[4:6] | tonumber) end) as $zone_minute
     | [31,
        (if (($year % 4 == 0 and $year % 100 != 0) or $year % 400 == 0) then 29 else 28 end),
        31,30,31,30,31,31,30,31,30,31][$month - 1] as $days_in_month
     | if $month >= 1 and $month <= 12
          and $day >= 1 and $day <= $days_in_month
          and $hour <= 23 and $minute <= 59 and $second <= 60
          and $zone_hour <= 23 and $zone_minute <= 59
       then $parts
       else false
       end
  ) catch false]
  | if length == 1 then .[0] else false end;
def rfc3339:
  rfc3339_parts | type == "object";
JQ
}

# trivy_scan_history_record <file>
#
# Normalizes the trust decision for a persisted Trivy scan-history record.  This
# is intentionally the sole validator for the side-channel: producers, cache
# merges, and the dashboard reader must not grow subtly different definitions
# of a usable record.  It always writes one object with this shape:
#   {usable, reason, last_scan, counts, alert_count}
#
# A legacy record has no `counts` member and uses alert_count as the old
# CRITICAL-only count.  New-format records must carry every normalized bucket
# and agree with their alert_count/status.
trivy_scan_history_record() {
    local scan_file="${1:-}"
    local normalized

    if [[ -z "$scan_file" || ! -f "$scan_file" ]]; then
        printf '%s\n' '{"usable":false,"reason":"no-file","last_scan":"","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
        return 0
    fi

    # jq normally consumes a stream of JSON values.  Slurp first so a file
    # containing two otherwise-valid records is rejected as one malformed
    # history file rather than leaking two summaries into a later --argjson.
    if ! normalized=$(jq -c -s "$(trivy_rfc3339_jq)"'
        def empty_counts:
          {critical: 0, high: 0, medium: 0, low: 0, info: 0};
        def reject($reason):
          {usable: false, reason: $reason, last_scan: "", counts: empty_counts, alert_count: 0};
        def nonnegative_safe_integer:
          type == "number" and isfinite and floor == . and . >= 0 and . <= 9007199254740991;
        def normalized_record:
          . as $normalized
          | ($normalized | type == "object")
          and ($normalized | (keys | sort) == ["alert_count", "counts", "last_scan", "reason", "usable"])
          and ($normalized.usable | type == "boolean")
          and ($normalized.reason | type == "string")
          and ($normalized.last_scan | type == "string")
          and ($normalized.alert_count | nonnegative_safe_integer)
          and ($normalized.counts | type == "object")
          and ($normalized.counts | (keys | sort) == ["critical", "high", "info", "low", "medium"])
          and ([$normalized.counts.critical, $normalized.counts.high, $normalized.counts.medium,
                $normalized.counts.low, $normalized.counts.info] | all(.[]; nonnegative_safe_integer));
        (
          if length != 1 or (.[0] | type != "object") then
            reject("malformed-record")
          else
            .[0] as $record
            | if ($record | has("last_scan") | not) or $record.last_scan == "" then
                reject("missing-timestamp")
              elif ($record.last_scan | type != "string") or ($record.last_scan | rfc3339 | not) then
                reject("malformed-record")
              elif ($record.status != "clean" and $record.status != "dirty") then
                reject("rejected-status")
              elif ($record | has("counts")) then
                if ($record.counts | type != "object")
                  or (all(["critical", "high", "medium", "low", "info"][];
                      . as $count_key | ($record.counts[$count_key] | nonnegative_safe_integer)) | not) then
                  reject("malformed-record")
                else
                  {critical: $record.counts.critical, high: $record.counts.high,
                   medium: $record.counts.medium, low: $record.counts.low,
                   info: $record.counts.info} as $counts
                  | ($counts.critical + $counts.high + $counts.medium + $counts.low + $counts.info) as $sum
                  | if ($record.alert_count | nonnegative_safe_integer | not)
                    or $record.alert_count != $sum
                    or ($record.status == "clean" and $sum != 0)
                    or ($record.status == "dirty" and $sum <= 0) then
                      reject("malformed-record")
                    else
                      {usable: true, reason: "", last_scan: $record.last_scan,
                       counts: $counts, alert_count: $record.alert_count}
                    end
                end
              elif ($record.alert_count | nonnegative_safe_integer)
                and (($record.status == "clean" and $record.alert_count == 0)
                     or ($record.status == "dirty" and $record.alert_count > 0)) then
                {usable: true, reason: "legacy", last_scan: $record.last_scan,
                 counts: {critical: $record.alert_count, high: 0, medium: 0, low: 0, info: 0},
                 alert_count: $record.alert_count}
              else
                reject("malformed-record")
              end
          end
        )
        | if normalized_record then . else reject("malformed-record") end
    ' "$scan_file" 2>/dev/null); then
        normalized='{"usable":false,"reason":"malformed-record","last_scan":"","counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"alert_count":0}'
    fi

    printf '%s\n' "$normalized"
}

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
    local sc_root sc_relative sc_file sc_last_scan sc_usable sc_reason sc_record
    sc_root="${SCRIPT_DIR:-.}"
    sc_relative="${category#container-}"         # postgres-18-alpine-linux/amd64
    sc_file="$sc_root/.trivy-scan-history/${sc_relative//\//-}.json"   # postgres-18-alpine-linux-amd64.json
    sc_last_scan=""
    sc_usable=false
    sc_reason="no-file"
    # One normalized decision for every history record.  Do not add ad-hoc
    # field probes here: cache merges use this same predicate, and agreeing on
    # usability matters more than accepting a merely timestamped JSON object.
    sc_record=$(trivy_scan_history_record "$sc_file")
    IFS=$'\x1f' read -r sc_usable sc_reason sc_last_scan < <(
        jq -r '[.usable, .reason, .last_scan] | map(tostring) | join("\u001f")' <<<"$sc_record"
    )

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
    # uploads asynchronously and can lag the in-pipeline scan by minutes. The
    # side-channel is therefore authoritative for what THIS pipeline produced
    # only when it is demonstrably at least as recent as the API result. When it
    # is usable we overlay its fields onto the API result (base), preserving
    # top_advisories. An indeterminate comparison keeps the API result: the
    # persisted record is the source whose freshness needs proving.
    # The API result is the base when it is a valid object; _TRIVY_EMPTY is the
    # fallback.
    # New scan-history files (Option C, post-ADR-008) carry a `counts` object
    # covering all severities; legacy files carry only `alert_count` (= critical
    # count by old CRITICAL-only policy). Back-compat: absence of `counts` in
    # the side-channel triggers the legacy path which sets only counts.critical.
    if [[ "$sc_usable" == true ]]; then
        local base has_api_result=false
        if [[ -n "$result" ]] && echo "$result" | jq -e 'type == "object"' >/dev/null 2>&1; then
            base="$result"
            has_api_result=true
        else
            base="$_TRIVY_EMPTY"
        fi

        # With no API entry there is nothing to protect or compare, so the
        # usable side-channel record remains the only available evidence.
        if [[ "$has_api_result" == true ]]; then
            # Compare instants rather than their RFC3339 spellings: a record writer
            # emits +00:00 while GitHub emits Z, for which string ordering is wrong.
            # The side-channel timestamp was already accepted by trivy_scan_history_record.
            # For the API, use that validator's exact RFC3339 grammar before date(1)
            # converts its offset to an epoch. Timestamp parsing or conversion failure
            # makes freshness unknown, which must retain the API result.
            local api_last_scan api_parts sc_parts api_zone sc_zone api_fraction sc_fraction api_epoch sc_epoch date_error comparison_width
            api_last_scan=$(jq -r 'if .last_scan | type == "string" then .last_scan else empty end' <<<"$base")
            api_parts=$(jq -cn --arg timestamp "$api_last_scan" "$(trivy_rfc3339_jq)"'
                $timestamp | rfc3339_parts
            ' 2>/dev/null)
            if [[ -z "$api_parts" ]] || ! jq -e 'type == "object"' <<<"$api_parts" >/dev/null 2>&1; then
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (API timestamp is not RFC3339: $api_last_scan)" >&2
                echo "$base"
                return 0
            fi

            sc_parts=$(jq -cn --arg timestamp "$sc_last_scan" "$(trivy_rfc3339_jq)"'
                $timestamp | rfc3339_parts
            ' 2>/dev/null)
            if [[ -z "$sc_parts" ]] || ! jq -e 'type == "object"' <<<"$sc_parts" >/dev/null 2>&1; then
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (record timestamp is not RFC3339: $sc_last_scan)" >&2
                echo "$base"
                return 0
            fi

            if ! api_zone=$(jq -er '.zone' <<<"$api_parts") \
                || ! sc_zone=$(jq -er '.zone' <<<"$sc_parts"); then
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (timestamp zone extraction failed)" >&2
                echo "$base"
                return 0
            fi
            if [[ "$api_zone" == "-00:00" || "$sc_zone" == "-00:00" ]]; then
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (timestamp offset is unknown: -00:00)" >&2
                echo "$base"
                return 0
            fi

            if ! api_epoch=$(date -d "$api_last_scan" +%s 2>&1); then
                date_error="$api_epoch"
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (API timestamp conversion failed: $api_last_scan; $date_error)" >&2
                echo "$base"
                return 0
            fi
            if ! sc_epoch=$(date -d "$sc_last_scan" +%s 2>&1); then
                date_error="$sc_epoch"
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (record timestamp conversion failed: $sc_last_scan; $date_error)" >&2
                echo "$base"
                return 0
            fi
            if ! [[ "$api_epoch" =~ ^-?[0-9]+$ && "$sc_epoch" =~ ^-?[0-9]+$ ]]; then
                [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                    echo "[debug] trivy side-channel freshness unknown for category=$category (date returned a non-epoch value)" >&2
                echo "$base"
                return 0
            fi

            # date(1)'s epoch is intentionally whole seconds. Its result decides
            # first; RFC3339 fractional fields are compared only when seconds tie.
            if ((api_epoch > sc_epoch)); then
                echo "$base"
                return 0
            fi
            if ((api_epoch == sc_epoch)); then
                if ! api_fraction=$(jq -r '.fraction // ""' <<<"$api_parts"); then
                    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                        echo "[debug] trivy side-channel freshness unknown for category=$category (API timestamp fraction extraction failed)" >&2
                    echo "$base"
                    return 0
                fi
                if ! sc_fraction=$(jq -r '.fraction // ""' <<<"$sc_parts"); then
                    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                        echo "[debug] trivy side-channel freshness unknown for category=$category (record timestamp fraction extraction failed)" >&2
                    echo "$base"
                    return 0
                fi
                api_fraction=${api_fraction#.}
                sc_fraction=${sc_fraction#.}

                # Real producers need at most nanosecond precision (nine digits),
                # while date -Iseconds emits none. More digits cannot be compared
                # reliably here, so retain the API result as for other uncertainty.
                if ((${#api_fraction} > 9 || ${#sc_fraction} > 9)); then
                    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                        echo "[debug] trivy side-channel freshness unknown for category=$category (fractional precision exceeds 9 digits)" >&2
                    echo "$base"
                    return 0
                fi

                comparison_width=${#api_fraction}
                if ((${#sc_fraction} > comparison_width)); then
                    comparison_width=${#sc_fraction}
                fi
                printf -v api_fraction "%-${comparison_width}s" "$api_fraction"
                printf -v sc_fraction "%-${comparison_width}s" "$sc_fraction"
                api_fraction=${api_fraction// /0}
                sc_fraction=${sc_fraction// /0}

                if [[ "$api_fraction" > "$sc_fraction" ]]; then
                    echo "$base"
                    return 0
                fi
            fi
        fi

        local sc_counts sc_alert_count
        sc_counts=$(jq -c '.counts' <<<"$sc_record")
        sc_alert_count=$(jq -r '.alert_count' <<<"$sc_record")

        if [[ "$sc_reason" != legacy ]]; then
            # New-format records are validated to carry all five buckets, so their
            # complete count object is authoritative over the API result.
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

    [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
        echo "[debug] trivy side-channel rejected for category=$category ($sc_reason)" >&2

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

    # Test 6: partial new-format counts are rejected; the API result remains unchanged.
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

    if [[ "$critical6" == "0" && "$high6" == "4" && "$medium6" == "2" && "$last_scan6" == "2026-05-06T08:00:00Z" ]]; then
        echo "PASS test-6: partial side-channel record rejected; API result unchanged"
    else
        echo "FAIL test-6: expected unchanged API critical=0 high=4 medium=2 last_scan=2026-05-06T08:00:00Z"
        echo "  got: critical=$critical6 high=$high6 medium=$medium6 last_scan=$last_scan6"
        echo "Full result: $result6"
        exit 1
    fi

    echo "All self-tests passed."
fi
