#!/usr/bin/env bash
# Print the rolling tag suffixes for one build cell.
#
# This keeps YAML run bodies from restating the rolling-alias routing rule:
# they pass their identifier and cell attributes here, then publish only the
# suffixes this script returns. The versioned cell tag is intentionally omitted.
#
# Usage: list-cell-rolling-tag-suffixes.sh <publisher> <tag> <os> <variant> <flavor> <is_default>

set -euo pipefail

if [[ "$#" -ne 6 ]]; then
    printf 'Usage: %s <publisher> <tag> <os> <variant> <flavor> <is_default>\n' "${0##*/}" >&2
    exit 2
fi

_rolling_suffixes_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../helpers/variant-utils.sh
source "$_rolling_suffixes_root/helpers/variant-utils.sh"
unset _rolling_suffixes_root

publisher="$1"
tag="$2"
os="$3"
variant="$4"
flavor="$5"
is_default="$6"

if ! suffixes=$(list_cell_publisher_rolling_aliases "$publisher" "$tag" "$os" "$variant" "$flavor" "$is_default"); then
    printf 'Could not enumerate rolling tag suffixes\n' >&2
    exit 1
fi

if [[ -n "$suffixes" ]]; then
    printf '%s\n' "$suffixes"
fi
