#!/bin/bash
# Dependency freshness resolvers for SBOM changelog enrichment.
#
# Public entry points:
#   _freshness_resolver_for <pkg_type>
#
# Resolver output shape:
#   {"latest":"X.Y.Z","query_failed":false}
#   {"latest":null,"query_failed":true}

set -euo pipefail

_DEPENDENCY_FRESHNESS_HELPER="${BASH_SOURCE[0]}"

_freshness_resolver_for() {
    case "${1:-}" in
        npm) echo "_freshness_npm" ;;
        gem) echo "_freshness_gem" ;;
        pypi|pip) echo "_freshness_pypi" ;;
        apk) echo "_freshness_apk" ;;
        *) echo "" ;;
    esac
}

_freshness_json_failure() {
    jq -cn '{latest:null, query_failed:true}'
}

_freshness_json_success() {
    local latest="$1"
    jq -cn --arg latest "$latest" '{latest:$latest, query_failed:false}'
}

_freshness_urlencode() {
    jq -nr --arg value "$1" '$value | @uri'
}

_freshness_regex_escape() {
    sed -e 's/[][(){}.^$*+?|\\]/\\&/g' <<< "${1:-}"
}

_freshness_gha_escape() {
    local value="${1:-}"
    value="${value//'%'/'%25'}"
    value="${value//$'\r'/'%0D'}"
    value="${value//$'\n'/'%0A'}"
    printf '%s' "$value"
}

_freshness_warn() {
    printf '::warning::dependency freshness: %s\n' "$(_freshness_gha_escape "$*")" >&2
}

_freshness_normalize_name() {
    local pkg_type="$1"
    local name="$2"
    case "$pkg_type" in
        npm|gem) printf '%s' "$name" | tr '[:upper:]' '[:lower:]' ;;
        *) printf '%s' "$name" ;;
    esac
}

_freshness_numeric_tuple() {
    local version="$1"
    if [[ "$version" =~ ^([0-9]+([.][0-9]+)*) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

_freshness_normalize_numeric_component() {
    local component="$1"
    while [[ "$component" == 0* && "$component" != "0" ]]; do
        component="${component#0}"
    done
    printf '%s\n' "$component"
}

_freshness_numeric_version_gt() {
    local candidate="$1"
    local current="$2"
    local candidate_tuple current_tuple candidate_part current_part index max_parts
    local -a candidate_parts current_parts

    [[ -n "$candidate" && -n "$current" ]] || return 2
    candidate_tuple=$(_freshness_numeric_tuple "$candidate") || return 2
    current_tuple=$(_freshness_numeric_tuple "$current") || return 2

    local IFS=.
    read -r -a candidate_parts <<< "$candidate_tuple"
    read -r -a current_parts <<< "$current_tuple"

    max_parts="${#candidate_parts[@]}"
    if (( ${#current_parts[@]} > max_parts )); then
        max_parts="${#current_parts[@]}"
    fi

    for ((index = 0; index < max_parts; index++)); do
        candidate_part=$(_freshness_normalize_numeric_component "${candidate_parts[index]:-0}")
        current_part=$(_freshness_normalize_numeric_component "${current_parts[index]:-0}")

        if (( ${#candidate_part} > ${#current_part} )); then
            return 0
        fi
        if (( ${#candidate_part} < ${#current_part} )); then
            return 1
        fi
        if [[ "$candidate_part" > "$current_part" ]]; then
            return 0
        fi
        if [[ "$candidate_part" < "$current_part" ]]; then
            return 1
        fi
    done

    return 1
}

_freshness_version_gt() {
    local pkg_type="$1"
    local candidate="$2"
    local current="$3"
    local status

    case "$pkg_type" in
        apk)
            if _freshness_apk_version_gt "$candidate" "$current"; then
                return 0
            fi
            return 1
            ;;
        npm|gem|pypi|pip)
            if _freshness_numeric_version_gt "$candidate" "$current"; then
                return 0
            else
                status=$?
                return "$status"
            fi
            ;;
        *)
            return 2
            ;;
    esac
}

_freshness_log_call() {
    if [[ -n "${DEPENDENCY_FRESHNESS_CALL_LOG:-}" ]]; then
        printf '%s\n' "$*" >> "$DEPENDENCY_FRESHNESS_CALL_LOG" 2>/dev/null || true
    fi
}

_freshness_fixture_latest() {
    local pkg_type="$1"
    local name="$2"
    local fixture="${_DEPENDENCY_FRESHNESS_FIXTURE:-}"

    [[ -n "$fixture" && -f "$fixture" ]] || return 1
    _freshness_log_call "latest ${pkg_type} ${name}"

    local result
    result=$(jq -c --arg pkg_type "$pkg_type" --arg name "$name" '
        .latest[$pkg_type][$name] // empty
    ' "$fixture" 2>/dev/null || true)
    [[ -n "$result" ]] || return 1
    jq -cn --argjson result "$result" '
        if ($result.query_failed // false) then
            {latest:null, query_failed:true}
        else
            {latest:($result.latest // null), query_failed:(($result.latest // null) == null)}
        end
    '
}

_freshness_http_get() {
    local url="$1"
    local max_filesize="${2:-}"
    local body_file status
    body_file=$(mktemp)
    local curl_args=(
        -sS -L
        --connect-timeout 5
        --max-time 5
        -H "Accept: application/json"
        -o "$body_file"
        -w '%{http_code}'
    )
    if [[ -n "$max_filesize" ]]; then
        curl_args+=(--max-filesize "$max_filesize")
    fi

    status=$(
        curl "${curl_args[@]}" "$url" 2>/dev/null || printf '000'
    )

    if [[ "$status" == "429" ]]; then
        sleep "${DEPENDENCY_FRESHNESS_429_BACKOFF_SECONDS:-2}"
        status=$(
            curl "${curl_args[@]}" "$url" 2>/dev/null || printf '000'
        )
    fi

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        cat "$body_file"
        rm -f "$body_file"
        return 0
    fi

    rm -f "$body_file"
    return 1
}

_freshness_http_download() {
    local url="$1"
    local output_file="$2"
    local max_filesize="${3:-}"
    local status
    local curl_args=(
        -sS -L
        --connect-timeout 5
        --max-time 5
        -o "$output_file"
        -w '%{http_code}'
    )
    if [[ -n "$max_filesize" ]]; then
        curl_args+=(--max-filesize "$max_filesize")
    fi

    status=$(
        curl "${curl_args[@]}" "$url" 2>/dev/null || printf '000'
    )

    if [[ "$status" == "429" ]]; then
        sleep "${DEPENDENCY_FRESHNESS_429_BACKOFF_SECONDS:-2}"
        status=$(
            curl "${curl_args[@]}" "$url" 2>/dev/null || printf '000'
        )
    fi

    [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

_freshness_npm() {
    local name="${1:-}"
    [[ -n "$name" ]] || { _freshness_json_failure; return 0; }

    if _freshness_fixture_latest npm "$name"; then
        return 0
    fi

    local encoded body latest
    encoded=$(_freshness_urlencode "$name")
    if ! body=$(_freshness_http_get \
        "https://registry.npmjs.org/${encoded}/latest" \
        "${DEPENDENCY_FRESHNESS_NPM_JSON_MAX_BYTES:-10485760}"); then
        _freshness_json_failure
        return 0
    fi

    latest=$(jq -r '.version // empty' <<< "$body" 2>/dev/null || true)
    [[ -n "$latest" ]] || { _freshness_json_failure; return 0; }
    _freshness_json_success "$latest"
}

_freshness_gem() {
    local name="${1:-}"
    [[ -n "$name" ]] || { _freshness_json_failure; return 0; }

    if _freshness_fixture_latest gem "$name"; then
        return 0
    fi

    local encoded body latest
    encoded=$(_freshness_urlencode "$name")
    if ! body=$(_freshness_http_get \
        "https://rubygems.org/api/v1/versions/${encoded}/latest.json" \
        "${DEPENDENCY_FRESHNESS_GEM_JSON_MAX_BYTES:-10485760}"); then
        _freshness_json_failure
        return 0
    fi

    latest=$(jq -r '.version // empty' <<< "$body" 2>/dev/null || true)
    [[ -n "$latest" ]] || { _freshness_json_failure; return 0; }
    _freshness_json_success "$latest"
}

_freshness_pypi() {
    local name="${1:-}"
    [[ -n "$name" ]] || { _freshness_json_failure; return 0; }

    if _freshness_fixture_latest pypi "$name"; then
        return 0
    fi

    local encoded body latest
    encoded=$(_freshness_urlencode "$name")
    if ! body=$(_freshness_http_get \
        "https://pypi.org/pypi/${encoded}/json" \
        "${DEPENDENCY_FRESHNESS_PYPI_JSON_MAX_BYTES:-10485760}"); then
        _freshness_json_failure
        return 0
    fi

    latest=$(jq -r '.info.version // empty' <<< "$body" 2>/dev/null || true)
    [[ -n "$latest" ]] || { _freshness_json_failure; return 0; }
    _freshness_json_success "$latest"
}

_freshness_deb() {
    local name="${1:-}"
    [[ -n "$name" ]] || { _freshness_json_failure; return 0; }

    if _freshness_fixture_latest deb "$name"; then
        return 0
    fi

    _freshness_json_failure
}

declare -gA _FRESHNESS_APK_PACKAGES=()
declare -g _FRESHNESS_APK_INDEX_LOADED=0
declare -g _FRESHNESS_APK_INDEX_FAILED=0

_freshness_reset_apk_state() {
    declare -gA _FRESHNESS_APK_PACKAGES=()
    _FRESHNESS_APK_INDEX_LOADED=0
    _FRESHNESS_APK_INDEX_FAILED=0
}

_freshness_apk_arch() {
    if [[ -n "${DEPENDENCY_FRESHNESS_APK_ARCH:-${_DEPENDENCY_FRESHNESS_APK_ARCH:-}}" ]]; then
        printf '%s' "${DEPENDENCY_FRESHNESS_APK_ARCH:-${_DEPENDENCY_FRESHNESS_APK_ARCH:-}}"
        return 0
    fi

    case "${DEPENDENCY_FRESHNESS_PLATFORM:-}" in
        linux/amd64) echo "x86_64" ;;
        linux/arm64) echo "aarch64" ;;
        linux/386) echo "x86" ;;
        linux/arm/v7) echo "armv7" ;;
        *) return 1 ;;
    esac
}

_freshness_apk_repositories() {
    if [[ -n "${_DEPENDENCY_FRESHNESS_APK_REPOSITORIES_FIXTURE:-}" ]]; then
        cat "$_DEPENDENCY_FRESHNESS_APK_REPOSITORIES_FIXTURE"
        return 0
    fi
    if [[ -n "${DEPENDENCY_FRESHNESS_APK_REPOSITORIES:-}" ]]; then
        printf '%s\n' "$DEPENDENCY_FRESHNESS_APK_REPOSITORIES"
        return 0
    fi
    if [[ -n "${DEPENDENCY_FRESHNESS_IMAGE_REF:-}" ]] && command -v docker >/dev/null 2>&1; then
        local container_id tmpdir status
        local -a docker_create_args

        docker_create_args=(create)
        if [[ -n "${DEPENDENCY_FRESHNESS_PLATFORM:-}" ]]; then
            docker_create_args+=(--platform "$DEPENDENCY_FRESHNESS_PLATFORM")
        fi
        docker_create_args+=("$DEPENDENCY_FRESHNESS_IMAGE_REF")

        tmpdir=$(mktemp -d)
        if ! container_id=$(timeout 20 docker "${docker_create_args[@]}" 2>/dev/null); then
            rm -rf "$tmpdir"
            return 1
        fi

        status=0
        if timeout 20 docker cp "${container_id}:/etc/apk/repositories" "${tmpdir}/repositories" 2>/dev/null; then
            cat "${tmpdir}/repositories"
        else
            status=1
        fi
        timeout 20 docker rm "$container_id" >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        return "$status"
    fi
    return 1
}

_freshness_apk_repo_url_allowed() {
    local url="$1"
    local allow_regex="${DEPENDENCY_FRESHNESS_APK_REPOSITORY_ALLOW_REGEX:-^https://([A-Za-z0-9-]+\.)*alpinelinux\.org/alpine(/|$)}"
    [[ "$url" =~ $allow_regex ]]
}

_freshness_apk_index_urls() {
    local arch="$1"
    local repos="$2"
    awk -v arch="$arch" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line=$0
            sub(/[[:space:]]+#.*$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "") next
            split(line, parts, /[[:space:]]+/)
            if (parts[1] ~ /^@[^[:space:]]+$/) next
            url=parts[1]
            if (url == "") next
            sub(/\/$/, "", url)
            print url
        }
    ' <<< "$repos" | while IFS= read -r repo_url; do
        if _freshness_apk_repo_url_allowed "$repo_url"; then
            printf '%s/%s/APKINDEX.tar.gz\n' "${repo_url%/}" "$arch"
        else
            printf 'WARN: skipping untrusted APK repository URL: %s\n' "$repo_url" >&2
        fi
    done | sort -u
}

_freshness_apk_version_gt() {
    local candidate="$1"
    local current="$2"
    local result py_status

    [[ -n "$candidate" ]] || return 1
    [[ -n "$current" ]] || return 0

    if command -v apk >/dev/null 2>&1; then
        result=$(apk version -t "$candidate" "$current" 2>/dev/null || true)
        [[ "$result" == ">" ]] && return 0
        [[ "$result" == "<" || "$result" == "=" ]] && return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        py_status=0
        python3 - "$candidate" "$current" <<'PY' || py_status=$?
import re
import sys

TOKEN_INITIAL_DIGIT = 0
TOKEN_DIGIT = 1
TOKEN_LETTER = 2
TOKEN_SUFFIX = 3
TOKEN_SUFFIX_NO = 4
TOKEN_COMMIT_HASH = 5
TOKEN_REVISION_NO = 6
TOKEN_END = 7
TOKEN_INVALID = 8

SUFFIX_INVALID = 0
SUFFIX_NONE = 5
SUFFIXES = {
    "alpha": 1,
    "beta": 2,
    "pre": 3,
    "rc": 4,
    "": SUFFIX_NONE,
    "cvs": 6,
    "svn": 7,
    "git": 8,
    "hg": 9,
    "p": 10,
}


def _digit_token(token, value, pos):
    if not value:
        return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
    return {"token": token, "value": value, "number": int(value), "suffix": SUFFIX_INVALID, "pos": pos}


def first_token(version):
    match = re.match(r"[0-9]+", version)
    if not match:
        return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": 0}
    return _digit_token(TOKEN_INITIAL_DIGIT, match.group(0), match.end())


def next_token(version, prev):
    pos = prev["pos"]
    prev_token = prev["token"]
    if pos >= len(version):
        return {"token": TOKEN_END, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}

    ch = version[pos]
    if "a" <= ch <= "z":
        if prev_token > TOKEN_DIGIT:
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        return {"token": TOKEN_LETTER, "value": ch, "number": ord(ch), "suffix": SUFFIX_INVALID, "pos": pos + 1}

    if ch == ".":
        if prev_token > TOKEN_DIGIT:
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        pos += 1
        ch = version[pos] if pos < len(version) else ""

    if ch.isdigit():
        if prev_token in (TOKEN_INITIAL_DIGIT, TOKEN_DIGIT):
            token = TOKEN_DIGIT
        elif prev_token == TOKEN_SUFFIX:
            token = TOKEN_SUFFIX_NO
        else:
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        match = re.match(r"[0-9]+", version[pos:])
        value = match.group(0) if match else ""
        return _digit_token(token, value, pos + len(value))

    if ch == "_":
        if prev_token > TOKEN_SUFFIX_NO:
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        match = re.match(r"[a-z]+", version[pos + 1:])
        value = match.group(0) if match else ""
        suffix = SUFFIXES.get(value, SUFFIX_INVALID)
        if suffix == SUFFIX_INVALID:
            return {"token": TOKEN_INVALID, "value": value, "number": 0, "suffix": suffix, "pos": pos}
        return {"token": TOKEN_SUFFIX, "value": value, "number": suffix, "suffix": suffix, "pos": pos + 1 + len(value)}

    if ch == "~":
        if prev_token >= TOKEN_COMMIT_HASH:
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        match = re.match(r"[0-9A-Fa-f]+", version[pos + 1:])
        value = match.group(0) if match else ""
        if not value:
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        return {"token": TOKEN_COMMIT_HASH, "value": value, "number": 0, "suffix": SUFFIX_INVALID, "pos": pos + 1 + len(value)}

    if ch == "-":
        if prev_token >= TOKEN_REVISION_NO or not version.startswith("-r", pos):
            return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}
        pos += 2
        match = re.match(r"[0-9]+", version[pos:])
        value = match.group(0) if match else ""
        return _digit_token(TOKEN_REVISION_NO, value, pos + len(value))

    return {"token": TOKEN_INVALID, "value": "", "number": 0, "suffix": SUFFIX_INVALID, "pos": pos}


def token_cmp(left, right):
    token = left["token"]
    if token == TOKEN_DIGIT and (left["value"].startswith("0") or right["value"].startswith("0")):
        return (left["value"] > right["value"]) - (left["value"] < right["value"])
    if token in (TOKEN_INITIAL_DIGIT, TOKEN_DIGIT, TOKEN_SUFFIX_NO, TOKEN_REVISION_NO):
        return (left["number"] > right["number"]) - (left["number"] < right["number"])
    if token == TOKEN_LETTER:
        return (left["number"] > right["number"]) - (left["number"] < right["number"])
    if token == TOKEN_SUFFIX:
        return (left["suffix"] > right["suffix"]) - (left["suffix"] < right["suffix"])
    return (left["value"] > right["value"]) - (left["value"] < right["value"])


def apk_compare(left_version, right_version):
    left = first_token(left_version)
    right = first_token(right_version)
    while left["token"] == right["token"] and left["token"] < TOKEN_END:
        result = token_cmp(left, right)
        if result:
            return result
        left = next_token(left_version, left)
        right = next_token(right_version, right)

    if left["token"] == right["token"]:
        return 0
    if left["token"] == TOKEN_SUFFIX and left["suffix"] < SUFFIX_NONE:
        return -1
    if right["token"] == TOKEN_SUFFIX and right["suffix"] < SUFFIX_NONE:
        return 1
    if left["token"] > right["token"]:
        return -1
    if right["token"] > left["token"]:
        return 1
    return 0


sys.exit(0 if apk_compare(sys.argv[1], sys.argv[2]) > 0 else 1)
PY
        case "$py_status" in
            0) return 0 ;;
            1) return 1 ;;
        esac
    fi

    [[ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n 1)" == "$candidate" && "$candidate" != "$current" ]]
}

_freshness_load_apk_indexes() {
    [[ "$_FRESHNESS_APK_INDEX_LOADED" -eq 1 ]] && return 0
    [[ "$_FRESHNESS_APK_INDEX_FAILED" -eq 1 ]] && return 1

    local fixture="${_DEPENDENCY_FRESHNESS_FIXTURE:-}"
    if [[ -n "$fixture" && -f "$fixture" ]] && jq -e '.apk.packages? // empty' "$fixture" >/dev/null 2>&1; then
        while IFS=$'\t' read -r pkg version; do
            [[ -n "$pkg" && -n "$version" ]] || continue
            _FRESHNESS_APK_PACKAGES["$pkg"]="$version"
        done < <(jq -r '.apk.packages | to_entries[] | [.key, .value] | @tsv' "$fixture")
        _FRESHNESS_APK_INDEX_LOADED=1
        return 0
    fi

    local arch repos url tmp pkg version max_download max_unpacked
    max_download="${DEPENDENCY_FRESHNESS_APKINDEX_MAX_BYTES:-10485760}"
    max_unpacked="${DEPENDENCY_FRESHNESS_APKINDEX_MAX_UNPACKED_BYTES:-52428800}"
    if ! arch=$(_freshness_apk_arch); then
        _FRESHNESS_APK_INDEX_FAILED=1
        return 1
    fi
    if ! repos=$(_freshness_apk_repositories); then
        _FRESHNESS_APK_INDEX_FAILED=1
        return 1
    fi

    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        tmp=$(mktemp)
        if _freshness_http_download "$url" "$tmp" "$max_download"; then
            while IFS=$'\t' read -r pkg version; do
                [[ -n "$pkg" && -n "$version" ]] || continue
                if [[ -z "${_FRESHNESS_APK_PACKAGES[$pkg]:-}" ]] \
                    || _freshness_apk_version_gt "$version" "${_FRESHNESS_APK_PACKAGES[$pkg]}"; then
                    _FRESHNESS_APK_PACKAGES["$pkg"]="$version"
                fi
            done < <(tar -xOzf "$tmp" APKINDEX 2>/dev/null | head -c "$max_unpacked" | awk '
                BEGIN { RS=""; FS="\n" }
                {
                    name=""; version="";
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^P:/) name=substr($i, 3);
                        if ($i ~ /^V:/) version=substr($i, 3);
                    }
                    if (name != "" && version != "") print name "\t" version;
                }
            ')
        fi
        rm -f "$tmp"
    done < <(_freshness_apk_index_urls "$arch" "$repos")

    if [[ "${#_FRESHNESS_APK_PACKAGES[@]}" -eq 0 ]]; then
        _FRESHNESS_APK_INDEX_FAILED=1
        return 1
    fi

    _FRESHNESS_APK_INDEX_LOADED=1
    return 0
}

_freshness_apk() {
    local name="${1:-}"
    [[ -n "$name" ]] || { _freshness_json_failure; return 0; }
    _freshness_log_call "latest apk ${name}"

    if _freshness_fixture_latest apk "$name"; then
        return 0
    fi
    if ! _freshness_load_apk_indexes; then
        _freshness_json_failure
        return 0
    fi

    local latest="${_FRESHNESS_APK_PACKAGES[$name]:-}"
    [[ -n "$latest" ]] || { _freshness_json_failure; return 0; }
    _freshness_json_success "$latest"
}

_freshness_concurrency() {
    local concurrency="${DEPENDENCY_FRESHNESS_CONCURRENCY:-4}"
    local max_concurrency=16
    [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || concurrency=4
    if (( concurrency > max_concurrency )); then
        concurrency="$max_concurrency"
    fi
    printf '%s\n' "$concurrency"
}

_freshness_latest_worker() {
    local encoded="$1"
    local query pkg_type name resolver result

    query=$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)
    pkg_type=$(jq -r '.pkg_type // empty' <<< "$query" 2>/dev/null || true)
    name=$(jq -r '.name // empty' <<< "$query" 2>/dev/null || true)

    resolver=$(_freshness_resolver_for "$pkg_type")
    if [[ -z "$resolver" || -z "$name" ]]; then
        jq -cn --arg pkg_type "$pkg_type" --arg name "$name" \
            '{pkg_type:$pkg_type, name:$name, latest:null, query_failed:false}'
        return 0
    fi

    result=$("$resolver" "$name" 2>/dev/null || _freshness_json_failure)
    if ! jq -e 'has("latest") and has("query_failed")' <<< "$result" >/dev/null 2>&1; then
        result=$(_freshness_json_failure)
    fi

    jq -cn \
        --arg pkg_type "$pkg_type" \
        --arg name "$name" \
        --argjson result "$result" \
        '{
            pkg_type:$pkg_type,
            name:$name,
            latest:$result.latest,
            query_failed:(if ($result | has("query_failed")) then $result.query_failed else true end)
        }'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        __latest_worker)
            _freshness_latest_worker "${2:-}"
            ;;
        *)
            echo "usage: $0 __latest_worker <base64-query>" >&2
            exit 2
            ;;
    esac
fi
