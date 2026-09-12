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

# Empty Trivy summary emitted when neither evidence channel is available.
_TRIVY_EMPTY='{"display_source":"unavailable","last_scan":null,"as_of":null,"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[],"scan_record":null,"code_scanning":null}'

# Precomputed per-category summary map (JSON object) — built once by _fetch_trivy_alerts_once.
# get_trivy_summary does a cheap jq key-lookup against this map instead of re-processing
# the full alerts list on every call.
_TRIVY_SUMMARY_MAP=""

# An empty map can be a successful zero-alert observation, so cache the
# outcome and the successful response's fetch instant separately from it.
_TRIVY_FETCH_OUTCOME=""
_TRIVY_FETCHED_AT=""

# trivy_rfc3339_jq
#
# Emits the shared jq definition for RFC3339 date-time syntax and calendar
# validity. It deliberately accepts -00:00 for record validation; that zone
# records an unknown local offset while preserving the supplied timestamp.
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

# trivy_summary_jq
#
# Emits the shared jq definitions for the dashboard's Trivy evidence object.
# Producers use trivy_summary_valid before publishing the object, while the
# completeness gate uses the identical predicate before certifying it. Scan
# history uses the same integer definition so the five-bucket contract has one
# meaning everywhere.
trivy_summary_jq() {
    trivy_rfc3339_jq
    cat <<'JQ'
def nonnegative_safe_integer:
  type == "number" and isfinite and floor == . and . >= 0 and . <= 9007199254740991;
def trivy_counts:
  type == "object"
  and (keys | sort) == ["critical", "high", "info", "low", "medium"]
  and ([.critical, .high, .medium, .low, .info] | all(.[]; nonnegative_safe_integer))
  and ([.critical, .high, .medium, .low, .info] | add <= 9007199254740991);
def trivy_advisory:
  type == "object"
  and (keys | sort) == ["package_name", "rule_id", "severity", "title"]
  and (.severity == "critical" or .severity == "high" or .severity == "medium"
       or .severity == "low" or .severity == "info")
  and ([.rule_id, .title, .package_name] | all(.[]; . == null or type == "string"));
def trivy_scan_record_channel:
  type == "object"
  and (keys | sort) == ["counts", "scan_at"]
  and (.scan_at | type == "string" and rfc3339)
  and (.counts | trivy_counts);
def trivy_code_scanning_channel:
  type == "object"
  and (keys | sort) == ["counts", "fetched_at", "top_advisories"]
  and (.fetched_at | type == "string" and rfc3339)
  and (.counts | trivy_counts)
  and (.top_advisories | type == "array" and all(.[]; trivy_advisory))
  and ((.top_advisories | length) <= 5)
  and ((.top_advisories | length) <= (.counts | [.critical, .high, .medium, .low, .info] | add));
def trivy_summary_valid:
  . as $summary
  | ($summary | type == "object")
  and ($summary | (keys | sort) == ["as_of", "code_scanning", "counts", "display_source", "last_scan", "scan_record", "top_advisories"])
  and ($summary.display_source == "code-scanning" or $summary.display_source == "scan-record" or $summary.display_source == "unavailable")
  and ($summary.last_scan == null or ($summary.last_scan | type == "string" and rfc3339))
  and ($summary.as_of == null or ($summary.as_of | type == "string" and rfc3339))
  and ($summary.counts | trivy_counts)
  and ($summary.top_advisories | type == "array" and all(.[]; trivy_advisory))
  and ($summary.scan_record == null or ($summary.scan_record | trivy_scan_record_channel))
  and ($summary.code_scanning == null or ($summary.code_scanning | trivy_code_scanning_channel))
  and (
    if $summary.scan_record == null then $summary.last_scan == null
    else $summary.last_scan == $summary.scan_record.scan_at
    end
  )
  and (
    if $summary.display_source == "code-scanning" then
      $summary.code_scanning != null
      and $summary.as_of == $summary.code_scanning.fetched_at
      and $summary.counts == $summary.code_scanning.counts
      and $summary.top_advisories == $summary.code_scanning.top_advisories
    elif $summary.display_source == "scan-record" then
      $summary.scan_record != null
      and $summary.code_scanning == null
      and $summary.as_of == $summary.scan_record.scan_at
      and $summary.counts == $summary.scan_record.counts
      and $summary.top_advisories == []
    else
      $summary.as_of == null
      and $summary.counts == {critical: 0, high: 0, medium: 0, low: 0, info: 0}
      and $summary.top_advisories == []
      and $summary.scan_record == null
      and $summary.code_scanning == null
    end
  );
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
    if ! normalized=$(jq -c -s "$(trivy_summary_jq)"'
        def empty_counts:
          {critical: 0, high: 0, medium: 0, low: 0, info: 0};
        def reject($reason):
          {usable: false, reason: $reason, last_scan: "", counts: empty_counts, alert_count: 0};
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
                {critical: $record.counts.critical, high: $record.counts.high,
                 medium: $record.counts.medium, low: $record.counts.low,
                 info: $record.counts.info} as $counts
                | if ($counts | trivy_counts | not) then
                    reject("malformed-record")
                  else
                    ($counts.critical + $counts.high + $counts.medium + $counts.low + $counts.info) as $sum
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
# Loads the full API observation once per process, or once per cross-subshell
# cache file. A successful empty result is deliberately distinct from failure.
_fetch_trivy_alerts_once() {
    [[ -n "${_TRIVY_FETCH_OUTCOME:-}" ]] && return 0

    if [[ -n "${TRIVY_CACHE_FILE:-}" && -s "${TRIVY_CACHE_FILE}" ]]; then
        local cached cached_summary_map cached_outcome cached_fetched_at
        cached=$(cat -- "${TRIVY_CACHE_FILE}" 2>/dev/null || true)
        if [[ -n "$cached" ]]; then
            # The compact map is JSON on one line: JSON newlines inside any
            # advisory string remain escaped, while outcome and fetched_at are
            # constrained to newline-free scalar values by this validation.
            # U+001F is escaped in compact JSON and cannot occur in the enum
            # or RFC3339 fields, so it safely separates this single jq result.
            if IFS=$'\x1f' read -r cached_summary_map cached_outcome cached_fetched_at < <(jq -er "$(trivy_rfc3339_jq)"'
                if type == "object"
                   and (keys | sort) == ["fetched_at", "outcome", "summary_map"]
                   and (.outcome == "ok" or .outcome == "unavailable")
                   and (.summary_map | type == "object")
                   and (if .outcome == "ok" then (.fetched_at | type == "string" and rfc3339)
                        else .fetched_at == null end)
                then [(.summary_map | tojson), .outcome, (.fetched_at // "")]
                     | join("\u001f")
                else empty
                end' <<<"$cached" 2>/dev/null); then
                _TRIVY_SUMMARY_MAP="$cached_summary_map"
                _TRIVY_FETCH_OUTCOME="$cached_outcome"
                _TRIVY_FETCHED_AT="$cached_fetched_at"
                return 0
            fi
        fi
    fi

    local raw gh_error_file gh_error gh_status attempt summary_map fetched_at cache_envelope cache_tmp
    raw=""
    gh_error=""
    gh_status=1
    fetched_at=""
    for attempt in 1 2 3; do
        if ! gh_error_file=$(mktemp "${TMPDIR:-/tmp}/trivy-gh-error.XXXXXX"); then
            gh_error="stderr-file-allocation-failed"
            log_warning "unable to allocate gh api stderr file — Trivy Code Scanning observation unavailable" || true
            break
        fi
        if raw=$(gh api --paginate \
            "repos/${TRIVY_UTILS_OWNER_REPO}/code-scanning/alerts?tool_name=Trivy&state=open&per_page=100" \
            2>"$gh_error_file"); then
            gh_status=0
            # This observation's time is the successful API return, not the
            # later completion of local jq summarisation.
            fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || fetched_at=""
        else
            gh_status=$?
        fi
        gh_error=$(cat -- "$gh_error_file" 2>/dev/null || true)
        rm -f -- "$gh_error_file" || true
        ((gh_status == 0)) && break

        # Every non-zero gh result gets the bounded retry sequence. Its status
        # and diagnostic cannot reliably identify a terminal failure here.
        if ((attempt < 3)); then
            sleep 1 || true
            continue
        fi
        break
    done

    if ((gh_status != 0)); then
        if [[ "$gh_error" != "stderr-file-allocation-failed" ]]; then
            log_warning "gh api code-scanning/alerts failed — Trivy Code Scanning observation unavailable" || true
        fi
        _TRIVY_SUMMARY_MAP="{}"
        _TRIVY_FETCH_OUTCOME="unavailable"
        _TRIVY_FETCHED_AT=""
    else
        if summary_map=$(echo "$raw" | jq -c -s '
            def severity_bucket:
              .rule.security_severity_level as $security_severity
              | if $security_severity == "critical" or $security_severity == "high"
                    or $security_severity == "medium" or $security_severity == "low"
                then $security_severity
                else "info"
                end;
            if length >= 1 and all(.[]; type == "array") then
              [.[][] | select(.most_recent_instance.category != null)]
              | group_by(.most_recent_instance.category)
              | map({
                  key: .[0].most_recent_instance.category,
                  value: {
                    counts: {
                      critical: (map(select(severity_bucket == "critical")) | length),
                      high:     (map(select(severity_bucket == "high"))     | length),
                      medium:   (map(select(severity_bucket == "medium"))   | length),
                      low:      (map(select(severity_bucket == "low"))      | length),
                      info:     (map(select(severity_bucket == "info"))     | length)
                    },
                    top_advisories: (
                      sort_by(if severity_bucket == "critical" then 0
                              elif severity_bucket == "high" then 1
                              elif severity_bucket == "medium" then 2
                              elif severity_bucket == "low" then 3 else 4 end)
                      | .[0:5]
                      | map({rule_id: .rule.id, severity: severity_bucket,
                             title: .rule.description,
                             package_name: ((.most_recent_instance.location.path // "") | split("/") | .[-1])})
                    )
                  }
                })
              | from_entries
            else error("expected one or more paginated JSON arrays")
            end
        ' 2>/dev/null); then
            if [[ -n "$fetched_at" ]]; then
                _TRIVY_SUMMARY_MAP="$summary_map"
                _TRIVY_FETCH_OUTCOME="ok"
                _TRIVY_FETCHED_AT="$fetched_at"
            else
                if [[ "${DASHBOARD_DEBUG:-}" == "1" ]]; then
                    echo "[debug] trivy Code Scanning fetch timestamp failed; observation unavailable" >&2 || true
                fi
                _TRIVY_SUMMARY_MAP="{}"
                _TRIVY_FETCH_OUTCOME="unavailable"
                _TRIVY_FETCHED_AT=""
            fi
        else
            if [[ "${DASHBOARD_DEBUG:-}" == "1" ]]; then
                echo "[debug] trivy code-scanning summary map build failed; observation unavailable" >&2 || true
            fi
            _TRIVY_SUMMARY_MAP="{}"
            _TRIVY_FETCH_OUTCOME="unavailable"
            _TRIVY_FETCHED_AT=""
        fi
    fi

    if [[ -n "${TRIVY_CACHE_FILE:-}" ]]; then
        if cache_envelope=$(jq -cn --arg outcome "$_TRIVY_FETCH_OUTCOME" --arg fetched_at "$_TRIVY_FETCHED_AT" \
            --argjson summary_map "$_TRIVY_SUMMARY_MAP" \
            '{outcome: $outcome, fetched_at: (if $outcome == "ok" then $fetched_at else null end), summary_map: $summary_map}'); then
            cache_tmp=$(mktemp "$(dirname "${TRIVY_CACHE_FILE}")/.trivy-summary.XXXXXX" 2>/dev/null || true)
            if [[ -n "$cache_tmp" ]]; then
                if ! printf '%s' "$cache_envelope" >"$cache_tmp" 2>/dev/null \
                    || ! mv -f -- "$cache_tmp" "${TRIVY_CACHE_FILE}" 2>/dev/null; then
                    rm -f -- "$cache_tmp" || true
                fi
            fi
        fi
    fi
}

# get_trivy_summary <category>
# Returns two independent evidence channels and a derived display choice.
get_trivy_summary() {
    local category="${1:-}"
    if [[ -z "$category" ]]; then
        echo "$_TRIVY_EMPTY"
        return 0
    fi

    _fetch_trivy_alerts_once

    local sc_root sc_relative sc_file sc_last_scan sc_usable sc_reason sc_record sc_counts scan_channel
    sc_root="${SCRIPT_DIR:-.}"
    sc_relative="${category#container-}"
    sc_file="$sc_root/.trivy-scan-history/${sc_relative//\//-}.json"
    sc_last_scan=""
    sc_usable=false
    sc_reason="no-file"
    sc_record=$(trivy_scan_history_record "$sc_file")
    IFS=$'\x1f' read -r sc_usable sc_reason sc_last_scan < <(
        jq -r '[.usable, .reason, .last_scan] | map(tostring) | join("\u001f")' <<<"$sc_record"
    )

    scan_channel=null
    if [[ "$sc_usable" == true ]]; then
        sc_counts=$(jq -c '.counts' <<<"$sc_record")
        scan_channel=$(jq -cn --arg scan_at "$sc_last_scan" --argjson counts "$sc_counts" \
            '{scan_at: $scan_at, counts: $counts}')
    else
        [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
            echo "[debug] trivy side-channel rejected for category=$category ($sc_reason)" >&2
    fi

    local api_entry code_channel
    api_entry='{"counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"top_advisories":[]}'
    if [[ "${_TRIVY_FETCH_OUTCOME:-}" == "ok" ]]; then
        api_entry=$(jq -c --arg category "$category" \
            '.[$category] // {counts: {critical: 0, high: 0, medium: 0, low: 0, info: 0}, top_advisories: []}' \
            <<<"${_TRIVY_SUMMARY_MAP}" 2>/dev/null) || api_entry=''
        if [[ -n "$api_entry" ]] && jq -e "$(trivy_summary_jq)"'type == "object"
            and (.counts | trivy_counts)
            and (.top_advisories | type == "array" and all(.[]; trivy_advisory))
        ' <<<"$api_entry" >/dev/null 2>&1; then
            code_channel=$(jq -cn --arg fetched_at "${_TRIVY_FETCHED_AT}" --argjson entry "$api_entry" \
                '{fetched_at: $fetched_at, counts: $entry.counts, top_advisories: $entry.top_advisories}')
        else
            [[ "${DASHBOARD_DEBUG:-}" == "1" ]] && \
                echo "[debug] trivy code-scanning map entry invalid for category=$category; observation unavailable" >&2
            code_channel=null
        fi
    else
        code_channel=null
    fi

    # This is the sole display resolver: it never merges the two channels.
    jq -cn --argjson scan_record "$scan_channel" --argjson code_scanning "$code_channel" '
        def zero_counts: {critical: 0, high: 0, medium: 0, low: 0, info: 0};
        (if $code_scanning != null then "code-scanning"
         elif $scan_record != null then "scan-record"
         else "unavailable" end) as $display_source
        | (if $display_source == "code-scanning" then $code_scanning
           elif $display_source == "scan-record" then $scan_record else null end) as $display
        | {display_source: $display_source,
           last_scan: (if $scan_record == null then null else $scan_record.scan_at end),
           as_of: (if $display == null then null elif $display_source == "code-scanning" then $display.fetched_at else $display.scan_at end),
           counts: (if $display == null then zero_counts else $display.counts end),
           top_advisories: (if $display_source == "code-scanning" then $display.top_advisories else [] end),
           scan_record: $scan_record, code_scanning: $code_scanning}
    '
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
    _test_dir=$(mktemp -d)
    trap 'rm -rf "$_test_dir"' EXIT
    mkdir -p "$_test_dir/.trivy-scan-history"
    printf '%s\n' '{"last_scan":"2026-04-30T11:00:00Z","alert_count":3,"status":"dirty","scanned_severity":"CRITICAL"}' > "$_test_dir/.trivy-scan-history/container-fake-1.0-linux-amd64.json"

    SCRIPT_DIR="$_test_dir"
    _TRIVY_FETCH_OUTCOME="unavailable"
    _TRIVY_FETCHED_AT=""
    _TRIVY_SUMMARY_MAP='{}'
    result=$(get_trivy_summary "container-container-fake-1.0-linux/amd64")
    jq -e '.display_source == "scan-record" and .last_scan == "2026-04-30T11:00:00Z" and .counts.critical == 3 and .code_scanning == null' <<<"$result" >/dev/null
    echo "PASS test-1: usable scan record is an independent display channel"

    _TRIVY_FETCH_OUTCOME="ok"
    _TRIVY_FETCHED_AT="2026-05-07T10:00:00Z"
    _TRIVY_SUMMARY_MAP='{}'
    result=$(get_trivy_summary "container-container-fake-1.0-linux/amd64")
    jq -e '.display_source == "code-scanning" and .counts.critical == 0 and .scan_record.counts.critical == 3 and .as_of == .code_scanning.fetched_at' <<<"$result" >/dev/null
    echo "PASS test-2: successful zero API observation wins display without discarding record"

    _TRIVY_FETCH_OUTCOME="unavailable"
    _TRIVY_FETCHED_AT=""
    result=$(get_trivy_summary "container-missing-latest-linux/amd64")
    jq -e '.display_source == "unavailable" and .last_scan == null and .as_of == null and .counts == {critical:0,high:0,medium:0,low:0,info:0}' <<<"$result" >/dev/null
    echo "PASS test-3: unavailable API is not fabricated as zero"
    echo "All self-tests passed."
fi
