#!/usr/bin/env bash
# Select the highest-priority PostgreSQL extension pair among the `full`
# flavor's members. UNKNOWN freshness candidates rank first, then dated
# overdue candidates by age; lexical extension|major|version order breaks ties.
#
# This is intentionally read-only: it lists GHCR version records and open
# blocking issues, then writes its decision to stdout and (when set) GITHUB_OUTPUT.
# The two listings are separate, non-atomic API observations. The workflow that
# acts on a selected pair must recheck that pair immediately before acting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=helpers/logging.sh
source "${ROOT_DIR}/helpers/logging.sh"
# shellcheck source=helpers/collect-lines.sh
source "${ROOT_DIR}/helpers/collect-lines.sh"
# shellcheck source=helpers/extension-utils.sh
source "${ROOT_DIR}/helpers/extension-utils.sh"
# shellcheck source=helpers/ghcr-package-utils.sh
source "${ROOT_DIR}/helpers/ghcr-package-utils.sh"

_write_selection() {
    local selected="$1"
    local extension="$2"
    local major="$3"
    local version="$4"

    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
    {
        printf 'selected=%s\n' "$selected"
        printf 'extension=%s\n' "$extension"
        printf 'major=%s\n' "$major"
        printf 'version=%s\n' "$version"
    } >> "$GITHUB_OUTPUT"
}

_list_rotation_blocking_issues() {
    local repository="$1"

    gh issue list \
        --repo "$repository" \
        --state open \
        --label extension-rotation-blocked \
        --json number,body \
        --limit 1000
}

_rotation_repository() {
    (
        cd "$ROOT_DIR"
        gh repo view --json nameWithOwner --jq .nameWithOwner
    )
}

_valid_timestamp() {
    local timestamp="$1"
    [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]
}

_valid_staleness_days() {
    local days="$1"
    # Accept 1 through 9999 days.
    [[ "$days" =~ ^[1-9][0-9]{0,3}$ ]]
}

_valid_extension_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]]
}

_remove_rotation_temp_files() {
    rm -f -- "$@"
}

_remove_rotation_temp_files_and_exit() {
    local exit_status="$1"
    shift
    _remove_rotation_temp_files "$@"
    trap - EXIT HUP INT TERM
    exit "$exit_status"
}

# EXIT and signal traps evaluate their actions as shell source. Keep the
# temporary paths in this global array and expand them only as quoted arguments
# when the static trap action runs; a TMPDIR pathname must never become code.
rotation_temp_files=()

_print_table() {
    local pairs_file="$1"
    local ext_name
    local pg_major
    local version
    local pair_key

    printf 'EXTENSION\tMAJOR\tCEILING\tAGE_DAYS\tFRESHNESS\tELIGIBILITY\n'
    while IFS=$'\t' read -r ext_name pg_major version; do
        [[ -n "$ext_name" ]] || continue
        pair_key="${ext_name}|${pg_major}|${version}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ext_name" "$pg_major" "$version" "${age_by_pair[$pair_key]}" \
            "${freshness_by_pair[$pair_key]}" "${eligibility_by_pair[$pair_key]}"
    done < "$pairs_file"
}

main() {
    : "${GH_TOKEN:?GH_TOKEN is required}"
    : "${OWNER:?OWNER is required}"
    # Keep pair-key tie-breaking bytewise and independent of the runner locale.
    local LC_ALL=C

    local staleness_days="${STALENESS_DAYS:-30}"
    if ! _valid_staleness_days "$staleness_days"; then
        log_error "STALENESS_DAYS must be an integer from 1 through 9999 days (got: ${staleness_days})"
        _write_selection false "" "" ""
        return 1
    fi

    local ext_config="${EXT_CONFIG:-${ROOT_DIR}/postgres/extensions/config.yaml}"
    if [[ ! -f "$ext_config" ]]; then
        log_error "Extension config not found: ${ext_config}"
        _write_selection false "" "" ""
        return 1
    fi

    if ! validate_extensions_schema "$ext_config"; then
        log_error "Extension config failed schema validation: ${ext_config}"
        _write_selection false "" "" ""
        return 1
    fi

    local now_epoch
    now_epoch=$(date +%s) || {
        log_error "Could not read the current time"
        _write_selection false "" "" ""
        return 1
    }

    # Five minutes permits ordinary runner/GitHub clock skew. A timestamp any
    # further ahead is impossible evidence of freshness and remains UNKNOWN.
    local future_timestamp_tolerance_seconds=300

    local pairs_file
    pairs_file=$(mktemp "${TMPDIR:-/tmp}/rotation-select-pairs.XXXXXX") || return 1
    local extensions_file
    extensions_file=$(mktemp "${TMPDIR:-/tmp}/rotation-select-extensions.XXXXXX") || {
        rm -f "$pairs_file"
        return 1
    }
    local issues_file
    issues_file=$(mktemp "${TMPDIR:-/tmp}/rotation-select-issues.XXXXXX") || {
        rm -f "$pairs_file" "$extensions_file"
        return 1
    }
    local majors_file
    majors_file=$(mktemp "${TMPDIR:-/tmp}/rotation-select-majors.XXXXXX") || {
        rm -f -- "$pairs_file" "$extensions_file" "$issues_file"
        return 1
    }
    rotation_temp_files=("$pairs_file" "$extensions_file" "$issues_file" "$majors_file")
    trap '_remove_rotation_temp_files "${rotation_temp_files[@]}"' EXIT
    trap '_remove_rotation_temp_files_and_exit 129 "${rotation_temp_files[@]}"' HUP
    trap '_remove_rotation_temp_files_and_exit 130 "${rotation_temp_files[@]}"' INT
    trap '_remove_rotation_temp_files_and_exit 143 "${rotation_temp_files[@]}"' TERM
    if ! collect_lines "$majors_file" -- yq -r '.pg_versions[]' "$ext_config"; then
        rm -f "$majors_file"
        log_error "Could not enumerate configured PostgreSQL majors"
        _write_selection false "" "" ""
        return 1
    fi

    local -A pair_seen=()
    local pg_major
    local ext_name
    local version
    while IFS= read -r pg_major; do
        [[ "$pg_major" =~ ^[0-9]+$ ]] || {
            rm -f "$majors_file"
            log_error "Invalid PostgreSQL major in ${ext_config}: ${pg_major}"
            _write_selection false "" "" ""
            return 1
        }
        if ! collect_lines "$extensions_file" -- get_flavor_extensions "$ext_config" full "$pg_major"; then
            rm -f "$majors_file"
            log_error "Could not enumerate extensions for PostgreSQL ${pg_major}"
            _write_selection false "" "" ""
            return 1
        fi
        while IFS= read -r ext_name; do
            [[ -n "$ext_name" ]] || continue
            version=$(ext_name="$ext_name" yq -er '.extensions[strenv(ext_name)].version' "$ext_config") || {
                rm -f "$majors_file"
                log_error "Could not read ceiling version for ${ext_name}/pg${pg_major}"
                _write_selection false "" "" ""
                return 1
            }
            if [[ -z "$version" || "$version" == "null" ]]; then
                rm -f "$majors_file"
                log_error "Could not read ceiling version for ${ext_name}/pg${pg_major}"
                _write_selection false "" "" ""
                return 1
            fi
            if ! _valid_extension_version "$version"; then
                rm -f "$majors_file"
                log_error "Invalid ceiling version for ${ext_name}/pg${pg_major}; expected a numeric-dotted version"
                _write_selection false "" "" ""
                return 1
            fi
            local pair_key="${ext_name}|${pg_major}|${version}"
            if [[ -z "${pair_seen[$pair_key]:-}" ]]; then
                pair_seen[$pair_key]=1
                printf '%s\t%s\t%s\n' "$ext_name" "$pg_major" "$version" >> "$pairs_file"
            fi
        done < "$extensions_file"
    done < "$majors_file"
    rm -f "$majors_file"

    if [[ ! -s "$pairs_file" ]]; then
        log_error "No extension/PostgreSQL pairs were found in ${ext_config}"
        _write_selection false "" "" ""
        return 1
    fi

    local rotation_repository
    if ! rotation_repository=$(_rotation_repository) || [[ -z "$rotation_repository" ]]; then
        log_error "Could not establish the repository for extension rotation; refusing to select from unknown issue scope"
        _write_selection false "" "" ""
        return 1
    fi
    if [[ "${rotation_repository%%/*}" != "$OWNER" ]]; then
        log_error "OWNER (${OWNER}) does not match rotation repository owner (${rotation_repository%%/*}); refusing to combine different scopes"
        _write_selection false "" "" ""
        return 1
    fi

    local -A records_by_extension=()
    local -A listed_extension=()
    local registry_failure=false
    local records_json
    while IFS=$'\t' read -r ext_name pg_major version; do
        [[ -n "$ext_name" && -z "${listed_extension[$ext_name]:-}" ]] || continue
        listed_extension[$ext_name]=1
        if records_json=$(_list_ghcr_ext_version_records "ext-${ext_name}"); then
            records_by_extension[$ext_name]="$records_json"
            if ! jq -e 'all(.[]; .tags_observed == true)' <<< "$records_json" >/dev/null; then
                registry_failure=true
                log_error "GHCR version listing for ext-${ext_name} has unobserved tags; refusing to select from incomplete registry data"
            fi
        else
            registry_failure=true
            records_by_extension[$ext_name]='[]'
            log_error "GHCR version listing failed for ext-${ext_name}; refusing to select from incomplete registry data"
        fi
    done < "$pairs_file"

    if [[ "$registry_failure" == true ]]; then
        printf 'No pair selected: registry state is incomplete; candidate set is unknown.\n'
        _write_selection false "" "" ""
        return 1
    fi

    local -A blocked_pair=()
    local issue_failure=false
    if ! collect_lines "$issues_file" -- _list_rotation_blocking_issues "$rotation_repository"; then
        issue_failure=true
        log_error "Could not list open extension-rotation-blocked issues; refusing to select from incomplete issue data"
    elif ! jq -e 'type == "array" and length < 1000 and all(.[]; type == "object" and (.number | type == "number") and ((.body == null) or (.body | type == "string")))' "$issues_file" >/dev/null; then
        issue_failure=true
        log_error "Open extension-rotation-blocked issue response was invalid or reached the 1000-issue cap; refusing to select"
    else
        local issue_records
        if ! issue_records=$(jq -c '.[]' "$issues_file"); then
            issue_failure=true
            log_error "Could not enumerate open extension-rotation-blocked issues; refusing to select"
        fi
        local issue_json
        while IFS= read -r issue_json; do
            [[ -n "$issue_json" ]] || continue
            local issue_number
            local issue_body
            issue_number=$(jq -r '.number' <<< "$issue_json")
            issue_body=$(jq -r '.body // ""' <<< "$issue_json")
            local marker
            while IFS= read -r marker; do
                # read removes LF but leaves CR from a CRLF-delimited GitHub body.
                # Remove only that terminator; spaces or any other trailing text
                # remain part of the marker and therefore fail the strict match.
                marker="${marker%$'\r'}"
                if [[ "$marker" =~ ^rotation-pair:\ ([a-zA-Z0-9_-]+)\ pg([0-9]+)\ ([0-9]+([.][0-9]+)*)$ ]]; then
                    local marker_key="${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${BASH_REMATCH[3]}"
                    if [[ -n "${pair_seen[$marker_key]:-}" ]]; then
                        blocked_pair[$marker_key]=1
                        log_info "Blocking marker #${issue_number}: ${marker} — matched current pair"
                    else
                        log_info "Blocking marker #${issue_number}: ${marker} — did not match a current pair"
                    fi
                fi
            done <<< "$issue_body"
        done <<< "$issue_records"
    fi

    if [[ "$issue_failure" == true ]]; then
        printf 'No pair selected: blocking-issue state is incomplete; candidate set is unknown.\n'
        _write_selection false "" "" ""
        return 1
    fi

    local -A freshness_by_pair=()
    local -A eligibility_by_pair=()
    local -A age_by_pair=()
    local selected_extension=""
    local selected_major=""
    local selected_version=""
    local selected_age=-1
    local selected_priority=-1
    local selected_key=""
    local canonical_tag
    local record_json
    local updated_at
    local updated_epoch
    local age_days
    local pair_key
    local blocked_candidate_count=0
    local record_matches
    local record_count

    while IFS=$'\t' read -r ext_name pg_major version; do
        pair_key="${ext_name}|${pg_major}|${version}"
        canonical_tag="pg${pg_major}-${version}"
        record_matches=$(jq -c --arg tag "$canonical_tag" '[.[] | select(any(.tags[]?; . == $tag))]' <<< "${records_by_extension[$ext_name]}")
        record_count=$(jq -r 'length' <<< "$record_matches")
        if [[ "$record_count" -ne 1 ]]; then
            freshness_by_pair[$pair_key]=UNKNOWN
            age_by_pair[$pair_key]=unknown
            eligibility_by_pair[$pair_key]=$([[ -n "${blocked_pair[$pair_key]:-}" ]] && printf BLOCKED || printf ELIGIBLE)
            [[ -z "${blocked_pair[$pair_key]:-}" ]] || ((blocked_candidate_count += 1))
            # UNKNOWN has priority over dated pairs: an absent canonical record
            # (or an inconsistent observation) means this pair was never built,
            # was pruned, or cannot be judged. Ties use the lexical
            # extension|major|version key, independent of config order.
            if [[ -z "${blocked_pair[$pair_key]:-}" && ( "$selected_priority" -lt 2 || ( "$selected_priority" -eq 2 && "$pair_key" < "$selected_key" ) ) ]]; then
                selected_extension="$ext_name"
                selected_major="$pg_major"
                selected_version="$version"
                selected_age=-1
                selected_priority=2
                selected_key="$pair_key"
            fi
            continue
        fi

        record_json=$(jq -c '.[0]' <<< "$record_matches")

        updated_at=$(jq -r '.updated_at // ""' <<< "$record_json")
        if ! _valid_timestamp "$updated_at" || ! updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || ((updated_epoch > now_epoch + future_timestamp_tolerance_seconds)); then
            freshness_by_pair[$pair_key]=UNKNOWN
            age_by_pair[$pair_key]=unknown
            eligibility_by_pair[$pair_key]=$([[ -n "${blocked_pair[$pair_key]:-}" ]] && printf BLOCKED || printf ELIGIBLE)
            [[ -z "${blocked_pair[$pair_key]:-}" ]] || ((blocked_candidate_count += 1))
            # UNKNOWN has priority over dated pairs; lexical key breaks its tie.
            if [[ -z "${blocked_pair[$pair_key]:-}" && ( "$selected_priority" -lt 2 || ( "$selected_priority" -eq 2 && "$pair_key" < "$selected_key" ) ) ]]; then
                selected_extension="$ext_name"
                selected_major="$pg_major"
                selected_version="$version"
                selected_age=-1
                selected_priority=2
                selected_key="$pair_key"
            fi
            continue
        fi

        age_days=$(( (now_epoch - updated_epoch) / 86400 ))
        if [[ "$age_days" -lt 0 ]]; then
            age_days=0
        fi
        age_by_pair[$pair_key]="$age_days"
        if [[ -n "${blocked_pair[$pair_key]:-}" ]]; then
            eligibility_by_pair[$pair_key]=BLOCKED
            if [[ "$age_days" -ge "$staleness_days" ]]; then
                freshness_by_pair[$pair_key]=OVERDUE
                ((blocked_candidate_count += 1))
            else
                freshness_by_pair[$pair_key]=FRESH
            fi
        elif [[ "$age_days" -ge "$staleness_days" ]]; then
            freshness_by_pair[$pair_key]=OVERDUE
            eligibility_by_pair[$pair_key]=ELIGIBLE
            # Among dated overdue pairs, age wins; equal ages use the same
            # lexical extension|major|version key as UNKNOWN pairs.
            if [[ "$selected_priority" -lt 1 || ( "$selected_priority" -eq 1 && ( "$age_days" -gt "$selected_age" || ( "$age_days" -eq "$selected_age" && "$pair_key" < "$selected_key" ) ) ) ]]; then
                selected_extension="$ext_name"
                selected_major="$pg_major"
                selected_version="$version"
                selected_age="$age_days"
                selected_priority=1
                selected_key="$pair_key"
            fi
        else
            freshness_by_pair[$pair_key]=FRESH
            eligibility_by_pair[$pair_key]=ELIGIBLE
        fi
    done < "$pairs_file"

    _print_table "$pairs_file"

    if [[ -n "$selected_extension" ]]; then
        if [[ "$selected_priority" -eq 2 ]]; then
            printf 'Selected pair: %s pg%s %s (freshness UNKNOWN)\n' \
                "$selected_extension" "$selected_major" "$selected_version"
        else
            printf 'Selected pair: %s pg%s %s (%s days overdue)\n' \
                "$selected_extension" "$selected_major" "$selected_version" "$((selected_age - staleness_days))"
        fi
        _write_selection true "$selected_extension" "$selected_major" "$selected_version"
    elif ((blocked_candidate_count > 0)); then
        printf 'No pair selected: every selection candidate is blocked.\n'
        _write_selection false "" "" ""
    else
        printf 'Nothing is overdue.\n'
        _write_selection false "" "" ""
    fi
}

main "$@"
