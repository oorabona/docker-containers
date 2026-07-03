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

    _freshness_json_failure
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
        timeout 20 docker run --rm --entrypoint cat "$DEPENDENCY_FRESHNESS_IMAGE_REF" /etc/apk/repositories 2>/dev/null
        return $?
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
            if (parts[1] ~ /^@[^[:space:]]+$/) {
                url=parts[2]
            } else {
                url=parts[1]
            }
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
    local result

    [[ -n "$candidate" ]] || return 1
    [[ -n "$current" ]] || return 0

    if command -v apk >/dev/null 2>&1; then
        result=$(apk version -t "$candidate" "$current" 2>/dev/null || true)
        [[ "$result" == ">" ]] && return 0
        [[ "$result" == "<" || "$result" == "=" ]] && return 1
    fi

    if command -v dpkg >/dev/null 2>&1; then
        dpkg --compare-versions "$candidate" gt "$current" 2>/dev/null && return 0
        return 1
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

_freshness_concurrency() {
    local concurrency="${DEPENDENCY_FRESHNESS_CONCURRENCY:-4}"
    [[ "$concurrency" =~ ^[1-9][0-9]*$ ]] || concurrency=4
    printf '%s\n' "$concurrency"
}

_freshness_json_is_type() {
    local json="$1"
    local expected_type="$2"
    jq -e --arg expected_type "$expected_type" 'type == $expected_type' <<< "$json" >/dev/null 2>&1
}

_freshness_constraint_manifest_worker() {
    local pkg_type="$1"
    local encoded="$2"
    local row name version payload expected_type

    row=$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)
    name=$(jq -r '.name // empty' <<< "$row" 2>/dev/null || true)
    version=$(jq -r '.installed // empty' <<< "$row" 2>/dev/null || true)
    [[ -n "$name" && -n "$version" && "$version" != "null" ]] || return 0

    case "$pkg_type" in
        npm)
            expected_type="object"
            if ! payload=$(_freshness_fetch_npm_manifest "$name" "$version" 2>/dev/null); then
                return 0
            fi
            ;;
        gem)
            expected_type="array"
            if ! payload=$(_freshness_fetch_gem_versions "$name" 2>/dev/null); then
                return 0
            fi
            ;;
        *) return 0 ;;
    esac

    if ! _freshness_json_is_type "$payload" "$expected_type"; then
        printf 'WARN: skipping malformed %s constraint response for %s@%s\n' "$pkg_type" "$name" "$version" >&2
        return 0
    fi

    case "$pkg_type" in
        npm)
            jq -cn \
                --arg parent "$name" \
                --arg parent_version "$version" \
                --argjson manifest "$payload" \
                '{parent:$parent, parent_version:$parent_version, manifest:$manifest}'
            ;;
        gem)
            jq -cn \
                --arg parent "$name" \
                --arg parent_version "$version" \
                --argjson versions "$payload" \
                '{parent:$parent, parent_version:$parent_version, versions:$versions}'
            ;;
    esac
}

_freshness_constraint_worker_results() {
    local pkg_type="$1"
    local changes_json="$2"
    local helper="${_DEPENDENCY_FRESHNESS_HELPER:-${BASH_SOURCE[0]}}"
    local concurrency encoded

    concurrency=$(_freshness_concurrency)
    encoded=$(jq -r --arg pkg_type "$pkg_type" '
        [.[] | select(.pkg_type == $pkg_type) | {name, installed}]
        | unique_by([.name, .installed])
        | .[]
        | @base64
    ' <<< "$changes_json")

    if [[ -z "$encoded" ]]; then
        jq -cn '[]'
        return 0
    fi

    if (( concurrency > 1 )); then
        printf '%s\n' "$encoded" \
            | xargs -r -n1 -P "$concurrency" bash "$helper" __constraint_worker "$pkg_type" \
            | jq -s '.'
    else
        while IFS= read -r row; do
            [[ -n "$row" ]] || continue
            _freshness_constraint_manifest_worker "$pkg_type" "$row"
        done <<< "$encoded" | jq -s '.'
    fi
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
    local manifests
    manifests=$(_freshness_constraint_worker_results npm "$changes_json")

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
    local manifests
    manifests=$(_freshness_constraint_worker_results gem "$changes_json")

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
    local core prerelease
    version="${version%%+*}"
    core="${version%%-*}"
    prerelease=""
    [[ "$version" == *-* ]] && prerelease="${version#*-}"

    local a b c _
    IFS='.' read -r a b c _ <<< "$core"
    [[ "$a" =~ ^[0-9]+$ ]] || return 1
    [[ "${b:-0}" =~ ^[0-9]+$ ]] || return 1
    [[ "${c:-0}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\t%s\t%s\n' "$a" "${b:-0}" "${c:-0}" "$prerelease"
}

_freshness_semver_prerelease_cmp() {
    local left="$1"
    local right="$2"
    local left_parts right_parts max i li ri

    if [[ -z "$left" && -z "$right" ]]; then echo 0; return 0; fi
    if [[ -z "$left" ]]; then echo 1; return 0; fi
    if [[ -z "$right" ]]; then echo -1; return 0; fi

    IFS='.' read -r -a left_parts <<< "$left"
    IFS='.' read -r -a right_parts <<< "$right"
    max="${#left_parts[@]}"
    (( ${#right_parts[@]} > max )) && max="${#right_parts[@]}"

    for (( i=0; i<max; i++ )); do
        if (( i >= ${#left_parts[@]} )); then echo -1; return 0; fi
        if (( i >= ${#right_parts[@]} )); then echo 1; return 0; fi
        li="${left_parts[$i]}"
        ri="${right_parts[$i]}"
        if [[ "$li" =~ ^[0-9]+$ && "$ri" =~ ^[0-9]+$ ]]; then
            if (( 10#$li < 10#$ri )); then echo -1; return 0; fi
            if (( 10#$li > 10#$ri )); then echo 1; return 0; fi
        elif [[ "$li" =~ ^[0-9]+$ ]]; then
            echo -1
            return 0
        elif [[ "$ri" =~ ^[0-9]+$ ]]; then
            echo 1
            return 0
        else
            if [[ "$li" < "$ri" ]]; then echo -1; return 0; fi
            if [[ "$li" > "$ri" ]]; then echo 1; return 0; fi
        fi
    done

    echo 0
}

_freshness_semver_cmp() {
    local left="$1"
    local right="$2"
    local la lb lc lp ra rb rc rp pre_cmp
    IFS=$'\t' read -r la lb lc lp < <(_freshness_semver_parts "$left") || return 2
    IFS=$'\t' read -r ra rb rc rp < <(_freshness_semver_parts "$right") || return 2

    if (( la < ra )); then echo -1; return 0; fi
    if (( la > ra )); then echo 1; return 0; fi
    if (( lb < rb )); then echo -1; return 0; fi
    if (( lb > rb )); then echo 1; return 0; fi
    if (( lc < rc )); then echo -1; return 0; fi
    if (( lc > rc )); then echo 1; return 0; fi

    pre_cmp=$(_freshness_semver_prerelease_cmp "$lp" "$rp") || return 2
    echo "$pre_cmp"
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

_freshness_npm_partial_bounds() {
    local raw="${1#v}"
    local core prerelease a b c _
    raw="${raw%%+*}"
    core="${raw%%-*}"
    prerelease=""
    [[ "$raw" == *-* ]] && prerelease="-${raw#*-}"

    IFS='.' read -r a b c _ <<< "$core"
    if [[ -z "${a:-}" || "$a" =~ ^[xX*]$ ]]; then
        printf 'any\t0.0.0\t\n'
        return 0
    fi
    [[ "$a" =~ ^[0-9]+$ ]] || return 1

    if [[ -z "${b:-}" || "$b" =~ ^[xX*]$ ]]; then
        printf 'major\t%s.0.0\t%s.0.0\n' "$a" "$((10#$a + 1))"
        return 0
    fi
    [[ "$b" =~ ^[0-9]+$ ]] || return 1

    if [[ -z "${c:-}" || "$c" =~ ^[xX*]$ ]]; then
        printf 'minor\t%s.%s.0\t%s.%s.0\n' "$a" "$b" "$a" "$((10#$b + 1))"
        return 0
    fi
    [[ "$c" =~ ^[0-9]+$ ]] || return 1

    printf 'patch\t%s.%s.%s%s\t\n' "$a" "$b" "$c" "$prerelease"
}

_freshness_semver_upper_for_caret() {
    local version="$1"
    local a b c _
    IFS=$'\t' read -r a b c _ < <(_freshness_semver_parts "$version") || return 1
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
    local a b c _
    IFS=$'\t' read -r a b c _ < <(_freshness_semver_parts "$version") || return 1
    printf '%s.%s.0\n' "$a" "$((b + 1))"
}

_freshness_semver_upper_for_gem_pessimistic() {
    local version="$1"
    local a b c _ dot_count
    IFS=$'\t' read -r a b c _ < <(_freshness_semver_parts "$version") || return 1
    dot_count=$(awk -F'.' '{print NF - 1}' <<< "${version%%[-+]*}")
    if (( dot_count >= 2 )); then
        printf '%s.%s.0\n' "$a" "$((b + 1))"
    else
        printf '%s.0.0\n' "$((a + 1))"
    fi
}

_freshness_apply_npm_bound() {
    local version="$1"
    local op="$2"
    local raw_bound="$3"
    local kind min upper

    IFS=$'\t' read -r kind min upper < <(_freshness_npm_partial_bounds "$raw_bound") || return 1
    [[ "$kind" != "any" ]] || return 0

    case "$op" in
        "="|"")
            if [[ -n "$upper" ]]; then
                _freshness_semver_compare_op "$version" ">=" "$min" && _freshness_semver_compare_op "$version" "<" "$upper"
            else
                _freshness_semver_compare_op "$version" "=" "$min"
            fi
            ;;
        ">=") _freshness_semver_compare_op "$version" ">=" "$min" ;;
        ">")
            if [[ -n "$upper" ]]; then
                _freshness_semver_compare_op "$version" ">=" "$upper"
            else
                _freshness_semver_compare_op "$version" ">" "$min"
            fi
            ;;
        "<")
            _freshness_semver_compare_op "$version" "<" "$min"
            ;;
        "<=")
            if [[ -n "$upper" ]]; then
                _freshness_semver_compare_op "$version" "<" "$upper"
            else
                _freshness_semver_compare_op "$version" "<=" "$min"
            fi
            ;;
        *) return 1 ;;
    esac
}

_freshness_npm_upper_for_tilde_bound() {
    local bound="$1"
    local kind min upper a b c _
    IFS=$'\t' read -r kind min upper < <(_freshness_npm_partial_bounds "$bound") || return 1
    case "$kind" in
        any) return 1 ;;
        major|minor) printf '%s\n' "$upper" ;;
        patch)
            IFS=$'\t' read -r a b c _ < <(_freshness_semver_parts "$min") || return 1
            printf '%s.%s.0\n' "$a" "$((b + 1))"
            ;;
        *) return 1 ;;
    esac
}

_freshness_npm_upper_for_caret_bound() {
    local bound="$1"
    local kind min upper a b c _
    IFS=$'\t' read -r kind min upper < <(_freshness_npm_partial_bounds "$bound") || return 1
    [[ "$kind" != "any" ]] || return 1
    IFS=$'\t' read -r a b c _ < <(_freshness_semver_parts "$min") || return 1

    if (( a > 0 )); then
        printf '%s.0.0\n' "$((a + 1))"
    elif (( b > 0 )); then
        printf '0.%s.0\n' "$((b + 1))"
    elif (( c > 0 )); then
        printf '0.0.%s\n' "$((c + 1))"
    elif [[ "$kind" == "major" ]]; then
        printf '1.0.0\n'
    elif [[ "$kind" == "minor" ]]; then
        printf '0.%s.0\n' "$((b + 1))"
    else
        printf '0.0.1\n'
    fi
}

_freshness_npm_token_includes() {
    local token="$1"
    local version="$2"
    local bound upper

    [[ -n "$token" ]] || return 0
    case "$token" in
        "*"|"x"|"X") return 0 ;;
        ^*)
            bound="${token#^}"
            [[ -n "$bound" ]] || return 1
            upper=$(_freshness_npm_upper_for_caret_bound "$bound") || return 1
            _freshness_apply_npm_bound "$version" ">=" "$bound" && _freshness_semver_compare_op "$version" "<" "$upper"
            ;;
        "~"*)
            bound="${token#\~}"
            [[ -n "$bound" ]] || return 1
            upper=$(_freshness_npm_upper_for_tilde_bound "$bound") || return 1
            _freshness_apply_npm_bound "$version" ">=" "$bound" && _freshness_semver_compare_op "$version" "<" "$upper"
            ;;
        ">="*|"<="*)
            _freshness_apply_npm_bound "$version" "${token:0:2}" "${token:2}"
            ;;
        ">"*|"<"*)
            _freshness_apply_npm_bound "$version" "${token:0:1}" "${token:1}"
            ;;
        "="*)
            _freshness_apply_npm_bound "$version" "=" "${token#=}"
            ;;
        *)
            _freshness_apply_npm_bound "$version" "=" "$token"
            ;;
    esac
}

_freshness_npm_range_conj_includes() {
    local range="$1"
    local version="$2"
    local token lower upper

    range="${range//\"/}"
    range="${range//\'/}"
    range="${range//,/ }"
    range=$(sed -E 's/([<>=~^]=?|=)[[:space:]]+/\1/g; s/[[:space:]]+/ /g; s/^ //; s/ $//' <<< "$range")
    [[ -n "$range" ]] || return 1

    if [[ "$range" =~ ^([^[:space:]]+)[[:space:]]+-[[:space:]]+([^[:space:]]+)$ ]]; then
        lower="${BASH_REMATCH[1]}"
        upper="${BASH_REMATCH[2]}"
        _freshness_apply_npm_bound "$version" ">=" "$lower" && _freshness_apply_npm_bound "$version" "<=" "$upper"
        return $?
    fi

    for token in $range; do
        _freshness_npm_token_includes "$token" "$version" || return 1
    done

    return 0
}

declare -g _FRESHNESS_NODE_SEMVER_AVAILABLE=""
_freshness_node_semver_available() {
    if [[ -z "${_FRESHNESS_NODE_SEMVER_AVAILABLE:-}" ]]; then
        if command -v node >/dev/null 2>&1 \
            && node -e "require.resolve('semver')" >/dev/null 2>&1; then
            _FRESHNESS_NODE_SEMVER_AVAILABLE=1
        else
            _FRESHNESS_NODE_SEMVER_AVAILABLE=0
        fi
    fi
    [[ "$_FRESHNESS_NODE_SEMVER_AVAILABLE" == "1" ]]
}

_freshness_npm_range_includes() {
    local range="$1"
    local version="$2"
    local part status

    [[ -n "$range" && -n "$version" ]] || return 1
    if _freshness_node_semver_available; then
        status=0
        node -e 'try { const semver = require("semver"); process.exit(semver.satisfies(process.argv[1], process.argv[2]) ? 0 : 1); } catch (e) { process.exit(2); }' "$version" "$range" || status=$?
        [[ "$status" -eq 0 ]] && return 0
        [[ "$status" -eq 1 ]] && return 1
    fi

    while IFS= read -r part; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ -n "$part" ]] || continue
        _freshness_npm_range_conj_includes "$part" "$version" && return 0
    done < <(sed -E 's/[[:space:]]*\|\|[[:space:]]*/\n/g' <<< "$range")
    return 1
}

declare -g _FRESHNESS_RUBY_AVAILABLE=""
_freshness_ruby_available() {
    if [[ -z "${_FRESHNESS_RUBY_AVAILABLE:-}" ]]; then
        if command -v ruby >/dev/null 2>&1 \
            && ruby -rrubygems -e 'Gem::Requirement.new(">= 0")' >/dev/null 2>&1; then
            _FRESHNESS_RUBY_AVAILABLE=1
        else
            _FRESHNESS_RUBY_AVAILABLE=0
        fi
    fi
    [[ "$_FRESHNESS_RUBY_AVAILABLE" == "1" ]]
}

_freshness_gem_range_fallback_includes() {
    local range="$1"
    local version="$2"
    local token bound upper

    range="${range//\"/}"
    range="${range//\'/}"
    range="${range//,/ }"
    range=$(sed -E 's/(~>|>=|<=|>|<|=)[[:space:]]+/\1/g; s/[[:space:]]+/ /g; s/^ //; s/ $//' <<< "$range")
    [[ -n "$range" ]] || return 1

    for token in $range; do
        [[ -n "$token" ]] || continue
        case "$token" in
            "~>"*)
                bound="${token#\~>}"
                upper=$(_freshness_semver_upper_for_gem_pessimistic "$bound") || return 1
                _freshness_semver_compare_op "$version" ">=" "$bound" && _freshness_semver_compare_op "$version" "<" "$upper" || return 1
                ;;
            ">="*|"<="*)
                _freshness_semver_compare_op "$version" "${token:0:2}" "${token:2}" || return 1
                ;;
            ">"*|"<"*)
                _freshness_semver_compare_op "$version" "${token:0:1}" "${token:1}" || return 1
                ;;
            "="*)
                _freshness_semver_compare_op "$version" "=" "${token#=}" || return 1
                ;;
            *)
                _freshness_semver_compare_op "$version" "=" "$token" || return 1
                ;;
        esac
    done

    return 0
}

_freshness_gem_range_includes() {
    local range="$1"
    local version="$2"
    local status

    [[ -n "$range" && -n "$version" ]] || return 1
    if _freshness_ruby_available; then
        status=0
        ruby -rrubygems -e 'begin; exit(Gem::Requirement.new(ARGV[1]).satisfied_by?(Gem::Version.new(ARGV[0])) ? 0 : 1); rescue StandardError; exit 2; end' "$version" "$range" || status=$?
        [[ "$status" -eq 0 ]] && return 0
        [[ "$status" -eq 1 ]] && return 1
    fi

    _freshness_gem_range_fallback_includes "$range" "$version"
}

_freshness_range_includes() {
    local pkg_type="$1"
    local range="$2"
    local version="$3"

    case "$pkg_type" in
        npm) _freshness_npm_range_includes "$range" "$version" ;;
        gem) _freshness_gem_range_includes "$range" "$version" ;;
        *) return 1 ;;
    esac
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
        __constraint_worker)
            _freshness_constraint_manifest_worker "${2:-}" "${3:-}"
            ;;
        *)
            echo "usage: $0 __latest_worker <base64-query> | __constraint_worker <pkg-type> <base64-row>" >&2
            exit 2
            ;;
    esac
fi
