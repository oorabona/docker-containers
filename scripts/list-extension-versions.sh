#!/usr/bin/env bash
# List containers and versions requiring extensions
# Used by auto-build.yaml to determine which extension images to build
#
# Output (via GITHUB_OUTPUT if set, else stdout):
#   containers=<space-separated list>
#   versions_map=<container1:v1,v2|container2:v3,v4>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/helpers/variant-utils.sh"

containers_with_extensions=""
versions_by_container=""

for container_dir in "$PROJECT_ROOT"/*/; do
    container="$(basename "$container_dir")"
    [[ ! -f "$container_dir/variants.yaml" ]] && continue

    if requires_extensions "$container_dir"; then
        echo "::notice::Container $container requires extensions"
        containers_with_extensions="$containers_with_extensions $container"

        # Get versions that have non-base variants
        versions_needing_extensions=""
        while IFS= read -r major_version; do
            [[ -z "$major_version" ]] && continue

            has_extension_variants=false
            while IFS= read -r variant; do
                [[ -z "$variant" ]] && continue
                flavor=$(variant_property "$container_dir" "$variant" "flavor" "$major_version")
                if [[ "$flavor" != "base" ]]; then
                    has_extension_variants=true
                    break
                fi
            done < <(list_variants "$container_dir" "$major_version")

            if [[ "$has_extension_variants" == "true" ]]; then
                versions_needing_extensions="$versions_needing_extensions $major_version"
                echo "  -> v$major_version needs extensions"
            fi
        done < <(list_versions "$container_dir")

        versions_by_container="$versions_by_container|$container:$(echo $versions_needing_extensions | xargs | tr ' ' ',')"
    fi
done

# Trim leading spaces
containers_with_extensions=$(echo "$containers_with_extensions" | xargs)
versions_map="${versions_by_container#|}"

# Output results
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "containers=$containers_with_extensions" >> "$GITHUB_OUTPUT"
    echo "versions_map=$versions_map" >> "$GITHUB_OUTPUT"
fi

echo "Containers with extensions: $containers_with_extensions"
echo "Versions map: $versions_map"
