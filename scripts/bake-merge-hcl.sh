#!/usr/bin/env bash
# bake-merge-hcl.sh — strict merge of latest and retained bake documents.
#
# Usage: scripts/bake-merge-hcl.sh <latest.json> <retained.json>
#
# A target or variable shared by both documents must be structurally identical.
# A shared group may differ only in its membership list, which is merged with
# latest members first. Bake's object merge would otherwise silently choose one
# definition and could discard an internal named context or group member.

set -euo pipefail

readonly _REFUSAL_STATUS=1

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
        exit "$_REFUSAL_STATUS"
    fi
done

# --slurpfile reads each input path once. The shape checks, refusal verdict,
# and merged document are then all derived from those exact parsed values.
if ! merge_result=$(jq -n \
    --slurpfile latest "$latest_file" \
    --slurpfile retained "$retained_file" \
    --arg latest_file "$latest_file" \
    --arg retained_file "$retained_file" '
    def valid_key:
        type == "string" and test("\\S");

    def document_errors($file; $documents):
        if ($documents | length) != 1 then
            [{kind: "document-count", file: $file}]
        elif (
            ($documents[0] | type == "object")
            and ($documents[0].variable | type == "object")
            and ($documents[0].target | type == "object")
            and ($documents[0].group | type == "object")
            and ($documents[0].group.default | type == "object")
            and ($documents[0].group.default.targets | type == "array")
            and ($documents[0].group | all(.[]; (type == "object") and (.targets | type == "array")))
        ) | not then
            [{kind: "shape", file: $file}]
        else
            [
                ["variable", "target", "group"][] as $block
                | $documents[0][$block]
                | keys[] as $key
                | select($key | valid_key | not)
                | {kind: "invalid-key", file: $file, block: $block, key: $key}
            ]
        end;

    def block_conflicts($latest; $retained; $block):
        [
            $latest[$block] | keys[] as $key
            | select($retained[$block] | has($key))
            | select($latest[$block][$key] != $retained[$block][$key])
            | {kind: "conflict", block: $block, key: $key}
        ];

    def group_conflicts($latest; $retained):
        [
            $latest.group | keys[] as $key
            | select($retained.group | has($key))
            | select(($latest.group[$key] | del(.targets)) != ($retained.group[$key] | del(.targets)))
            | {kind: "conflict", block: "group", key: $key}
        ];

    def unique_in_order:
        reduce .[] as $item ([]; if index($item) then . else . + [$item] end);

    ($latest[0]) as $latest_document
    | ($retained[0]) as $retained_document
    | (document_errors($latest_file; $latest) + document_errors($retained_file; $retained)) as $document_errors
    | (if ($document_errors | length) == 0 then
           block_conflicts($latest_document; $retained_document; "variable")
           + block_conflicts($latest_document; $retained_document; "target")
           + group_conflicts($latest_document; $retained_document)
       else
           []
       end) as $conflicts
    | ($document_errors + $conflicts) as $errors
    | if ($errors | length) > 0 then
          {status: "refused", errors: $errors}
      else
          {
            status: "ok",
            merged: (
                $latest_document
                | .variable = ($latest_document.variable + $retained_document.variable)
                | .target = ($latest_document.target + $retained_document.target)
                | .group = ($latest_document.group + $retained_document.group)
                | reduce ($latest_document.group | keys[]) as $key (
                    .;
                    if $retained_document.group | has($key) then
                        .group[$key].targets = (
                            ($latest_document.group[$key].targets + $retained_document.group[$key].targets)
                            | unique_in_order
                        )
                    else
                        .
                    end
                )
            )
          }
      end
'); then
    printf '::error::bake HCL merge could not parse one or more input documents\n' >&2
    exit "$_REFUSAL_STATUS"
fi

if ! jq -e '.status == "ok"' <<< "$merge_result" >/dev/null; then
    jq -r '
        .errors[]
        | if .kind == "document-count" then
              "::error::bake HCL merge input must contain exactly one JSON document: \(.file)"
          elif .kind == "shape" then
              "::error::bake HCL merge input has an invalid document shape: \(.file)"
          elif .kind == "invalid-key" then
              "::error::bake HCL merge input has an empty or blank \(.block) key: \(.key | @json) in \(.file)"
          else
              "::error::bake HCL merge conflict: \(.block) \(.key | @json) differs between latest and retained documents"
          end
    ' <<< "$merge_result" >&2
    exit "$_REFUSAL_STATUS"
fi

jq '.merged' <<< "$merge_result"
