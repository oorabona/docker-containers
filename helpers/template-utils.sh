#!/bin/bash
# Generic Dockerfile template expansion utilities
# Replaces @@MARKER@@ comment lines in a Dockerfile template with generated content.
#
# Usage pattern:
#   1. Check: has_template_markers "path/to/Dockerfile"
#   2. Expand: expand_template "path/to/Dockerfile" MARKER1 "$content1" MARKER2 "$content2"
#
# Markers in Dockerfiles look like: # @@MARKER_NAME@@
# Each container's generator computes the replacement content for its markers.

set -euo pipefail

_TEMPLATE_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logging if available
if [[ -f "$_TEMPLATE_UTILS_DIR/logging.sh" ]]; then
    source "$_TEMPLATE_UTILS_DIR/logging.sh"
else
    log_info()    { echo "INFO: $*" >&2; }
    log_error()   { echo "ERROR: $*" >&2; }
fi

# Check if a file contains any @@MARKER@@ template patterns
# Usage: has_template_markers <file>
# Returns 0 (true) if markers found, 1 otherwise
has_template_markers() {
    local file="$1"
    grep -qE '@@[A-Z_]+@@' "$file" 2>/dev/null
}

# Expand template markers in a Dockerfile
# Usage: expand_template <template_file> <MARKER1> <content1> [<MARKER2> <content2> ...]
# Each pair: marker name (without @@) and its replacement content.
# Empty content = marker line is removed silently.
# Lines without markers pass through unchanged.
expand_template() {
    local template="$1"
    shift

    if [[ ! -f "$template" ]]; then
        log_error "Template file not found: $template"
        return 1
    fi

    # Collect marker→content pairs into parallel arrays (bash 4.0+ compat without assoc arrays)
    local -a _marker_names=()
    local -a _marker_content=()
    while [[ $# -ge 2 ]]; do
        _marker_names+=("$1")
        _marker_content+=("$2")
        shift 2
    done

    if [[ ${#_marker_names[@]} -eq 0 ]]; then
        log_error "expand_template: no marker pairs provided"
        return 1
    fi

    # Process template line by line
    while IFS= read -r line; do
        local matched=false
        local i
        for i in "${!_marker_names[@]}"; do
            if [[ "$line" == *"@@${_marker_names[$i]}@@"* ]]; then
                # Replace marker line with content (if non-empty)
                [[ -n "${_marker_content[$i]}" ]] && printf '%s' "${_marker_content[$i]}"
                matched=true
                break
            fi
        done
        [[ "$matched" != "true" ]] && printf '%s\n' "$line"
    done < "$template"
}
