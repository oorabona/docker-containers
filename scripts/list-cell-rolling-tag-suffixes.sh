#!/usr/bin/env bash
# Print the rolling tag suffixes for one build cell.
#
# This keeps YAML run bodies from restating the rolling-alias routing rule:
# they pass the cell attributes here and publish the suffixes this script
# returns. The versioned cell tag is intentionally omitted from the output.
#
# Usage: list-cell-rolling-tag-suffixes.sh <tag> <os> <variant> <flavor> <is_default>

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
    printf 'Usage: %s <tag> <os> <variant> <flavor> <is_default>\n' "${0##*/}" >&2
    exit 2
fi

_rolling_suffixes_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../helpers/variant-utils.sh
source "$_rolling_suffixes_root/helpers/variant-utils.sh"
unset _rolling_suffixes_root

tag="$1"
os="$2"
variant="$3"
flavor="$4"
is_default="$5"

if ! suffixes=$(compute_cell_tag_suffixes "$tag" "$os" "$variant" "$flavor" "$is_default"); then
    printf 'Could not enumerate rolling tag suffixes\n' >&2
    exit 1
fi

while IFS= read -r suffix; do
    # The first suffix is always the versioned tag. A tag literally named
    # "latest" produces no rolling alias, so filter by value rather than line.
    [[ "$suffix" == "$tag" ]] && continue
    printf '%s\n' "$suffix"
done <<< "$suffixes"
