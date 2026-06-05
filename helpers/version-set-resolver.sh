#!/usr/bin/env bash
# Generic version-set resolver for extensions
#
# resolve_version_set <ext_name> <pg_major>
#   Reads .extensions.<ext_name>.version_set.resolver from
#   postgres/extensions/config.yaml via yq.
#   - If absent: echoes ["<version>"] (single-version backward-compat default)
#   - If present: invokes the resolver script with the env contract:
#       EXT_NAME=<ext_name> PG_MAJOR=<pg_major>
#     Propagates the resolver's non-zero exit code (fail-closed).
#
# Resolver contract (env-in / stdout-out):
#   EXT_NAME, PG_MAJOR, CEILING_VERSION → compact JSON array on stdout
#   Non-zero exit + no stdout on any error

set -euo pipefail

# Source logging helpers if available (provides _error / log_* functions)
_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_HELPER_DIR}/logging.sh" ]]; then
    # shellcheck source=helpers/logging.sh
    source "${_HELPER_DIR}/logging.sh"
fi

# Path to extensions config, relative to project root
_EXT_CONFIG="${_HELPER_DIR}/../postgres/extensions/config.yaml"

# Committed version-set file for extensions whose resolver contacts docker.io.
# Schema (kept consistent by upstream-monitor and this function):
#   { "<ext_name>": { "pg<major>": ["X.Y.Z", ...], ... }, ... }
# Example:
#   { "timescaledb": { "pg18": ["2.24.0","2.27.2"], "pg17": [...], ... } }
_COMMITTED_VERSIONSET_FILE="${_HELPER_DIR}/../postgres/extensions/timescaledb-version-set.json"

# _read_committed_versionset <ext_name> <pg_major>
#   Returns the JSON array for this ext+major from the committed file (stdout).
#   Exit 0 on hit; exit 1 on miss (file absent, ext absent, major key absent,
#   or empty/non-array result).  No docker.io or skopeo required.
_read_committed_versionset() {
    local ext_name="${1:?ext_name is required}"
    local pg_major="${2:?pg_major is required}"
    local key="pg${pg_major}"

    # File absent → miss
    [[ -f "$_COMMITTED_VERSIONSET_FILE" ]] || return 1

    # jq extracts .ext.pg<major>; outputs "null" when key is absent.
    local arr
    arr=$(jq -c --arg ext "$ext_name" --arg key "$key" \
        '.[$ext][$key] // empty' "$_COMMITTED_VERSIONSET_FILE" 2>/dev/null) || return 1

    # empty output → miss
    [[ -n "$arr" ]] || return 1

    # Verify it is actually a non-empty JSON array
    local count
    count=$(printf '%s' "$arr" | jq 'if type == "array" and length > 0 then length else 0 end' 2>/dev/null) || return 1
    [[ "${count:-0}" -gt 0 ]] || return 1

    printf '%s\n' "$arr"
    return 0
}

resolve_version_set() {
    local ext_name="${1:?ext_name is required}"
    local pg_major="${2:?pg_major is required}"
    # Optional third argument: path to the extensions config file.
    # When provided by the caller it takes precedence; falls back to the
    # module-level default so existing direct invocations keep working.
    local _config_file="${3:-${_EXT_CONFIG}}"

    # Read single version (always present) for fallback; -r (raw output) strips
    # surrounding quotes so yq v4 returns a bare string regardless of version.
    local single_version
    single_version=$(yq -r ".extensions.${ext_name}.version" "${_config_file}")

    # Read optional resolver path; -r ensures the fallback empty string is bare,
    # not a quoted "\"\"" on older yq v4 variants.
    local resolver_path
    resolver_path=$(yq -r ".extensions.${ext_name}.version_set.resolver // \"\"" "${_config_file}")

    if [[ -z "$resolver_path" ]]; then
        # No resolver configured — validate version before emitting single-version array.
        # yq returns the literal string "null" for a missing field; an empty string also
        # indicates invalid config.  Both cases → fail fast (the ext config is broken).
        if [[ -z "$single_version" || "$single_version" == "null" ]]; then
            echo "::error::version-set-resolver: .extensions.${ext_name}.version is missing or null in ${_config_file}" >&2
            return 1
        fi
        echo "[\"${single_version}\"]"
        return 0
    fi

    # Read optional retain_count here (shared by both the fast path and the live
    # resolver path).  Empty string → resolver uses its own internal default (12).
    # We use 12 as the fast-path fallback so the committed slice is trimmed
    # consistently with what the live resolver would produce.
    local retain_count
    retain_count=$(yq -r ".extensions.${ext_name}.version_set.retain_count // \"\"" "${_config_file}")
    local _effective_retain="${retain_count:-12}"

    # Fast path: consult the committed version-set file BEFORE invoking the live
    # resolver (which contacts docker.io via skopeo).  This eliminates all docker.io
    # egress during the build path when the file is present and covers this major.
    #
    # Guard: the ceiling from the caller's config must match the highest element in
    # the committed slice.  If they differ, the committed file is stale relative to
    # the caller's pinned version (e.g. a caller-supplied test config with a lower
    # ceiling) → fall through to the live resolver so the correct ceiling is applied.
    #
    # When accepting the committed slice, trim it to the effective retain_count
    # (last N elements, newest first) so the fast path mirrors what the live
    # resolver would return.  If the slice has fewer elements than retain_count,
    # it is returned as-is (it IS the full set for this major).
    #
    # Falls through on any miss (file absent, ext absent, major key absent, empty
    # array, or ceiling mismatch) — existing fail-closed semantics preserved.
    if [[ -n "$single_version" && "$single_version" != "null" ]]; then
        local _committed_slice _committed_ceiling
        if _committed_slice=$(_read_committed_versionset "$ext_name" "$pg_major" 2>/dev/null); then
            _committed_ceiling=$(printf '%s' "$_committed_slice" | jq -r '.[-1]' 2>/dev/null) || true
            if [[ "$_committed_ceiling" == "$single_version" ]]; then
                # Trim to retain_count: keep the last _effective_retain elements.
                # If the slice length <= retain_count, .[-N:] in jq returns the full array.
                printf '%s' "$_committed_slice" | \
                    jq -c --argjson n "${_effective_retain}" '.[-$n:]'
                return 0
            fi
            # Ceiling mismatch → committed file is stale for this caller → fall through
        fi
    fi

    # Resolve path relative to project root
    local project_root
    project_root="$(cd "${_HELPER_DIR}/.." && pwd)"
    local abs_resolver="${project_root}/${resolver_path}"

    # Escape a value for safe inclusion in a GHA workflow command.
    # Prevents %/\r/\n in yq-parsed or env-supplied values from injecting
    # extra commands (e.g. ::stop-commands::, ::add-mask::) into the runner log.
    _esc_gha() { local s="$1"; s="${s//\%/%25}"; s="${s//$'\n'/%0A}"; s="${s//$'\r'/%0D}"; printf '%s' "$s"; }

    if [[ ! -x "$abs_resolver" ]]; then
        echo "::error::version-set-resolver: resolver not found or not executable: $(_esc_gha "${abs_resolver}")" >&2
        return 1
    fi

    # Invoke resolver with env contract; propagate rc.
    # CEILING_VERSION bounds the resolver to the pinned config version so that
    # upstream tags published above it are excluded (see #558).
    # RETAIN_COUNT caps the window to the N most-recent versions per major.
    EXT_NAME="$ext_name" PG_MAJOR="$pg_major" CEILING_VERSION="$single_version" \
        RETAIN_COUNT="$retain_count" \
        "${abs_resolver}"
}
