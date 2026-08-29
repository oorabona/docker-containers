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
extension_containers_json="${EXTENSION_CONTAINERS_JSON:-}"

if [[ -n "$extension_containers_json" ]]; then
    if ! extension_containers_json=$(printf '%s' "$extension_containers_json" | jq -c 'if type == "array" then . else error("not array") end' 2>/dev/null); then
        echo "::error::EXTENSION_CONTAINERS_JSON must be a JSON array when set" >&2
        exit 1
    fi
fi

for container_dir in "$PROJECT_ROOT"/*/; do
    container="$(basename "$container_dir")"
    [[ ! -f "$container_dir/variants.yaml" ]] && continue

    if [[ -n "$extension_containers_json" ]]; then
        if ! printf '%s' "$extension_containers_json" | jq -e --arg c "$container" 'index($c) != null' >/dev/null; then
            continue
        fi
    fi

    if requires_extensions "$container_dir"; then
        echo "::notice::Container $container requires extensions"
        containers_with_extensions="$containers_with_extensions $container"

        # Get declared major inputs for cells that have non-base variants.
        # `major` is a cell-level contract: extension builds consume the numeric
        # PostgreSQL major, never the container image tag.
        versions_needing_extensions=""
        while IFS=$'\t' read -r version_tag major_version; do
            [[ -z "$version_tag" ]] && continue
            if [[ ! "$major_version" =~ ^[0-9]+$ ]]; then
                echo "::error::Container $container version $version_tag must declare a numeric major for extension builds" >&2
                exit 1
            fi

            has_extension_variants=false
            while IFS= read -r variant; do
                [[ -z "$variant" ]] && continue
                flavor=$(variant_property "$container_dir" "$variant" "flavor" "$version_tag")
                if [[ "$flavor" != "base" ]]; then
                    has_extension_variants=true
                    break
                fi
            done < <(list_variants "$container_dir" "$version_tag")

            if [[ "$has_extension_variants" == "true" ]]; then
                versions_needing_extensions="$versions_needing_extensions $major_version"
                echo "  -> v$major_version needs extensions"
            fi
        done < <(yq -r '.versions[] | [.tag, (.major // "")] | @tsv' "$container_dir/variants.yaml")

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
