#!/usr/bin/env bash
# Sum per-extension build durations for a given flavor.
#
# Called by build-container.sh AFTER the per-extension lineage files have been
# written by build-extensions.sh in the same CI run.  Extensions that were
# skipped (image already in registry → no lineage file written) contribute 0
# to the total, which accurately reflects "this build run cost".
#
# Usage: sum_flavor_extension_durations <container> <flavor> <pg_major>

# Resolve helpers directory from this script's own location
_EXT_DUR_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source extension-utils for get_flavor_extensions()
# shellcheck source=./extension-utils.sh
source "$_EXT_DUR_HELPERS_DIR/extension-utils.sh"

# sum_flavor_extension_durations <container> <flavor> <pg_major>
#
# Reads .build-lineage/ext-<ext>-pg<pg_major>-<ext_version>.json files
# written during this CI run by build-extensions.sh.
#
# Returns (stdout):
#   integer — total seconds for all rebuilt extensions this run
#   "null"  — container has no extension config, or the flavor has no extensions
sum_flavor_extension_durations() {
    local container="$1"
    local flavor="$2"
    local pg_major="$3"

    # ROOT_DIR set by build-extensions.sh callers; PROJECT_ROOT set by build-container.sh;
    # fall back to PWD for direct invocation/tests.
    local root="${ROOT_DIR:-${PROJECT_ROOT:-.}}"
    local config_file="${root}/${container}/extensions/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo "null"
        return 0
    fi

    # Collect the extension list for this flavor/pg_major combination
    local ext_list
    ext_list=$(get_flavor_extensions "$config_file" "$flavor" "$pg_major" 2>/dev/null || true)

    if [[ -z "$ext_list" ]]; then
        # Flavor exists but has no compiled extensions → genuinely zero contribution
        # this build (vs. "null" which signals "container has no extensions concept
        # at all" — handled by the missing config_file branch above).
        echo "0"
        return 0
    fi

    local total=0
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue

        # Aggregate ALL per-version lineage files present for this extension+major.
        # With version-set fan-out, the ceiling tag may already exist in the registry
        # (no lineage written this run) while older retained versions were backfilled
        # (their lineage files were written). Summing only the ceiling file would
        # record 0 even though builds happened. Exclude the versionset artifact
        # (ext-<ext>-pg<major>-versionset.json) — it has no duration_seconds field.
        local lineage_glob="${root}/.build-lineage/ext-${ext}-pg${pg_major}-*.json"
        # shellcheck disable=SC2086
        for lineage_file in $lineage_glob; do
            [[ -f "$lineage_file" ]] || continue
            # Skip the versionset artifact — it contains no duration_seconds
            [[ "$lineage_file" == *"-versionset.json" ]] && continue
            local d
            d=$(jq -r '.duration_seconds // 0' "$lineage_file" 2>/dev/null || echo 0)
            # Guard against non-numeric output from jq (e.g. "null" when field absent)
            if [[ "$d" =~ ^[0-9]+$ ]]; then
                total=$(( total + d ))
            else
                log_warning "$lineage_file: non-integer duration_seconds, treating as 0"
            fi
        done
        # No lineage files for this ext → all versions were cached; contributes 0 this run
    done <<< "$ext_list"

    echo "$total"
}
