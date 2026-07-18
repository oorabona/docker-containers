#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${GPG_KEYS_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=../helpers/logging.sh
# shellcheck disable=SC1091
source "$PROJECT_ROOT/helpers/logging.sh"

DEFAULT_WARN_DAYS=60
MAX_WARN_DAYS=3650
CURL_ARGS=(-fsSL --retry 2 --retry-delay 2 --retry-all-errors --connect-timeout 15 --max-time 45)
GPG_BIN="${GPG_KEYS_GPG_BIN:-$(command -v gpg || true)}"
CURL_BIN="${GPG_KEYS_CURL_BIN:-$(command -v curl || true)}"
YQ_BIN="${GPG_KEYS_YQ_BIN:-$(command -v yq || true)}"
JQ_BIN="${GPG_KEYS_JQ_BIN:-$(command -v jq || true)}"
LATEST_GH_RELEASE="${GPG_KEYS_LATEST_GH_RELEASE:-$PROJECT_ROOT/helpers/latest-github-release}"

_gha_escape() {
    local s="$1"
    s="${s//%/%25}"
    s="${s//$'\r'/%0D}"
    s="${s//$'\n'/%0A}"
    printf '%s' "$s"
}

usage() {
    cat >&2 <<'USAGE'
usage: check-gpg-keys.sh [--all | <container>] [--json] [--warn-days N]
USAGE
}

validate_tools() {
    local missing=0
    if [[ -z "$GPG_BIN" || ! -x "$GPG_BIN" ]]; then
        echo "check-gpg-keys: unable to resolve gpg; set GPG_KEYS_GPG_BIN" >&2
        missing=1
    fi
    if [[ -z "$CURL_BIN" || ! -x "$CURL_BIN" ]]; then
        echo "check-gpg-keys: unable to resolve curl; set GPG_KEYS_CURL_BIN" >&2
        missing=1
    fi
    if [[ -z "$YQ_BIN" || ! -x "$YQ_BIN" ]]; then
        echo "check-gpg-keys: unable to resolve yq; set GPG_KEYS_YQ_BIN" >&2
        missing=1
    fi
    if [[ -z "$JQ_BIN" || ! -x "$JQ_BIN" ]]; then
        echo "check-gpg-keys: unable to resolve jq; set GPG_KEYS_JQ_BIN" >&2
        missing=1
    fi
    if [[ -z "$LATEST_GH_RELEASE" || ! -x "$LATEST_GH_RELEASE" ]]; then
        echo "check-gpg-keys: unable to resolve latest-github-release; set GPG_KEYS_LATEST_GH_RELEASE" >&2
        missing=1
    fi
    (( missing == 0 ))
}

jq() {
    "$JQ_BIN" "$@"
}

yq() {
    "$YQ_BIN" "$@"
}

config_parses() {
    local config="$1"
    yq -e '.' "$config" >/dev/null 2>&1
}

config_has_gpg_key() {
    local config="$1"
    yq -e '(.dependency_sources // {}) | select(type == "!!map") | to_entries[] | select(.value | type == "!!map") | select(.value.gpg_key != null)' "$config" >/dev/null 2>&1
}

config_dependency_sources_shape_invalid() {
    local config="$1"
    yq -e 'has("dependency_sources") and (.dependency_sources | type != "!!map")' "$config" >/dev/null 2>&1
}

discover_containers() {
    local config container
    for config in "$PROJECT_ROOT"/*/config.yaml; do
        [[ -f "$config" ]] || continue
        container="$(basename -- "$(dirname "$config")")"
        valid_container_target "$container" || continue
        if ! config_parses "$config" || config_dependency_sources_shape_invalid "$config" || config_has_gpg_key "$config"; then
            printf '%s\n' "$container"
        fi
    done | sort -u
}

monitored_deps() {
    local config="$1"
    yq -r '(.dependency_sources // {}) | select(type == "!!map") | to_entries[] | select(.value | type == "!!map") | select(.value.gpg_key != null) | .key' "$config"
}

valid_warn_days() {
    local value="$1"
    local normalized

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    normalized="$value"
    while [[ "${#normalized}" -gt 1 && "${normalized:0:1}" == "0" ]]; do
        normalized="${normalized:1}"
    done
    if [[ "${#normalized}" -gt "${#MAX_WARN_DAYS}" ]]; then
        return 1
    fi
    if [[ "${#normalized}" -eq "${#MAX_WARN_DAYS}" ]] && (( 10#$normalized > MAX_WARN_DAYS )); then
        return 1
    fi
    return 0
}

empty_expiry() {
    local reason="$1"
    local severity="$2"
    jq -nc --arg reason "$reason" --arg severity "$severity" \
        '{status:"error", reason:$reason, severity:$severity, days_left:null, expires:null, fpr:null, keyid:null}'
}

empty_rotation() {
    jq -nc '{status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:null, runtime:false}'
}

rotation_config_unsupported() {
    jq -nc '{status:"error", rotation:false, reason:"rotation-config-unsupported", severity:"high", latest:null}'
}

rotation_tag_pattern_unsupported() {
    jq -nc '{status:"error", rotation:false, reason:"rotation-tag-pattern-unsupported", severity:"high", latest:null, runtime:false}'
}

contract_result() {
    local report="$1"
    local pinned_fpr="$2"

    local primary_fpr primary_keyid primary_count primary_validity signing_capable signing_usable reason severity status
    primary_fpr="$(jq -r '.primary_fpr // ""' <<< "$report")"
    primary_keyid="$(jq -r '.primary_keyid // ""' <<< "$report")"
    primary_count="$(jq -r '.primary_count // 0' <<< "$report")"
    primary_validity="$(jq -r '.primary_validity // ""' <<< "$report")"
    signing_capable="$(jq -r '.signing_capable // .signing_usable // false' <<< "$report")"
    signing_usable="$(jq -r '.signing_usable // false' <<< "$report")"

    # Reconciled trust-anchor contract: reject revoked/invalid/disabled keys
    # because that trust-anchor failure is not caught elsewhere, but allow
    # expired keys because the build tolerates EXPKEYSIG and expiry is owned by
    # the expiry check.
    status="ok"
    reason="valid"
    severity="none"
    if [[ "$primary_count" != "1" \
        || "$primary_fpr" != "$pinned_fpr" \
        || "$signing_capable" != "true" \
        || "$primary_validity" =~ ^[rid]$ ]]; then
        status="error"
        reason="key-contract-mismatch"
        severity="high"
    fi

    jq -nc \
        --arg status "$status" \
        --arg reason "$reason" \
        --arg severity "$severity" \
        --arg primary_fpr "$primary_fpr" \
        --arg primary_keyid "$primary_keyid" \
        --arg primary_count "$primary_count" \
        --arg primary_validity "$primary_validity" \
        --arg signing_capable "$signing_capable" \
        --arg signing_usable "$signing_usable" \
        --arg pinned_fpr "$pinned_fpr" '
        {
          status: $status,
          reason: $reason,
          severity: $severity,
          primary_fpr: $primary_fpr,
          primary_keyid: $primary_keyid,
          primary_count: ($primary_count | tonumber),
          primary_validity: $primary_validity,
          signing_capable: ($signing_capable == "true"),
          signing_usable: ($signing_usable == "true"),
          pinned_fpr: $pinned_fpr
        }'
}

expiry_result_from_report() {
    local container="$1"
    local dep="$2"
    local report="$3"
    local warn_days="$4"

    local no_expiry expires_ts expires fpr keyid now days_left status reason severity signing_capable signing_usable primary_validity
    no_expiry="$(jq -r '.no_expiry' <<< "$report")"
    expires_ts="$(jq -r '.expires_ts // empty' <<< "$report")"
    expires="$(jq -r '.expires // empty' <<< "$report")"
    fpr="$(jq -r '.signing_fpr // ""' <<< "$report")"
    keyid="$(jq -r '.primary_keyid // ""' <<< "$report")"
    signing_capable="$(jq -r '.signing_capable // .signing_usable // false' <<< "$report")"
    signing_usable="$(jq -r '.signing_usable // false' <<< "$report")"
    primary_validity="$(jq -r '.primary_validity // ""' <<< "$report")"
    now="${GPG_KEYS_NOW_TS:-$(date -u +%s)}"

    if [[ "$signing_capable" == "true" && "$signing_usable" == "false" && ! "$primary_validity" =~ ^[rid]$ ]]; then
        status="expired"
        reason="signing-key-expired"
        severity="high"
        if [[ -n "$expires_ts" ]]; then
            days_left=$(( (expires_ts - now) / 86400 ))
        else
            days_left=""
        fi
    elif [[ "$no_expiry" == "true" ]]; then
        status="ok"
        reason="no-expiry"
        severity="none"
        days_left=""
    elif (( expires_ts < now )); then
        status="expired"
        reason="expired"
        severity="high"
        days_left=$(( (expires_ts - now) / 86400 ))
    else
        days_left=$(( (expires_ts - now) / 86400 ))
        if (( days_left <= 10#$warn_days )); then
            status="expiring"
            reason="expiring"
            severity="warn"
        else
            status="ok"
            reason="valid"
            severity="none"
        fi
    fi

    log_info "[${container}/${dep}] signing key ${fpr} expiry: ${expires:-none}"

    jq -nc \
        --arg status "$status" \
        --arg reason "$reason" \
        --arg severity "$severity" \
        --arg days_left "$days_left" \
        --arg expires "$expires" \
        --arg fpr "$fpr" \
        --arg keyid "$keyid" '
        {
          status: $status,
          reason: $reason,
          severity: $severity,
          days_left: (if $days_left == "" then null else ($days_left | tonumber) end),
          expires: (if $expires == "" then null else $expires end),
          fpr: $fpr,
          keyid: $keyid
        }'
}

fetch_release_artifact() {
    local url="$1"
    local out="$2"

    if ! "$CURL_BIN" "${CURL_ARGS[@]}" -o "$out" "$url" >/dev/null; then
        return 1
    fi
    [[ -s "$out" ]]
}

rotation_result() {
    local container="$1"
    local dep="$2"
    local repo="$3"
    local strip_v="$4"
    local keyfile="$5"
    local errors_json="$6"
    local config="$7"

    local asset_template tag_template asset tag base_url
    asset_template="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].gpg_key.release_asset_template // ""' "$config")"
    tag_template="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].gpg_key.release_tag_template // ""' "$config")"
    if [[ -z "$asset_template" || "$asset_template" == "null" || -z "$tag_template" || "$tag_template" == "null" ]]; then
        local msg="${dep}: missing gpg_key release_asset_template or release_tag_template"
        jq -nc --arg msg "$msg" --argjson errors "$errors_json" '
          {
            rotation: {status:"error", rotation:false, reason:"missing-release-template", severity:"high", latest:null, runtime:false},
            errors: ($errors + [$msg])
          }'
        return 0
    fi

    local latest_args=("$repo")
    [[ "$strip_v" == "true" ]] && latest_args+=("--strip-v")

    local latest
    if ! latest="$("$LATEST_GH_RELEASE" "${latest_args[@]}" 2>/dev/null)"; then
        local msg="${dep}: failed to resolve latest release for ${repo}"
        jq -nc --arg msg "$msg" --argjson errors "$errors_json" '
          {
            rotation: {status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:null, runtime:true},
            errors: ($errors + [$msg])
          }'
        return 0
    fi

    asset="${asset_template//\{version\}/$latest}"
    tag="${tag_template//\{version\}/$latest}"
    local base_url="https://github.com/${repo}/releases/download/${tag}/${asset}"
    local tmpdir tgz sig gnupg_tmp
    tmpdir="$(mktemp -d)"
    gnupg_tmp="$(mktemp -d)"
    chmod 700 "$gnupg_tmp"

    local cleanup_done=false
    cleanup_rotation_tmp() {
        if [[ "$cleanup_done" == "false" ]]; then
            rm -rf "$tmpdir" "$gnupg_tmp"
            cleanup_done=true
        fi
    }

    tgz="${tmpdir}/$(basename -- "$asset")"
    sig="${tgz}.sig"

    if ! fetch_release_artifact "$base_url" "$tgz" || ! fetch_release_artifact "${base_url}.sig" "$sig"; then
        cleanup_rotation_tmp
        local msg="${dep}: failed to fetch release artifact/signature for ${latest}"
        jq -nc --arg latest "$latest" --arg msg "$msg" --argjson errors "$errors_json" '
          {
            rotation: {status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:$latest, runtime:true},
            errors: ($errors + [$msg])
          }'
        return 0
    fi

    local import_out verify_out
    if ! import_out="$(GNUPGHOME="$gnupg_tmp" "$GPG_BIN" --batch --quiet --import "$keyfile" 2>&1)"; then
        cleanup_rotation_tmp
        local msg="${dep}: failed to import vendored key for rotation check: ${import_out}"
        jq -nc --arg latest "$latest" --arg msg "$msg" --argjson errors "$errors_json" '
          {
            rotation: {status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:$latest, runtime:true},
            errors: ($errors + [$msg])
          }'
        return 0
    fi

    verify_out="$(GNUPGHOME="$gnupg_tmp" "$GPG_BIN" --batch --status-fd=1 --verify "$sig" "$tgz" 2>&1)" || true
    cleanup_rotation_tmp

    # EXPKEYSIG is deliberately accepted for the rotation verdict: the build's
    # `gpg --verify` accepts expired-key signatures, expiry is covered by the
    # separate expiry check, and this throwaway keyring contains only the
    # vendored key. Rotation here means the latest release is no longer signed
    # by the pinned key.
    if grep -q '^\[GNUPG:\] VALIDSIG ' <<< "$verify_out" \
        && ! grep -Eq '^\[GNUPG:\] (REVKEYSIG|BADSIG|ERRSIG|NO_PUBKEY|EXPSIG)( |$)' <<< "$verify_out"; then
        log_info "[${container}/${dep}] release ${latest} verifies with vendored key"
        jq -nc --arg latest "$latest" --argjson errors "$errors_json" '
          {rotation: {status:"ok", rotation:false, reason:"verified", severity:"none", latest:$latest, runtime:true}, errors: $errors}'
    else
        log_warning "[${container}/${dep}] release ${latest} signature no longer verifies with vendored key"
        jq -nc --arg latest "$latest" --argjson errors "$errors_json" '
          {rotation: {status:"rotation", rotation:true, reason:"no-valid-signature", severity:"high", latest:$latest, runtime:true}, errors: $errors}'
    fi
}

emit_warning_if_needed() {
    local container="$1"
    local dep="$2"
    local result="$3"

    local expiry_status rotation_status contract_status expiry_reason rotation_reason contract_reason
    expiry_status="$(jq -r '.expiry.status' <<< "$result")"
    rotation_status="$(jq -r '.rotation.status' <<< "$result")"
    contract_status="$(jq -r '.contract.status // "ok"' <<< "$result")"
    expiry_reason="$(jq -r '.expiry.reason' <<< "$result")"
    rotation_reason="$(jq -r '.rotation.reason' <<< "$result")"
    contract_reason="$(jq -r '.contract.reason // "valid"' <<< "$result")"

    if [[ "$contract_status" != "ok" ]]; then
        printf '::warning::gpg-key-contract: %s\n' \
            "$(_gha_escape "${container}/${dep}: ${contract_reason}")" >&2
    fi
    if [[ "$expiry_status" != "ok" ]]; then
        printf '::warning::gpg-key-expiry: %s\n' \
            "$(_gha_escape "${container}/${dep}: ${expiry_reason}")" >&2
    fi
    if [[ "$rotation_status" != "ok" ]]; then
        printf '::warning::gpg-key-rotation: %s\n' \
            "$(_gha_escape "${container}/${dep}: ${rotation_reason}")" >&2
    fi
    local config_finding config_reason config_value config_detail
    while IFS= read -r config_finding; do
        [[ -n "$config_finding" ]] || continue
        config_reason="$(jq -r '.reason // "config-error"' <<< "$config_finding")"
        config_value="$(jq -r '.value // ""' <<< "$config_finding")"
        config_detail="${container}/${dep}: ${config_reason}"
        [[ -n "$config_value" ]] && config_detail="${config_detail} ${config_value}"
        printf '::warning::gpg-key-config: %s\n' "$(_gha_escape "$config_detail")" >&2
    done < <(jq -c '.config // [] | .[]' <<< "$result")
}

config_parse_result() {
    local container="$1"
    local config="$PROJECT_ROOT/${container}/config.yaml"
    local msg="${container}: failed to parse ${config}"

    jq -nc \
        --arg container "$container" \
        --arg msg "$msg" '
        {
          container: $container,
          dependency: null,
          key_file: null,
          expiry: {status:"error", reason:"config-parse-error", severity:"high", days_left:null, expires:null, fpr:null, keyid:null},
          rotation: {status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:null},
          contract: {status:"error", reason:"config-parse-error", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:null},
          config: [{reason:"config-parse-error", severity:"high", message:$msg}],
          errors: [$msg]
        }'
}

config_shape_result() {
    local container="$1"
    local config="$PROJECT_ROOT/${container}/config.yaml"
    local msg="${container}: dependency_sources in ${config} must be a mapping"

    jq -nc \
        --arg container "$container" \
        --arg msg "$msg" '
        {
          container: $container,
          dependency: null,
          key_file: null,
          expiry: {status:"error", reason:"config-shape-invalid", severity:"high", days_left:null, expires:null, fpr:null, keyid:null},
          rotation: {status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:null},
          contract: {status:"error", reason:"config-shape-invalid", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:null},
          config: [{reason:"config-shape-invalid", severity:"high", message:$msg}],
          errors: [$msg]
        }'
}

gpg_key_shape_valid() {
    local config="$1"
    local dep="$2"

    # shellcheck disable=SC2016
    YQ_DEP="$dep" yq -e '
      .dependency_sources[strenv(YQ_DEP)].gpg_key as $gpg_key
      | select($gpg_key | type == "!!map")
      | select(([
          $gpg_key.file,
          $gpg_key.expiry_warn_days,
          $gpg_key.fingerprint_arg,
          $gpg_key.release_asset_template,
          $gpg_key.release_tag_template
        ] | map(select(. != null and (type == "!!map" or type == "!!seq"))) | length) == 0)
    ' "$config" >/dev/null 2>&1
}

gpg_key_shape_result() {
    local container="$1"
    local dep="$2"
    local config="$PROJECT_ROOT/${container}/config.yaml"
    local msg="${dep}: gpg_key in ${config} must be a mapping with scalar fields"

    jq -nc \
        --arg container "$container" \
        --arg dep "$dep" \
        --arg msg "$msg" '
        {
          container: $container,
          dependency: $dep,
          key_file: null,
          expiry: {status:"error", reason:"gpg-key-shape-invalid", severity:"high", days_left:null, expires:null, fpr:null, keyid:null},
          rotation: {status:"error", rotation:false, reason:"rotation-check-unavailable", severity:"warn", latest:null},
          contract: {status:"error", reason:"gpg-key-shape-invalid", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:null},
          config: [{reason:"gpg-key-shape-invalid", severity:"high", message:$msg}],
          errors: [$msg]
        }'
}

valid_container_target() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

container_config_path() {
    local container="$1"
    valid_container_target "$container" || return 1
    printf '%s/%s/config.yaml\n' "$PROJECT_ROOT" "$container"
}

valid_gpg_key_file() {
    local key_rel="$1"
    [[ -n "$key_rel" && "$key_rel" != "null" && "$key_rel" != *"/"* && "$key_rel" != *".."* ]]
}

check_dep() {
    local container="$1"
    local dep="$2"
    local config="$3"
    local cli_warn_days="$4"

    local key_rel repo strip_v cfg_warn_days warn_days dep_type tag_pattern keyfile errors_json config_json fingerprint_arg pinned_fpr
    key_rel="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].gpg_key.file // ""' "$config")"
    repo="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].repo // ""' "$config")"
    strip_v="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].strip_v // false' "$config")"
    cfg_warn_days="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].gpg_key.expiry_warn_days // ""' "$config")"
    dep_type="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].type // ""' "$config")"
    tag_pattern="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].tag_pattern // ""' "$config")"
    fingerprint_arg="$(YQ_DEP="$dep" yq -r '.dependency_sources[strenv(YQ_DEP)].gpg_key.fingerprint_arg // ""' "$config")"
    pinned_fpr=""
    if [[ -n "$fingerprint_arg" && "$fingerprint_arg" != "null" ]]; then
        pinned_fpr="$(YQ_DEP="$dep" YQ_FPR_ARG="$fingerprint_arg" yq -r '.build_args[strenv(YQ_FPR_ARG)] // ""' "$config")"
    fi
    warn_days="${cli_warn_days:-${cfg_warn_days:-$DEFAULT_WARN_DAYS}}"
    [[ -z "$warn_days" || "$warn_days" == "null" ]] && warn_days="$DEFAULT_WARN_DAYS"
    keyfile=""
    errors_json="[]"
    config_json="[]"

    local expiry_json rotation_json contract_json report
    if [[ -z "$fingerprint_arg" || "$fingerprint_arg" == "null" || -z "$pinned_fpr" || "$pinned_fpr" == "null" ]]; then
        local msg="${dep}: missing pinned gpg_key fingerprint build_arg"
        errors_json="$(jq -nc --arg msg "$msg" '[$msg]')"
        config_json="$(jq -nc --arg msg "$msg" '[{reason:"missing-pinned-fingerprint", severity:"high", message:$msg}]')"
        expiry_json="$(empty_expiry "missing-pinned-fingerprint" "high")"
        rotation_json="$(empty_rotation)"
        contract_json="$(jq -nc '{status:"error", reason:"missing-pinned-fingerprint", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:null}')"
    elif ! valid_gpg_key_file "$key_rel"; then
        local msg="${dep}: invalid gpg_key.file: ${key_rel}"
        errors_json="$(jq -nc --arg msg "$msg" '[$msg]')"
        config_json="$(jq -nc --arg msg "$msg" '[{reason:"key-file-invalid", severity:"high", message:$msg}]')"
        expiry_json="$(empty_expiry "key-file-invalid" "high")"
        rotation_json="$(empty_rotation)"
        contract_json="$(jq -nc --arg pinned_fpr "$pinned_fpr" '{status:"error", reason:"key-file-invalid", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:$pinned_fpr}')"
    else
        keyfile="$PROJECT_ROOT/${container}/${key_rel}"
        if [[ ! -f "$keyfile" ]]; then
            local msg="${dep}: key file missing: ${container}/${key_rel}"
            errors_json="$(jq -nc --arg msg "$msg" '[$msg]')"
            config_json="$(jq -nc --arg msg "$msg" '[{reason:"key-file-missing", severity:"high", message:$msg}]')"
            expiry_json="$(empty_expiry "key-file-missing" "high")"
            rotation_json="$(empty_rotation)"
            contract_json="$(jq -nc --arg pinned_fpr "$pinned_fpr" '{status:"error", reason:"key-file-missing", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:$pinned_fpr}')"
        elif ! report="$(GPG_KEYS_GPG_BIN="$GPG_BIN" "$PROJECT_ROOT/helpers/gpg-key-expiry" "$keyfile" 2>&1)"; then
            errors_json="$(jq -nc --arg msg "${dep}: failed to inspect ${keyfile}: ${report}" '[$msg]')"
            expiry_json="$(empty_expiry "key-parse-error" "high")"
            rotation_json="$(empty_rotation)"
            contract_json="$(jq -nc --arg pinned_fpr "$pinned_fpr" '{status:"error", reason:"key-parse-error", severity:"high", primary_fpr:null, primary_keyid:null, primary_count:null, primary_validity:null, pinned_fpr:$pinned_fpr}')"
        else
            contract_json="$(contract_result "$report" "$pinned_fpr")"
            if ! valid_warn_days "$warn_days"; then
                local msg="${dep}: invalid gpg_key.expiry_warn_days: ${warn_days}"
                errors_json="$(jq -nc --arg msg "$msg" --argjson errors "$errors_json" '$errors + [$msg]')"
                config_json="$(jq -nc --arg msg "$msg" --arg value "$warn_days" --argjson config "$config_json" '$config + [{reason:"invalid-warn-days", severity:"warn", value:$value, message:$msg}]')"
                warn_days="$DEFAULT_WARN_DAYS"
            fi
            expiry_json="$(expiry_result_from_report "$container" "$dep" "$report" "$warn_days")"
            if [[ "$dep_type" == "github-release" && -n "$repo" && "$repo" != "null" ]]; then
                if [[ -n "$tag_pattern" && "$tag_pattern" != "null" ]]; then
                    # GPG-rotation tag_pattern support is deferred until the
                    # shared latest-github-release resolver is hardened to honor
                    # it safely; fail closed instead of checking the wrong tag.
                    local msg="${dep}: gpg_key rotation does not support dependency_sources.${dep}.tag_pattern"
                    errors_json="$(jq -nc --arg msg "$msg" --argjson errors "$errors_json" '$errors + [$msg]')"
                    config_json="$(jq -nc --arg msg "$msg" --arg value "$tag_pattern" --argjson config "$config_json" '$config + [{reason:"rotation-tag-pattern-unsupported", severity:"high", value:$value, message:$msg}]')"
                    rotation_json="$(rotation_tag_pattern_unsupported)"
                else
                    rotation_json="$(rotation_result "$container" "$dep" "$repo" "$strip_v" "$keyfile" "$errors_json" "$config")"
                    errors_json="$(jq -c '.errors' <<< "$rotation_json")"
                    rotation_json="$(jq -c '.rotation' <<< "$rotation_json")"
                    if [[ "$(jq -r '.reason' <<< "$rotation_json")" == "missing-release-template" ]]; then
                        config_json="$(jq -nc --arg msg "${dep}: missing gpg_key release_asset_template or release_tag_template" --argjson config "$config_json" '$config + [{reason:"missing-release-template", severity:"high", message:$msg}]')"
                    fi
                fi
            else
                local msg="${dep}: rotation check requires dependency_sources.${dep}.type=github-release and repo"
                errors_json="$(jq -nc --arg msg "$msg" --argjson errors "$errors_json" '$errors + [$msg]')"
                config_json="$(jq -nc --arg msg "$msg" --argjson config "$config_json" '$config + [{reason:"rotation-config-unsupported", severity:"high", message:$msg}]')"
                rotation_json="$(rotation_config_unsupported)"
            fi
        fi
    fi

    local result
    result="$(jq -nc \
        --arg container "$container" \
        --arg dep "$dep" \
        --arg key_file "${container}/${key_rel}" \
        --argjson expiry "$expiry_json" \
        --argjson rotation "$rotation_json" \
        --argjson contract "$contract_json" \
        --argjson config "$config_json" \
        --argjson errors "$errors_json" \
        '{container:$container, dependency:$dep, key_file:$key_file, expiry:$expiry, rotation:$rotation, contract:$contract, config:$config, errors:$errors}')"

    emit_warning_if_needed "$container" "$dep" "$result"
    printf '%s\n' "$result"
}

main() {
    local target="" json=false cli_warn_days=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                target="__all__"
                shift
                ;;
            --json)
                json=true
                shift
                ;;
            --warn-days)
                if [[ $# -lt 2 ]] || ! valid_warn_days "$2"; then
                    usage
                    return 2
                fi
                cli_warn_days="$2"
                shift 2
                ;;
            -*)
                usage
                return 2
                ;;
            *)
                [[ -z "$target" ]] || {
                    usage
                    return 2
                }
                target="$1"
                shift
                ;;
        esac
    done

    [[ -n "$target" ]] || target="__all__"
    validate_tools

    local containers=()
    if [[ "$target" == "__all__" ]]; then
        mapfile -t containers < <(discover_containers)
    else
        containers=("$target")
    fi

    if [[ "$target" != "__all__" ]]; then
        if ! valid_container_target "$target"; then
            echo "check-gpg-keys: invalid target container: ${target}" >&2
            return 1
        fi
        local explicit_config
        explicit_config="$(container_config_path "$target")"
        if [[ ! -f "$explicit_config" ]]; then
            echo "check-gpg-keys: no config.yaml found for target container: ${target}" >&2
            return 1
        fi
    fi

    local results="[]"
    local container config deps dep result
    for container in "${containers[@]}"; do
        if ! config="$(container_config_path "$container")"; then
            continue
        fi
        [[ -f "$config" ]] || continue
        if ! config_parses "$config"; then
            result="$(config_parse_result "$container")"
            results="$(jq -c --argjson item "$result" '. + [$item]' <<< "$results")"
            continue
        fi
        if config_dependency_sources_shape_invalid "$config"; then
            result="$(config_shape_result "$container")"
            results="$(jq -c --argjson item "$result" '. + [$item]' <<< "$results")"
            continue
        fi
        deps="$(monitored_deps "$config")"
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            if ! gpg_key_shape_valid "$config" "$dep"; then
                result="$(gpg_key_shape_result "$container" "$dep")"
            else
                result="$(check_dep "$container" "$dep" "$config" "$cli_warn_days")"
            fi
            results="$(jq -c --argjson item "$result" '. + [$item]' <<< "$results")"
        done <<< "$deps"
    done

    if [[ "$json" == "true" ]]; then
        jq -c '.' <<< "$results"
    else
        jq -r '.[] | "\(.container)/\(.dependency): contract=\(.contract.status // "ok") expiry=\(.expiry.status) rotation=\(.rotation.status)"' <<< "$results"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
