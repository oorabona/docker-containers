#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="${ROOT_DIR:-$PROJECT_ROOT}"
export PROJECT_ROOT ROOT_DIR

# shellcheck source=../helpers/extension-utils.sh
source "${PROJECT_ROOT}/helpers/extension-utils.sh"

template="${1:-Dockerfile}"
flavor="${2:-base}"
version="${3:-}"
# Fourth argument is accepted for the generic bake-generator contract.
: "${4:-}"

if [[ -z "$version" ]]; then
    printf 'ERROR: postgres/generate-dockerfile.sh requires <version>\n' >&2
    exit 2
fi

pg_major="${version%%.*}"
pg_major="${pg_major%%-*}"
if [[ -z "$pg_major" || ! "$pg_major" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: cannot derive PostgreSQL major version from %q\n' "$version" >&2
    exit 2
fi

generate_dockerfile \
    "${PROJECT_ROOT}/postgres/extensions/config.yaml" \
    "$template" \
    "$flavor" \
    "$pg_major"
