#!/usr/bin/env bash
# bake-merge-hcl.sh — strict merge of latest and retained bake documents.
#
# Usage: scripts/bake-merge-hcl.sh <latest.json> <retained.json>
#
# A target shared by both documents must be structurally identical.  Bake's
# object merge would otherwise silently choose one definition and could discard
# an internal named context.

set -euo pipefail

_usage() {
    printf 'Usage: %s <latest.json> <retained.json>\n' "${0##*/}" >&2
}

if [[ $# -ne 2 ]]; then
    _usage
    exit 2
fi

latest_file="$1"
retained_file="$2"

for input_file in "$latest_file" "$retained_file"; do
    if [[ ! -r "$input_file" ]]; then
        printf '::error::bake HCL merge input is not readable: %s\n' "$input_file" >&2
        exit 1
    fi
    if ! jq -e '
        type == "object"
        and (.target | type == "object")
        and (.group | type == "object")
        and (.group.default.targets | type == "array")
    ' "$input_file" >/dev/null; then
        printf '::error::bake HCL merge input has an invalid document shape: %s\n' "$input_file" >&2
        exit 1
    fi
done

conflicts=$(jq -r -s '
    .[0].target as $latest
    | .[1].target as $retained
    | [
        $latest | keys[] as $target
        | select(($retained | has($target)) and ($latest[$target] != $retained[$target]))
        | $target
      ]
    | .[]
' "$latest_file" "$retained_file")

if [[ -n "$conflicts" ]]; then
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        printf '::error::bake HCL merge conflict: target %s differs between latest and retained documents\n' "$target" >&2
    done <<< "$conflicts"
    exit 1
fi

jq -s '
    .[0] as $latest
    | .[1] as $retained
    | (($latest.group.default.targets // []) + ($retained.group.default.targets // [])) as $default_targets
    | $latest
    | .target = ($latest.target + $retained.target)
    | .group = ($latest.group + $retained.group)
    | .group.default.targets = (
        reduce $default_targets[] as $target ([]; if index($target) then . else . + [$target] end)
      )
' "$latest_file" "$retained_file"
