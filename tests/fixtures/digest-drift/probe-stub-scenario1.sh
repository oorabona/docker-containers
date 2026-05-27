#!/usr/bin/env bash
# Fixture probe that reads pre-captured registry responses from scenario-1/responses/.
# Maps image_ref to filename: replace : and / with - (e.g. alpine:3.21 -> alpine-3.21.json)
image_ref="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
responses_dir="${SCRIPT_DIR}/scenario-1/responses"
key="$(printf '%s' "$image_ref" | tr ':/' '--')"
response_file="${responses_dir}/${key}.json"
if [[ -f "$response_file" ]]; then
    cat "$response_file"
    exit 0
else
    echo "no fixture for '$image_ref' (expected $response_file)" >&2
    exit 1
fi
