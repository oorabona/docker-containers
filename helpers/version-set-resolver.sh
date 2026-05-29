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

    # Read single version (always present) for fallback
    local single_version
    single_version=$(yq ".extensions.${ext_name}.version" "${_EXT_CONFIG}")

    # Read optional resolver path (mikefarah/yq v4: use // "" for absent key)
    local resolver_path
    resolver_path=$(yq ".extensions.${ext_name}.version_set.resolver // \"\"" "${_EXT_CONFIG}")

    if [[ -z "$resolver_path" ]]; then
        # No resolver configured — return single-version array
        echo "[\"${single_version}\"]"
        return 0
    fi

    # Resolve path relative to project root
    local project_root
    project_root="$(cd "${_HELPER_DIR}/.." && pwd)"
    local abs_resolver="${project_root}/${resolver_path}"

    if [[ ! -x "$abs_resolver" ]]; then
        echo "::error::version-set-resolver: resolver not found or not executable: ${abs_resolver}" >&2
        return 1
    fi

    # Invoke resolver with env contract; propagate rc
    EXT_NAME="$ext_name" PG_MAJOR="$pg_major" \
        "${abs_resolver}"
}
