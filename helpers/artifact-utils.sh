#!/usr/bin/env bash
# Release-artifact helpers.
#
# A container may declare, in config.yaml, the URL of the upstream artifact its
# Dockerfile downloads:
#
#   artifact_url: "https://example.org/rel/${UPSTREAM_VERSION}/tool-${RELEASE_VERSION}.tar.gz"
#   artifact_signature_suffix: ".asc"      # optional: also require URL + suffix
#
# That single declaration feeds every consumer, so they cannot drift apart:
#   - the build receives --build-arg ARTIFACT_URL (and ARTIFACT_SIGNATURE_URL
#     when a suffix is declared) on both the matrix and the bake path
#   - `make check-updates` only proposes a candidate once those URLs answer 2xx
#
# Placeholders: ${UPSTREAM_VERSION} is the candidate tag with its tag suffix
# removed (e.g. v2.7.8 from v2.7.8-alpine); ${RELEASE_VERSION} is the same
# without a leading "v". The version is ALWAYS derived from the frozen tag
# (derive_upstream_version), never from a live upstream query, so the monitor,
# the matrix build and the bake build all fetch the version the Docker tag
# announces.
#
# Without `artifact_url` nothing changes for the container.
#
# Two failure classes are kept apart on purpose:
#   - configuration errors (unparsable config.yaml, invalid declaration,
#     collision with build_args)         -> explicit failure, never bypassed
#   - artifact temporarily unavailable   -> "pending", the caller retries later

# Upstream version a frozen tag announces: the tag minus the container's tag
# suffix (version.sh --tag-suffix, offline by contract). Never queries upstream.
# A suffix is honoured only when it is empty or starts with '-' and the tag ends
# with it: a version.sh lacking --tag-suffix falls through to its default
# (version) output, which must not be treated as a suffix.
# Usage: derive_upstream_version <container_dir> <tag>
derive_upstream_version() {
    local dir="$1" tag="$2" suffix=""
    [[ -n "$tag" ]] || return 1
    if [[ -x "$dir/version.sh" ]]; then
        suffix=$(cd "$dir" && ./version.sh --tag-suffix 2>/dev/null || true)
        if [[ -n "$suffix" && ( "${suffix:0:1}" != "-" || "${tag%"$suffix"}" == "$tag" ) ]]; then
            suffix=""
        fi
    fi
    if [[ -n "$suffix" ]]; then
        printf '%s\n' "${tag%"$suffix"}"
    else
        printf '%s\n' "$tag"
    fi
}

# Read a top-level scalar from <dir>/config.yaml (empty when absent).
# Fails (non-zero) when yq cannot read the file: callers must not treat that as
# "not declared".
# Usage: artifact_config_value <dir> <key>
artifact_config_value() {
    local dir="$1" key="$2"
    [[ -f "$dir/config.yaml" ]] || return 0
    yq -r ".${key} // \"\"" "$dir/config.yaml" 2>/dev/null
}

# Fail-closed validation of the declaration in <dir>/config.yaml.
#   0 = valid, or nothing declared
#   2 = configuration error (reason on stderr)
# Usage: artifact_validate_config <dir>
artifact_validate_config() {
    local dir="$1" cfg="$1/config.yaml" label
    label=$(basename "$(cd "$dir" 2>/dev/null && pwd)")
    [[ -f "$cfg" ]] || return 0

    local decl url_tag sfx_tag collision
    if ! decl=$(yq -r '[(.artifact_url | tag), (.artifact_signature_suffix | tag), ((.build_args | tag) == "!!map" and (.build_args | (has("ARTIFACT_URL") or has("ARTIFACT_SIGNATURE_URL"))))] | @tsv' "$cfg" 2>/dev/null); then
        printf 'artifact: %s: cannot parse config.yaml\n' "$label" >&2
        return 2
    fi
    IFS=$'\t' read -r url_tag sfx_tag collision <<< "$decl"

    if [[ "$url_tag" == "!!null" ]]; then
        if [[ "$sfx_tag" != "!!null" ]]; then
            printf 'artifact: %s: artifact_signature_suffix without artifact_url\n' "$label" >&2
            return 2
        fi
        return 0
    fi
    if [[ "$url_tag" != "!!str" ]]; then
        printf 'artifact: %s: artifact_url must be a string\n' "$label" >&2
        return 2
    fi
    if [[ "$collision" == "true" ]]; then
        printf 'artifact: %s: build_args must not define ARTIFACT_URL or ARTIFACT_SIGNATURE_URL (derived from artifact_url)\n' "$label" >&2
        return 2
    fi

    local tpl stripped
    tpl=$(yq -r '.artifact_url' "$cfg" 2>/dev/null) || { printf 'artifact: %s: cannot read artifact_url\n' "$label" >&2; return 2; }
    stripped="${tpl//\$\{UPSTREAM_VERSION\}/X}"
    stripped="${stripped//\$\{RELEASE_VERSION\}/X}"
    if [[ ! "$stripped" =~ ^https://[A-Za-z0-9._~:/?@%+,=-]+$ ]]; then
        printf 'artifact: %s: artifact_url must be a plain https URL using only ${UPSTREAM_VERSION}/${RELEASE_VERSION} placeholders\n' "$label" >&2
        return 2
    fi

    if [[ "$sfx_tag" != "!!null" ]]; then
        local sfx
        sfx=$(yq -r '.artifact_signature_suffix' "$cfg" 2>/dev/null) || sfx=""
        if [[ "$sfx_tag" != "!!str" || ! "$sfx" =~ ^[A-Za-z0-9._-]+$ ]]; then
            printf 'artifact: %s: artifact_signature_suffix must be a non-empty plain suffix such as ".asc"\n' "$label" >&2
            return 2
        fi
    fi
    return 0
}

# Resolve the URL template for a given upstream version.
# Usage: resolve_artifact_url <template> <upstream_version>
# Fails (non-zero, nothing on stdout) on an empty version or when the result is
# not a plain https URL: the value ends up in a docker argument list.
resolve_artifact_url() {
    local template="$1" upstream="$2"
    [[ -n "$template" && -n "$upstream" ]] || return 1

    local url="${template//\$\{UPSTREAM_VERSION\}/$upstream}"
    url="${url//\$\{RELEASE_VERSION\}/${upstream#v}}"

    [[ "$url" =~ ^https://[A-Za-z0-9._~:/?@%+,=-]+$ ]] || return 1
    printf '%s\n' "$url"
}

# Build arguments derived from the declaration, for a frozen candidate tag.
# Prints "ARTIFACT_URL=<url>" and, when a suffix is declared,
# "ARTIFACT_SIGNATURE_URL=<url><suffix>"; prints nothing when undeclared.
#   0 = ok (possibly nothing declared)
#   1 = declared but not resolvable for this tag
#   2 = configuration error
# Usage: artifact_build_args <container_dir> <tag>
artifact_build_args() {
    local dir="$1" tag="$2"
    artifact_validate_config "$dir" || return 2

    local template suffix upstream url
    template=$(artifact_config_value "$dir" artifact_url) || return 2
    [[ -n "$template" ]] || return 0
    suffix=$(artifact_config_value "$dir" artifact_signature_suffix) || return 2

    upstream=$(derive_upstream_version "$dir" "$tag") || return 1
    url=$(resolve_artifact_url "$template" "$upstream") || return 1
    printf 'ARTIFACT_URL=%s\n' "$url"
    [[ -z "$suffix" ]] || printf 'ARTIFACT_SIGNATURE_URL=%s%s\n' "$url" "$suffix"
}

# Succeeds only when the FINAL response is 2xx (a terminal 3xx, 4xx, 5xx, a
# timeout or a redirect loop is "not available"). HEAD first; servers that
# refuse HEAD (403/405/501) get one ranged GET capped at a single byte, so the
# archive itself is never downloaded.
# Usage: artifact_reachable <url>
artifact_reachable() {
    local url="$1" code
    code=$(curl -sSIL --max-redirs 5 --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 60 \
        -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    case "$code" in
        403|405|501)
            code=$(curl -sSL --max-redirs 5 -r 0-0 --max-filesize 1 --connect-timeout 15 --max-time 60 \
                -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
            ;;
    esac
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

# Is the artifact declared by <container_dir>/config.yaml downloadable for the
# frozen candidate <tag>?
#   0 = ready, or nothing declared (the gate is opt-in)
#   1 = declared but not downloadable yet ("pending": the caller retries later)
#   2 = configuration error (never downgraded to "pending")
# Usage: artifact_ready <container_dir> <tag>
artifact_ready() {
    local dir="$1" tag="$2" lines rc=0
    lines=$(artifact_build_args "$dir" "$tag") || rc=$?
    case "$rc" in
        0) ;;
        2) return 2 ;;
        *) return 1 ;;
    esac

    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        artifact_reachable "${line#*=}" || return 1
    done <<< "$lines"
    return 0
}
