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

resolve_version_set() {
    local ext_name="${1:?ext_name is required}"
    local pg_major="${2:?pg_major is required}"

    # Read single version (always present) for fallback; -r (raw output) strips
    # surrounding quotes so yq v4 returns a bare string regardless of version.
    local single_version
    single_version=$(yq -r ".extensions.${ext_name}.version" "${_EXT_CONFIG}")

    # Read optional resolver path; -r ensures the fallback empty string is bare,
    # not a quoted "\"\"" on older yq v4 variants.
    local resolver_path
    resolver_path=$(yq -r ".extensions.${ext_name}.version_set.resolver // \"\"" "${_EXT_CONFIG}")

    if [[ -z "$resolver_path" ]]; then
        # No resolver configured — return single-version array
        echo "[\"${single_version}\"]"
        return 0
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
    EXT_NAME="$ext_name" PG_MAJOR="$pg_major" CEILING_VERSION="$single_version" \
        "${abs_resolver}"
}
