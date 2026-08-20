#!/usr/bin/env bash

# Collect find results that are safe to pass to linters and to render in CI.
#
# Keep this decision in one executable instead of copying the allowlist into
# workflow run blocks. A later linter must route pathnames it discovers by
# search through this collector: it withholds every pathname until find has
# succeeded and every result has passed the boundary, so its command cannot
# start after a hostile pathname was found.

set -euo pipefail

# The pathname allowlist is ASCII bytes, regardless of the caller's locale or
# Bash's range-expression behavior.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

main() {
    local paths_file path bad_path=

    # Workflow callers use repository-relative find roots and predicates.
    cd "$ROOT_DIR"

    paths_file=$(mktemp)
    # Do not put find in a process substitution: the consumer could see an
    # empty list when find failed. With pipefail, the completed result is only
    # considered usable after both find and sort have succeeded.
    if ! find "$@" -print0 | sort -z > "$paths_file"; then
        rm -f "$paths_file"
        printf '%s\n' '::error::safe path discovery failed' >&2
        return 1
    fi

    while IFS= read -r -d '' path; do
        case $path in
            *[!A-Za-z0-9._/-]*)
                bad_path=$path
                break
                ;;
        esac
    done < "$paths_file"

    if [[ -n $bad_path ]]; then
        rm -f "$paths_file"
        printf '%s\n' '::error::refusing to lint a path outside [A-Za-z0-9._/-]' >&2
        printf 'rejected pathname: %q\n' "$bad_path" >&2
        return 1
    fi

    if cat "$paths_file"; then
        rm -f "$paths_file"
    else
        local status=$?
        rm -f "$paths_file"
        return "$status"
    fi
}

main "$@"
