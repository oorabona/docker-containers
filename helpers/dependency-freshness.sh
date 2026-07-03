#!/bin/bash
# Dependency freshness resolvers for SBOM changelog enrichment.
#
# Public entry points:
#   _freshness_resolver_for <pkg_type>
#   _freshness_constraints_for_batch <pkg_type> <changes_json>
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
        deb) echo "_freshness_deb" ;;
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

_freshness_normalize_name() {
    local pkg_type="$1"
    local name="$2"
    case "$pkg_type" in
        npm|gem) printf '%s' "$name" | tr '[:upper:]' '[:lower:]' ;;
        *) printf '%s' "$name" ;;
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
    local body_file status
    body_file=$(mktemp)

    status=$(
        curl -sS -L \
            --connect-timeout 5 \
            --max-time 5 \
            -H "Accept: application/json" \
            -o "$body_file" \
            -w '%{http_code}' \
            "$url" 2>/dev/null || printf '000'
    )

    if [[ "$status" == "429" ]]; then
        sleep "${DEPENDENCY_FRESHNESS_429_BACKOFF_SECONDS:-2}"
        status=$(
            curl -sS -L \
                --connect-timeout 5 \
                --max-time 5 \
                -H "Accept: application/json" \
                -o "$body_file" \
                -w '%{http_code}' \
                "$url" 2>/dev/null || printf '000'
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
    local status

    status=$(
        curl -sS -L \
            --connect-timeout 5 \
            --max-time 5 \
            -o "$output_file" \
            -w '%{http_code}' \
            "$url" 2>/dev/null || printf '000'
    )

    if [[ "$status" == "429" ]]; then
        sleep "${DEPENDENCY_FRESHNESS_429_BACKOFF_SECONDS:-2}"
        status=$(
            curl -sS -L \
                --connect-timeout 5 \
                --max-time 5 \
                -o "$output_file" \
                -w '%{http_code}' \
                "$url" 2>/dev/null || printf '000'
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
    if ! body=$(_freshness_http_get "https://registry.npmjs.org/${encoded}/latest"); then
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
    if ! body=$(_freshness_http_get "https://rubygems.org/api/v1/versions/${encoded}/latest.json"); then
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
    if ! body=$(_freshness_http_get "https://pypi.org/pypi/${encoded}/json"); then
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

    local encoded body latest
    encoded=$(_freshness_urlencode "$name")
    if ! body=$(_freshness_http_get "https://sources.debian.org/api/src/${encoded}/"); then
        _freshness_json_failure
        return 0
    fi

    latest=$(jq -r '(.versions // [] | map(select(.version?)) | first.version) // .version // empty' <<< "$body" 2>/dev/null || true)
    [[ -n "$latest" ]] || { _freshness_json_failure; return 0; }
    _freshness_json_success "$latest"
}

declare -gA _FRESHNESS_APK_PACKAGES=()
declare -g _FRESHNESS_APK_INDEX_LOADED=0
declare -g _FRESHNESS_APK_INDEX_FAILED=0

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
        timeout 20 docker run --rm "$DEPENDENCY_FRESHNESS_IMAGE_REF" cat /etc/apk/repositories 2>/dev/null
        return $?
    fi
    return 1
}

_freshness_apk_index_urls() {
    local arch="$1"
    local repos="$2"
    awk -v arch="$arch" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            url=$0
            sub(/^[[:space:]]+/, "", url)
            sub(/[[:space:]]+$/, "", url)
            sub(/\/$/, "", url)
            print url "/" arch "/APKINDEX.tar.gz"
        }
    ' <<< "$repos" | sort -u
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

    local arch repos url tmp pkg version
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
        if _freshness_http_download "$url" "$tmp"; then
            while IFS=$'\t' read -r pkg version; do
                if [[ -n "$pkg" && -n "$version" && -z "${_FRESHNESS_APK_PACKAGES[$pkg]:-}" ]]; then
                    _FRESHNESS_APK_PACKAGES["$pkg"]="$version"
                fi
            done < <(tar -xOzf "$tmp" APKINDEX 2>/dev/null | awk '
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

_freshness_fixture_manifest() {
    local pkg_type="$1"
    local name="$2"
    local version="$3"
    local fixture="${_DEPENDENCY_FRESHNESS_FIXTURE:-}"

    [[ -n "$fixture" && -f "$fixture" ]] || return 1
    _freshness_log_call "manifest ${pkg_type} ${name}@${version}"

    case "$pkg_type" in
        npm)
            jq -c --arg name "$name" --arg version "$version" '
                .manifests.npm[($name + "@" + $version)] // empty
            ' "$fixture" 2>/dev/null
            ;;
        gem)
            jq -c --arg name "$name" '
                .manifests.gem[$name] // empty
            ' "$fixture" 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

_freshness_fetch_npm_manifest() {
    local name="$1"
    local version="$2"
    local fixture_result encoded_name encoded_version body

    fixture_result=$(_freshness_fixture_manifest npm "$name" "$version" || true)
    if [[ -n "$fixture_result" ]]; then
        printf '%s\n' "$fixture_result"
        return 0
    fi

    encoded_name=$(_freshness_urlencode "$name")
    encoded_version=$(_freshness_urlencode "$version")
    if ! body=$(_freshness_http_get "https://registry.npmjs.org/${encoded_name}/${encoded_version}"); then
        return 1
    fi
    printf '%s\n' "$body"
}

_freshness_fetch_gem_versions() {
    local name="$1"
    local fixture_result encoded body

    fixture_result=$(_freshness_fixture_manifest gem "$name" "_" || true)
    if [[ -n "$fixture_result" ]]; then
        printf '%s\n' "$fixture_result"
        return 0
    fi

    encoded=$(_freshness_urlencode "$name")
    if ! body=$(_freshness_http_get "https://rubygems.org/api/v1/versions/${encoded}.json"); then
        return 1
    fi
    printf '%s\n' "$body"
}

_freshness_constraints_for_batch() {
    local pkg_type="$1"
    local changes_json="$2"

    case "$pkg_type" in
        npm) _freshness_npm_constraints_for_batch "$changes_json" ;;
        gem) _freshness_gem_constraints_for_batch "$changes_json" ;;
        *) jq -cn '[]' ;;
    esac
}

_freshness_npm_constraints_for_batch() {
    local changes_json="$1"
    local manifests="[]"
    local row name version manifest

    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row")
        version=$(jq -r '.installed' <<< "$row")
        [[ -n "$name" && -n "$version" && "$version" != "null" ]] || continue
        if manifest=$(_freshness_fetch_npm_manifest "$name" "$version" 2>/dev/null); then
            manifests=$(jq -cn \
                --argjson manifests "$manifests" \
                --arg parent "$name" \
                --arg parent_version "$version" \
                --argjson manifest "$manifest" \
                '$manifests + [{parent:$parent, parent_version:$parent_version, manifest:$manifest}]')
        fi
    done < <(jq -c '[.[] | select(.pkg_type == "npm") | {name, installed}] | unique_by([.name, .installed])[]' <<< "$changes_json")

    jq -cn --argjson manifests "$manifests" '
        [
            $manifests[] as $m
            | (($m.manifest.dependencies // {}) + ($m.manifest.peerDependencies // {})) as $deps
            | $deps
            | to_entries[]
            | {
                pkg_type: "npm",
                child: (.key | ascii_downcase),
                parent: $m.parent,
                parent_version: $m.parent_version,
                range: (.value | tostring)
              }
        ]
    '
}

_freshness_gem_constraints_for_batch() {
    local changes_json="$1"
    local manifests="[]"
    local row name version versions_json

    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row")
        version=$(jq -r '.installed' <<< "$row")
        [[ -n "$name" && -n "$version" && "$version" != "null" ]] || continue
        if versions_json=$(_freshness_fetch_gem_versions "$name" 2>/dev/null); then
            manifests=$(jq -cn \
                --argjson manifests "$manifests" \
                --arg parent "$name" \
                --arg parent_version "$version" \
                --argjson versions "$versions_json" \
                '$manifests + [{parent:$parent, parent_version:$parent_version, versions:$versions}]')
        fi
    done < <(jq -c '[.[] | select(.pkg_type == "gem") | {name, installed}] | unique_by([.name, .installed])[]' <<< "$changes_json")

    jq -cn --argjson manifests "$manifests" '
        [
            $manifests[] as $m
            | ($m.versions // [])
            | map(select((.number // "") == $m.parent_version))
            | first // null
            | select(. != null)
            | (.dependencies.runtime // [])
            | .[]
            | {
                pkg_type: "gem",
                child: ((.name // "") | ascii_downcase),
                parent: $m.parent,
                parent_version: $m.parent_version,
                range: ((.requirements // .requirement // "") | tostring)
              }
        ]
    '
}

_freshness_semver_parts() {
    local version="${1#v}"
    version="${version%%[-+]*}"
    IFS='.' read -r a b c _ <<< "$version"
    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "${b:-0}" =~ ^[0-9]+$ ]] || return 1
    [[ "${c:-0}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\t%s\n' "$a" "${b:-0}" "${c:-0}"
}

_freshness_semver_cmp() {
    local left="$1"
    local right="$2"
    local la lb lc ra rb rc
    IFS=$'\t' read -r la lb lc < <(_freshness_semver_parts "$left") || return 2
    IFS=$'\t' read -r ra rb rc < <(_freshness_semver_parts "$right") || return 2

    if (( la < ra )); then echo -1; return 0; fi
    if (( la > ra )); then echo 1; return 0; fi
    if (( lb < rb )); then echo -1; return 0; fi
    if (( lb > rb )); then echo 1; return 0; fi
    if (( lc < rc )); then echo -1; return 0; fi
    if (( lc > rc )); then echo 1; return 0; fi
    echo 0
}

_freshness_semver_compare_op() {
    local version="$1"
    local op="$2"
    local bound="$3"
    local cmp
    cmp=$(_freshness_semver_cmp "$version" "$bound") || return 1
    case "$op" in
        "<")  (( cmp < 0 )) ;;
        "<=") (( cmp <= 0 )) ;;
        ">")  (( cmp > 0 )) ;;
        ">=") (( cmp >= 0 )) ;;
        "="|"") (( cmp == 0 )) ;;
        *) return 1 ;;
    esac
}

_freshness_semver_upper_for_caret() {
    local version="$1"
    local a b c
    IFS=$'\t' read -r a b c < <(_freshness_semver_parts "$version") || return 1
    if (( a > 0 )); then
        printf '%s.0.0\n' "$((a + 1))"
    elif (( b > 0 )); then
        printf '0.%s.0\n' "$((b + 1))"
    else
        printf '0.0.%s\n' "$((c + 1))"
    fi
}

_freshness_semver_upper_for_tilde() {
    local version="$1"
    local a b c
    IFS=$'\t' read -r a b c < <(_freshness_semver_parts "$version") || return 1
    printf '%s.%s.0\n' "$a" "$((b + 1))"
}

_freshness_semver_upper_for_gem_pessimistic() {
    local version="$1"
    local a b c dot_count
    IFS=$'\t' read -r a b c < <(_freshness_semver_parts "$version") || return 1
    dot_count=$(grep -o '\.' <<< "${version%%[-+]*}" | wc -l | tr -d ' ')
    if (( dot_count >= 2 )); then
        printf '%s.%s.0\n' "$a" "$((b + 1))"
    else
        printf '%s.0.0\n' "$((a + 1))"
    fi
}

_freshness_range_conj_includes() {
    local pkg_type="$1"
    local range="$2"
    local version="$3"
    local token op bound upper

    range="${range//,/ }"
    range="${range//\"/}"
    range="${range//\'/}"

    for token in $range; do
        [[ -n "$token" ]] || continue
        case "$token" in
            "||") return 1 ;;
            "*"|"x"|"X") continue ;;
            ^*)
                bound="${token#^}"
                upper=$(_freshness_semver_upper_for_caret "$bound") || return 1
                _freshness_semver_compare_op "$version" ">=" "$bound" || return 1
                _freshness_semver_compare_op "$version" "<" "$upper" || return 1
                ;;
            "~>"*)
                bound="${token#~>}"
                upper=$(_freshness_semver_upper_for_gem_pessimistic "$bound") || return 1
                _freshness_semver_compare_op "$version" ">=" "$bound" || return 1
                _freshness_semver_compare_op "$version" "<" "$upper" || return 1
                ;;
            "~"*)
                bound="${token#~}"
                upper=$(_freshness_semver_upper_for_tilde "$bound") || return 1
                _freshness_semver_compare_op "$version" ">=" "$bound" || return 1
                _freshness_semver_compare_op "$version" "<" "$upper" || return 1
                ;;
            ">="*|"<="*)
                op="${token:0:2}"
                bound="${token:2}"
                _freshness_semver_compare_op "$version" "$op" "$bound" || return 1
                ;;
            ">"*|"<"*)
                op="${token:0:1}"
                bound="${token:1}"
                _freshness_semver_compare_op "$version" "$op" "$bound" || return 1
                ;;
            "="*)
                bound="${token#=}"
                _freshness_semver_compare_op "$version" "=" "$bound" || return 1
                ;;
            *)
                if [[ "$token" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
                    _freshness_semver_compare_op "$version" "=" "$token" || return 1
                elif [[ "$token" =~ ^[0-9]+\.x$ ]]; then
                    bound="${token%.x}.0.0"
                    upper="$(( ${token%%.*} + 1 )).0.0"
                    _freshness_semver_compare_op "$version" ">=" "$bound" || return 1
                    _freshness_semver_compare_op "$version" "<" "$upper" || return 1
                else
                    return 1
                fi
                ;;
        esac
    done

    return 0
}

_freshness_range_includes() {
    local pkg_type="$1"
    local range="$2"
    local version="$3"
    local part

    [[ -n "$range" && -n "$version" ]] || return 1
    if [[ "$range" == *"||"* ]]; then
        while IFS= read -r part; do
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            _freshness_range_conj_includes "$pkg_type" "$part" "$version" && return 0
        done < <(tr '|' '\n' <<< "$range" | sed '/^[[:space:]]*$/d')
        return 1
    fi

    _freshness_range_conj_includes "$pkg_type" "$range" "$version"
}

_freshness_find_capping_constraint() {
    local pkg_type="$1"
    local name="$2"
    local installed="$3"
    local latest="$4"
    local constraints_json="$5"
    local normalized constraint range parent

    [[ -n "$latest" && "$latest" != "null" ]] || return 1
    normalized=$(_freshness_normalize_name "$pkg_type" "$name")

    while IFS= read -r constraint; do
        range=$(jq -r '.range // empty' <<< "$constraint")
        parent=$(jq -r '.parent // empty' <<< "$constraint")
        [[ -n "$range" && -n "$parent" ]] || continue
        if _freshness_range_includes "$pkg_type" "$range" "$installed" \
            && ! _freshness_range_includes "$pkg_type" "$range" "$latest"; then
            printf '%s %s\n' "$parent" "$range"
            return 0
        fi
    done < <(jq -c --arg child "$normalized" '.[] | select(.child == $child)' <<< "$constraints_json")

    return 1
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
