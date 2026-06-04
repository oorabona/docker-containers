#!/usr/bin/env bash
# check-version-drift.sh — Flag versions declared in config but not published to GHCR.
#
# For each container (and postgres extension) that has declared versions, compare
# each declared version tag against what is actually published as a multi-arch
# manifest in GHCR.  If a version is declared but not published, and the bump
# timestamp is older than the grace period, it is reported as "drift".
#
# Usage:
#   check-version-drift.sh --mode sweep [options]
#   check-version-drift.sh --mode post-build --container <name> [options]
#
# Options:
#   --mode post-build|sweep      Required. post-build checks one container;
#                                sweep checks all containers + extensions.
#   --container <name>           Required with --mode post-build. Container name.
#   --grace-hours <N>            Grace period in hours (default: 6). Versions bumped
#                                within the grace window are in_flight, not drift.
#   --json                       Output JSON array instead of human table.
#
# Output rows (JSON object fields):
#   kind        "container" | "extension"
#   name        container or extension name (extensions: "ext-<name>:pg<major>")
#   declared    declared version tag
#   published   published version tag (empty if not found)
#   status      "in_sync" | "drift" | "in_flight" | "window_ok" | "window_empty" | "error"
#
# Exit codes:
#   0 — no drift rows (all in_sync, in_flight, window_ok)
#   1 — at least one drift row
#   2 — probe error OR window_empty (resolver failed/returned [] — fail-closed)
#
# Test seams:
#   _VDRIFT_BUMP_EPOCH_OVERRIDE         — override git log bump timestamp (epoch seconds)
#   _VDRIFT_CONTAINERS_OVERRIDE         — whitespace-sep container list, bypasses ./make list
#   _VDRIFT_GHCR_OWNER_OVERRIDE         — override GHCR owner derivation
#   _VDRIFT_PROBE_OVERRIDE              — function/path: probe(<image> <tag>) → "present"|"absent"|"error"
#
# GHA command injection prevention:
#   All user-derived strings emitted via ::notice::/::warning:: are escaped via
#   _escape_gha_command (pattern from helpers/base-cache-utils.sh).

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script directory from BASH_SOURCE (always needed for helper sourcing).
# PROJECT_ROOT: respect env override for testing; derive from BASH_SOURCE otherwise.
# (mirrors dependency-graph.sh pattern: check if empty before overwriting)
# ---------------------------------------------------------------------------
_vdrift_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    PROJECT_ROOT="$(cd "${_vdrift_self_dir}/.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Source helpers — use BASH_SOURCE-relative paths (no PROJECT_ROOT for sourcing)
# ---------------------------------------------------------------------------
# shellcheck source=../helpers/variant-utils.sh
source "${_vdrift_self_dir}/../helpers/variant-utils.sh"
# shellcheck source=../helpers/extension-utils.sh
source "${_vdrift_self_dir}/../helpers/extension-utils.sh"
# shellcheck source=../helpers/build-cache-utils.sh
source "${_vdrift_self_dir}/../helpers/build-cache-utils.sh"

# ---------------------------------------------------------------------------
# _escape_gha_command <value>
#
# Escape a value for safe inclusion in a ::keyword::value GHA workflow command.
# Mapping per GitHub runner spec: % → %25, \n → %0A, \r → %0D.
# Pattern sourced from helpers/base-cache-utils.sh::_escape_gha_command.
# ---------------------------------------------------------------------------
_escape_gha_command() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//$'\n'/%0A}"
    s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
CONTAINER_ARG=""
GRACE_HOURS=6
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"; shift 2 ;;
        --container)
            CONTAINER_ARG="$2"; shift 2 ;;
        --grace-hours)
            GRACE_HOURS="$2"; shift 2 ;;
        --json)
            JSON_OUTPUT=true; shift ;;
        -h|--help)
            grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
            exit 0 ;;
        *)
            printf '::error::Unknown argument: %s\n' "$(_escape_gha_command "$1")" >&2
            exit 2 ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "::error::--mode is required (post-build|sweep)" >&2
    exit 2
fi

if [[ "$MODE" != "post-build" && "$MODE" != "sweep" ]]; then
    echo "::error::--mode must be 'post-build' or 'sweep'" >&2
    exit 2
fi

if [[ "$MODE" == "post-build" && -z "$CONTAINER_ARG" ]]; then
    echo "::error::--container is required with --mode post-build" >&2
    exit 2
fi

if ! [[ "$GRACE_HOURS" =~ ^[0-9]+$ ]]; then
    echo "::error::--grace-hours must be a non-negative integer" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# GHCR owner resolution
# ---------------------------------------------------------------------------
_vdrift_ghcr_owner() {
    if [[ -n "${_VDRIFT_GHCR_OWNER_OVERRIDE:-}" ]]; then
        printf '%s' "$_VDRIFT_GHCR_OWNER_OVERRIDE"
        return 0
    fi
    if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
        printf '%s' "$GITHUB_REPOSITORY_OWNER"
        return 0
    fi
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        printf '%s' "${GITHUB_REPOSITORY%%/*}"
        return 0
    fi
    local remote_url
    if ! remote_url=$(cd "$PROJECT_ROOT" && git remote get-url origin 2>/dev/null); then
        echo "::error::Cannot determine GHCR owner (no GITHUB_REPOSITORY_OWNER and git remote get-url origin failed)" >&2
        return 1
    fi
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '::error::Cannot parse owner from git remote URL: %s\n' \
        "$(_escape_gha_command "$remote_url")" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Container enumeration
# ---------------------------------------------------------------------------
_vdrift_list_containers() {
    # _VDRIFT_CONTAINERS_OVERRIDE: if set (even to empty string), use its value.
    # Empty string = "no containers" (valid for extension-only sweeps in tests).
    if [[ -n "${_VDRIFT_CONTAINERS_OVERRIDE+is_set}" ]]; then
        printf '%s' "$_VDRIFT_CONTAINERS_OVERRIDE"
        return 0
    fi
    local out
    if ! out=$(cd "$PROJECT_ROOT" && ./make list 2>/dev/null); then
        echo "::error::Failed to enumerate containers via './make list'" >&2
        return 1
    fi
    out=$(printf '%s' "$out" | grep -E '^[a-z0-9_-]+$' || true)
    if [[ -z "$out" ]]; then
        echo "::error::'./make list' returned empty container set" >&2
        return 1
    fi
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Bump timestamp: seconds since epoch of the last git commit that touched
# the declaring file.  Respects _VDRIFT_BUMP_EPOCH_OVERRIDE test seam.
# ---------------------------------------------------------------------------
_vdrift_bump_epoch() {
    local file="$1"
    if [[ -n "${_VDRIFT_BUMP_EPOCH_OVERRIDE:-}" ]]; then
        printf '%s' "$_VDRIFT_BUMP_EPOCH_OVERRIDE"
        return 0
    fi
    local epoch
    epoch=$(cd "$PROJECT_ROOT" && git log -1 --format=%ct -- "$file" 2>/dev/null || true)
    if [[ -z "$epoch" || "$epoch" == "0" ]]; then
        # File not tracked or no commit history — treat as epoch 0 (always drift-eligible)
        printf '0'
        return 0
    fi
    printf '%s' "$epoch"
}

# ---------------------------------------------------------------------------
# _vdrift_probe_published <owner> <image_name> <tag>
#
# Check whether a multi-arch manifest exists in GHCR for <owner>/<image_name>:<tag>.
# Outputs one of: "present" | "absent" | "error"
# Never exits non-zero.
#
# Test seam: _VDRIFT_PROBE_OVERRIDE is a function/script that accepts
#   $1=<full image ref with tag>
# and outputs "present", "absent", or "error".
# ---------------------------------------------------------------------------
_vdrift_probe_published() {
    local owner="$1"
    local image_name="$2"
    local tag="$3"
    local full_ref="ghcr.io/${owner}/${image_name}:${tag}"

    if [[ -n "${_VDRIFT_PROBE_OVERRIDE:-}" ]]; then
        local result
        result=$("${_VDRIFT_PROBE_OVERRIDE}" "$full_ref" 2>/dev/null) || true
        case "$result" in
            present|absent|error) printf '%s' "$result" ;;
            *) printf 'error' ;;
        esac
        return 0
    fi

    # Real probe: use skopeo inspect --raw to get the raw manifest JSON, then
    # classify by mediaType to require a multi-arch index for Linux tags.
    #
    # skopeo is always available in CI (installed by the build jobs) and is
    # already used elsewhere in this repo (extension-utils.sh, base-cache-utils.sh).
    #
    # Classification:
    #   present — manifest is an OCI image index
    #               (application/vnd.oci.image.index.v1+json) OR Docker manifest
    #               list (application/vnd.docker.distribution.manifest.list.v2+json)
    #             OR tag contains "windows" (single-arch Windows images are
    #               legitimately single-platform)
    #   absent  — manifest is a single-image manifest
    #               (application/vnd.oci.image.manifest.v1+json or
    #                application/vnd.docker.distribution.manifest.v2+json)
    #               for a non-Windows Linux tag — the tag exists but only as a
    #               single-arch placeholder, not the published multi-arch image.
    #             OR skopeo exits non-zero AND stderr matches a manifest-specific
    #               "not found" pattern: "manifest unknown" / MANIFEST_UNKNOWN, or
    #               "was deleted or has expired".
    #   error   — skopeo exits 0 but manifest JSON is unparseable, OR any other
    #               non-zero exit (auth failure, network error, credential errors,
    #               5xx, etc.) — anything whose stderr is NOT a manifest-absent message.
    #
    # Falls back to a token+curl approach when skopeo is not on PATH.
    if command -v skopeo >/dev/null 2>&1; then
        local sk_stdout sk_stderr sk_rc
        # Capture both stdout (raw manifest JSON) and stderr (error messages).
        # stderr goes to a private mktemp file (not a predictable /tmp path) to
        # avoid a symlink race in the world-writable temp dir.
        local _sk_err_tmp
        _sk_err_tmp=$(mktemp)
        sk_stdout=$(skopeo inspect --raw "docker://${full_ref}" 2>"$_sk_err_tmp") \
            && sk_rc=0 || sk_rc=$?
        sk_stderr=$(cat "$_sk_err_tmp" 2>/dev/null || true)
        rm -f "$_sk_err_tmp"

        if [[ "$sk_rc" -ne 0 ]]; then
            # Distinguish manifest-not-found from transport/auth/tooling errors.
            # Only manifest-specific messages map to absent; everything else is error
            # (fail-closed): credential helper failures, "command not found", auth-endpoint
            # 404s, network errors, and 5xx responses all remain in the error branch.
            if printf '%s' "$sk_stderr" | grep -qiE \
                'manifest unknown|MANIFEST_UNKNOWN|was deleted or has expired'; then
                printf 'absent'
            else
                printf 'error'
            fi
            return 0
        fi

        # rc=0: classify manifest by mediaType.
        local media_type
        media_type=$(printf '%s' "$sk_stdout" | jq -r '.mediaType // empty' 2>/dev/null) || true

        if [[ -z "$media_type" ]]; then
            # Unparseable or missing mediaType → fail-closed
            printf 'error'
            return 0
        fi

        case "$media_type" in
            application/vnd.oci.image.index.v1+json|\
            application/vnd.docker.distribution.manifest.list.v2+json)
                # Multi-arch index → present
                printf 'present'
                ;;
            application/vnd.oci.image.manifest.v1+json|\
            application/vnd.docker.distribution.manifest.v2+json)
                # Single-arch manifest — Windows tags are legitimately single-platform
                if [[ "$tag" == *windows* ]]; then
                    printf 'present'
                else
                    # Linux tag backed only by a single-arch placeholder — treat as absent
                    # so partial/failed multi-arch publishes are flagged as drift.
                    printf '::warning::version-drift: %s single-arch manifest where multi-arch expected\n' \
                        "$(_escape_gha_command "${full_ref}")" >&2
                    printf 'absent'
                fi
                ;;
            *)
                # Unknown mediaType → fail-closed
                printf 'error'
                ;;
        esac
        return 0
    fi

    # skopeo not available: fall back to authenticated manifest GET via curl.
    # We need registry-utils sourced for ghcr_get_token; do it lazily.
    if [[ -z "${_VDRIFT_REGISTRY_UTILS_LOADED:-}" ]]; then
        # shellcheck source=../helpers/registry-utils.sh
        source "${_vdrift_self_dir}/../helpers/registry-utils.sh"
        _VDRIFT_REGISTRY_UTILS_LOADED=1
    fi

    local token
    token=$(ghcr_get_token "${owner}/${image_name}" 2>/dev/null) || true

    if [[ -z "$token" ]]; then
        # Cannot obtain a token → cannot determine state → error (fail-closed)
        printf 'error'
        return 0
    fi

    local curl_body curl_http_status
    # Capture body and status together; use -w to append status after body.
    # The body is the raw manifest JSON; the last line is the HTTP status code.
    local curl_out
    curl_out=$(curl -s \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
        -w '\n__HTTP_STATUS__:%{http_code}' \
        "https://ghcr.io/v2/${owner}/${image_name}/manifests/${tag}" \
        2>/dev/null) || true

    curl_http_status=$(printf '%s' "$curl_out" | grep -oE '__HTTP_STATUS__:[0-9]+$' | cut -d: -f2 || true)
    curl_body=$(printf '%s' "$curl_out" | sed '$s/__HTTP_STATUS__:[0-9]*$//' | sed '/^$/d' || true)

    case "$curl_http_status" in
        404|400)
            printf 'absent'
            return 0
            ;;
        ""|000|5*|401|403)
            printf 'error'
            return 0
            ;;
        200|201)
            # Got a response — classify by mediaType, same as skopeo path
            local curl_media_type
            curl_media_type=$(printf '%s' "$curl_body" | jq -r '.mediaType // empty' 2>/dev/null) || true

            if [[ -z "$curl_media_type" ]]; then
                printf 'error'
                return 0
            fi

            case "$curl_media_type" in
                application/vnd.oci.image.index.v1+json|\
                application/vnd.docker.distribution.manifest.list.v2+json)
                    printf 'present'
                    ;;
                application/vnd.oci.image.manifest.v1+json|\
                application/vnd.docker.distribution.manifest.v2+json)
                    if [[ "$tag" == *windows* ]]; then
                        printf 'present'
                    else
                        printf '::warning::version-drift: %s single-arch manifest where multi-arch expected\n' \
                            "$(_escape_gha_command "${full_ref}")" >&2
                        printf 'absent'
                    fi
                    ;;
                *)
                    printf 'error'
                    ;;
            esac
            ;;
        *)
            printf 'error'
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Result accumulator
# ---------------------------------------------------------------------------
# Rows are accumulated as a newline-delimited JSON objects in _ROWS_BUF,
# flushed to final output array at the end.
_ROWS_BUF=""
_HAS_DRIFT=false
_HAS_ERROR=false

_append_row() {
    local kind="$1"   # container|extension
    local name="$2"   # container name or "ext-<n>:pg<M>"
    local declared="$3"
    local published="$4"
    local status="$5"  # in_sync|drift|in_flight|window_ok|window_empty|error

    local row
    # Use jq to build safe JSON (handles any special chars in values)
    row=$(jq -cn \
        --arg kind      "$kind" \
        --arg name      "$name" \
        --arg declared  "$declared" \
        --arg published "$published" \
        --arg status    "$status" \
        '{kind:$kind,name:$name,declared:$declared,published:$published,status:$status}')

    if [[ -n "$_ROWS_BUF" ]]; then
        _ROWS_BUF+=$'\n'
    fi
    _ROWS_BUF+="$row"

    case "$status" in
        drift)          _HAS_DRIFT=true ;;
        error)          _HAS_ERROR=true ;;
        window_empty)   _HAS_ERROR=true ;;
    esac

    # GHA annotations
    local safe_name safe_declared safe_status
    safe_name=$(_escape_gha_command "$name")
    safe_declared=$(_escape_gha_command "$declared")
    safe_status=$(_escape_gha_command "$status")

    case "$status" in
        drift)
            printf '::warning::version-drift: %s declared=%s status=%s\n' \
                "$safe_name" "$safe_declared" "$safe_status" >&2 ;;
        in_flight)
            printf '::notice::version-drift: %s declared=%s status=in_flight (within grace window)\n' \
                "$safe_name" "$safe_declared" >&2 ;;
        error)
            printf '::warning::version-drift: %s declared=%s probe error\n' \
                "$safe_name" "$safe_declared" >&2 ;;
        window_empty)
            printf '::warning::version-drift: %s declared=%s timescaledb window empty\n' \
                "$safe_name" "$safe_declared" >&2 ;;
    esac
}

# ---------------------------------------------------------------------------
# Check a single container tag
# ---------------------------------------------------------------------------
_check_container_tag() {
    local owner="$1"
    local container="$2"     # e.g. "postgres"
    local image_name="$3"    # e.g. "postgres"
    local version_tag="$4"   # e.g. "18-alpine" or "13.7.0-ubuntu"
    local declaring_file="$5" # relative to PROJECT_ROOT, for bump timestamp

    local probe_result
    probe_result=$(_vdrift_probe_published "$owner" "$image_name" "$version_tag")

    case "$probe_result" in
        present)
            # Tag is present and multi-arch → in_sync
            _append_row "container" "$container" "$version_tag" "$version_tag" "in_sync"
            ;;
        absent)
            # Check grace window
            local bump_epoch now grace_secs elapsed
            bump_epoch=$(_vdrift_bump_epoch "$declaring_file")
            now=$(date +%s)
            grace_secs=$(( GRACE_HOURS * 3600 ))
            elapsed=$(( now - bump_epoch ))
            if (( elapsed <= grace_secs )); then
                _append_row "container" "$container" "$version_tag" "" "in_flight"
            else
                _append_row "container" "$container" "$version_tag" "" "drift"
            fi
            ;;
        error)
            _append_row "container" "$container" "$version_tag" "" "error"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Process a single container
# ---------------------------------------------------------------------------
_process_container() {
    local owner="$1"
    local container="$2"

    local container_dir="${PROJECT_ROOT}/${container}"
    local variants_file="${container_dir}/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        # No variants.yaml — nothing declared, skip silently
        return 0
    fi

    # list_versions masks yq parse errors (|| echo "") and always returns rc 0,
    # so validate the file directly here: a malformed or schema-broken
    # variants.yaml must fail closed (exit 2), not silently yield "no versions".
    if ! yq -e '.versions[].tag' "$variants_file" >/dev/null 2>&1; then
        echo "::error::version-drift: variants.yaml for ${container} failed to parse or declares no .versions[].tag" >&2
        _HAS_ERROR=true
        return 0
    fi

    # List all declared version tags.
    # Distinguish parse/tool failure (non-zero exit) from genuinely empty result.
    local versions
    if ! versions=$(list_versions "$container_dir" 2>/dev/null); then
        echo "::error::version-drift: failed to read declared versions for ${container} (yq/parse error)" >&2
        _HAS_ERROR=true
        return 0
    fi

    if [[ -z "$versions" ]]; then
        return 0
    fi

    # Determine the base suffix (e.g. "-alpine" for postgres, "" for others)
    local bsfx
    bsfx=$(base_suffix "$container_dir" 2>/dev/null || true)

    # For containers with variants (multi-variant per version like postgres),
    # we check the default/base variant tag per version.
    # For simple containers (ansible, openresty), the tag IS the version tag.
    if has_variants "$container_dir" 2>/dev/null; then
        local vc
        vc=$(version_count "$container_dir" 2>/dev/null || echo "0")
        if [[ "$vc" -gt 0 ]]; then
            # Multi-version with variants — check just the first (default) variant per version
            # to determine if the version was published at all.  The tag for the default
            # variant is the canonical published tag.
            while IFS= read -r vtag; do
                [[ -z "$vtag" ]] && continue
                local default_var
                default_var=$(default_variant "$container_dir" "$vtag" 2>/dev/null || true)
                local published_tag
                if [[ -n "$default_var" ]]; then
                    published_tag=$(variant_image_tag "$vtag" "$default_var" "$container_dir" 2>/dev/null || true)
                else
                    # No default variant — use version + base suffix as the tag
                    published_tag="${vtag}${bsfx}"
                fi
                [[ -z "$published_tag" ]] && published_tag="${vtag}${bsfx}"
                _check_container_tag "$owner" "$container" "$container" \
                    "$published_tag" "${container}/variants.yaml"
            done <<< "$versions"
            return 0
        fi
    fi

    # Simple container — version tag IS the published tag (no suffix beyond bsfx)
    # For simple variants.yaml the tag already contains the full suffix
    # (e.g. "13.7.0-ubuntu" for ansible, "1.29.2.5-alpine" for openresty)
    while IFS= read -r vtag; do
        [[ -z "$vtag" ]] && continue
        _check_container_tag "$owner" "$container" "$container" \
            "$vtag" "${container}/variants.yaml"
    done <<< "$versions"
}

# ---------------------------------------------------------------------------
# Process postgres extensions
# ---------------------------------------------------------------------------
_process_extensions() {
    local owner="$1"

    local ext_config="${PROJECT_ROOT}/postgres/extensions/config.yaml"
    if [[ ! -f "$ext_config" ]]; then
        return 0
    fi

    # Read PG major versions — distinguish tool failure from genuinely empty config.
    local pg_majors
    if ! pg_majors=$(yq -r '.pg_versions[]' "$ext_config" 2>/dev/null); then
        echo "::error::version-drift: failed to read pg_versions from ${ext_config} (yq/parse error)" >&2
        _HAS_ERROR=true
        return 0
    fi
    if [[ -z "$pg_majors" ]]; then
        return 0
    fi

    # Enumerate extension names per PG major using the build's filter function
    # (list_extensions_by_priority), which excludes disabled extensions and those
    # with max_pg_version < pg_major.  This matches exactly what the build publishes.
    while IFS= read -r pg_major; do
        [[ -z "$pg_major" ]] && continue

        local ext_names
        if ! ext_names=$(list_extensions_by_priority "$ext_config" "$pg_major" 2>/dev/null); then
            echo "::error::version-drift: failed to list extensions for pg${pg_major} from ${ext_config} (yq/parse error)" >&2
            _HAS_ERROR=true
            continue
        fi

        if [[ -z "$ext_names" ]]; then
            continue
        fi

        while IFS= read -r ext_name; do
            [[ -z "$ext_name" ]] && continue

            # Check if this extension has a version_set resolver (timescaledb pattern)
            local has_resolver
            has_resolver=$(yq -r ".extensions.${ext_name}.version_set.resolver // \"\"" \
                "$ext_config" 2>/dev/null || true)

            if [[ -n "$has_resolver" ]]; then
                # Timescaledb-style: check the resolver window per PG major
                _check_timescaledb_extension "$owner" "$ext_name" "$pg_major" "$ext_config"
            else
                # Standard extension: single declared version from config
                local ext_version
                ext_version=$(yq -r ".extensions.${ext_name}.version // \"\"" \
                    "$ext_config" 2>/dev/null || true)

                if [[ -z "$ext_version" || "$ext_version" == "null" ]]; then
                    continue
                fi

                local tag="pg${pg_major}-${ext_version}"
                local ext_image_name="ext-${ext_name}"
                local probe_result
                probe_result=$(_vdrift_probe_published "$owner" "$ext_image_name" "$tag")
                local row_name="ext-${ext_name}:pg${pg_major}"

                case "$probe_result" in
                    present)
                        _append_row "extension" "$row_name" "$tag" "$tag" "in_sync"
                        ;;
                    absent)
                        local bump_epoch now grace_secs elapsed
                        bump_epoch=$(_vdrift_bump_epoch "postgres/extensions/config.yaml")
                        now=$(date +%s)
                        grace_secs=$(( GRACE_HOURS * 3600 ))
                        elapsed=$(( now - bump_epoch ))
                        if (( elapsed <= grace_secs )); then
                            _append_row "extension" "$row_name" "$tag" "" "in_flight"
                        else
                            _append_row "extension" "$row_name" "$tag" "" "drift"
                        fi
                        ;;
                    error)
                        _append_row "extension" "$row_name" "$tag" "" "error"
                        ;;
                esac
            fi
        done <<< "$ext_names"
    done <<< "$pg_majors"
}

# ---------------------------------------------------------------------------
# Timescaledb version_set check
#
# The timescaledb extension uses a version_set resolver that produces a window
# of versions per PG major.  We check:
#   - Is the ceiling (latest in window) published?           → window_ok
#   - Is the window empty (resolver failed / returned [])?   → window_empty
#   - Otherwise all versions in window published?            → window_ok
# ---------------------------------------------------------------------------
_check_timescaledb_extension() {
    local owner="$1"
    local ext_name="$2"
    local pg_major="$3"
    local ext_config="$4"

    local resolver
    resolver=$(yq -r ".extensions.${ext_name}.version_set.resolver // \"\"" \
        "$ext_config" 2>/dev/null || true)

    if [[ -z "$resolver" ]]; then
        return 0
    fi

    # Derive ceiling from declared version field
    local ceiling
    ceiling=$(yq -r ".extensions.${ext_name}.version // \"\"" \
        "$ext_config" 2>/dev/null || true)

    local retain_count
    retain_count=$(yq -r ".extensions.${ext_name}.version_set.retain_count // 12" \
        "$ext_config" 2>/dev/null || echo "12")

    # Run the resolver to get the version window
    local resolver_path="${PROJECT_ROOT}/${resolver}"
    local window_json=""

    if [[ -f "$resolver_path" ]]; then
        window_json=$(PG_MAJOR="$pg_major" \
            CEILING_VERSION="$ceiling" \
            RETAIN_COUNT="$retain_count" \
            bash "$resolver_path" 2>/dev/null || true)
    fi

    local row_name="ext-${ext_name}:pg${pg_major}"

    if [[ -z "$window_json" ]]; then
        # Resolver failed or returned empty
        _append_row "extension" "$row_name" "pg${pg_major}-window" "" "window_empty"
        return 0
    fi

    # Validate JSON array
    if ! printf '%s' "$window_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        _append_row "extension" "$row_name" "pg${pg_major}-window" "" "window_empty"
        return 0
    fi

    local window_len
    window_len=$(printf '%s' "$window_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$window_len" -eq 0 ]]; then
        _append_row "extension" "$row_name" "pg${pg_major}-window" "" "window_empty"
        return 0
    fi

    # Check the ceiling version is published (most important check)
    if [[ -n "$ceiling" && "$ceiling" != "null" ]]; then
        local ceiling_tag="pg${pg_major}-${ceiling}"
        local ext_image_name="ext-${ext_name}"
        local probe_result
        probe_result=$(_vdrift_probe_published "$owner" "$ext_image_name" "$ceiling_tag")

        case "$probe_result" in
            present)
                _append_row "extension" "$row_name" "$ceiling_tag" "$ceiling_tag" "window_ok"
                ;;
            absent)
                local bump_epoch now grace_secs elapsed
                bump_epoch=$(_vdrift_bump_epoch "postgres/extensions/config.yaml")
                now=$(date +%s)
                grace_secs=$(( GRACE_HOURS * 3600 ))
                elapsed=$(( now - bump_epoch ))
                if (( elapsed <= grace_secs )); then
                    _append_row "extension" "$row_name" "$ceiling_tag" "" "in_flight"
                else
                    _append_row "extension" "$row_name" "$ceiling_tag" "" "drift"
                fi
                ;;
            error)
                _append_row "extension" "$row_name" "$ceiling_tag" "" "error"
                ;;
        esac
    else
        # No ceiling declared — check non-empty window as sufficient
        _append_row "extension" "$row_name" "pg${pg_major}-window" \
            "$(printf '%s' "$window_json" | jq -r '.[0]' 2>/dev/null || true)" "window_ok"
    fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
_emit_output() {
    local rows_json
    if [[ -z "$_ROWS_BUF" ]]; then
        rows_json="[]"
    else
        rows_json=$(printf '%s\n' "$_ROWS_BUF" | jq -s '.')
    fi

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        printf '%s\n' "$rows_json"
    else
        # Human-readable table
        printf '%-14s %-36s %-32s %-32s %s\n' "KIND" "NAME" "DECLARED" "PUBLISHED" "STATUS"
        printf '%s\n' "$(printf '%0.s-' {1..120})"
        printf '%s' "$rows_json" | jq -r \
            '.[] | [.kind, .name, .declared, .published, .status] | @tsv' \
            | while IFS=$'\t' read -r kind name declared published status; do
                printf '%-14s %-36s %-32s %-32s %s\n' \
                    "$kind" "$name" "$declared" "$published" "$status"
            done
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Prerequisite check — fail-closed on missing tools
# Both yq and jq are required for declared-version enumeration and JSON output.
# A missing tool causes silent false-clean results; we must exit 2 explicitly.
# ---------------------------------------------------------------------------
if ! command -v yq >/dev/null 2>&1; then
    echo "::error::version-drift: required tool 'yq' not found on PATH — cannot run guard" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "::error::version-drift: required tool 'jq' not found on PATH — cannot run guard" >&2
    exit 2
fi

if ! GHCR_OWNER=$(_vdrift_ghcr_owner); then
    echo "::error::version-drift: GHCR owner resolution failed — cannot run guard" >&2
    exit 2
fi

if [[ "$MODE" == "post-build" ]]; then
    _process_container "$GHCR_OWNER" "$CONTAINER_ARG"
    if [[ "$CONTAINER_ARG" == "postgres" ]]; then
        _process_extensions "$GHCR_OWNER"
    fi
else
    # Sweep mode: all containers + extensions
    containers=""
    if ! containers=$(_vdrift_list_containers); then
        echo "::error::version-drift: container enumeration failed — cannot run guard" >&2
        exit 2
    fi

    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        _process_container "$GHCR_OWNER" "$container"
    done <<< "$containers"

    _process_extensions "$GHCR_OWNER"
fi

_emit_output

# Exit code
if [[ "$_HAS_ERROR" == "true" ]]; then
    exit 2
elif [[ "$_HAS_DRIFT" == "true" ]]; then
    exit 1
else
    exit 0
fi
