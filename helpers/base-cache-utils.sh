#!/bin/bash
# Base image cache utilities
# Reads base_image_cache from config.yaml and provides helpers for:
# - Caching Docker Hub base images to GHCR (CI cache job)
# - Resolving cached base image build args (build action)
#
# Config schema (in config.yaml):
#   base_image_cache:
#     - arg: BASE_IMAGE           # Dockerfile ARG name to override
#       source: ubuntu             # Docker Hub image name
#       ghcr_repo: ubuntu-base     # GHCR cache repo name
#       tags: ["latest"]           # Tags to cache
#     - arg: BASE_IMAGE
#       source: postgres
#       ghcr_repo: postgres-base
#       tags_from_versions: true   # Derive tags from variants.yaml versions + base_suffix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source variant utils for tags_from_versions resolution
source "$SCRIPT_DIR/variant-utils.sh"

# Resolve a tag template by substituting ${VERSION} and ${KEY} placeholders
# Usage: _resolve_tag_template <template> <build_version> <config_file>
# Output: resolved tag string
_resolve_tag_template() {
    local tag_template="$1"
    local build_version="$2"
    local config_file="$3"

    # Resolve ${VERSION} → detected build version
    local tag="${tag_template//\$\{VERSION\}/$build_version}"

    # Resolve ${KEY} → value from build_args in config.yaml
    while [[ "$tag" =~ \$\{([A-Z_]+)\} ]]; do
        local key="${BASH_REMATCH[1]}"
        local val
        val=$(yq -r ".build_args.$key // \"\"" "$config_file")
        tag="${tag//\$\{$key\}/$val}"
    done

    echo "$tag"
}

# Collect tags for a single cache entry, returns JSON array of image objects
# Usage: _collect_entry_tags <container_dir> <config_file> <entry_index> <build_version> <owner>
_collect_entry_tags() {
    local container_dir="$1"
    local config_file="$2"
    local entry_index="$3"
    local build_version="$4"
    local owner="$5"

    local source ghcr_repo
    source=$(yq -r ".base_image_cache[$entry_index].source" "$config_file")
    ghcr_repo=$(yq -r ".base_image_cache[$entry_index].ghcr_repo" "$config_file")

    local tags_from_versions
    tags_from_versions=$(yq -r ".base_image_cache[$entry_index].tags_from_versions // false" "$config_file")

    local images="[]"

    if [[ "$tags_from_versions" == "true" ]]; then
        local base_sfx
        base_sfx=$(base_suffix "$container_dir")

        for major_version in $(list_versions "$container_dir"); do
            local full_tag="${major_version}${base_sfx}"
            images=$(echo "$images" | jq -c \
                --arg source "$source" \
                --arg tag "$full_tag" \
                --arg ghcr_repo "$ghcr_repo" \
                --arg ghcr_image "ghcr.io/$owner/$ghcr_repo:$full_tag" \
                '. + [{source: $source, tag: $tag, ghcr_repo: $ghcr_repo, ghcr_image: $ghcr_image}]')
        done
    else
        local tag_count
        tag_count=$(yq -r ".base_image_cache[$entry_index].tags | length" "$config_file")

        for ((k = 0; k < tag_count; k++)); do
            local tag_template
            tag_template=$(yq -r ".base_image_cache[$entry_index].tags[$k]" "$config_file")
            local tag
            tag=$(_resolve_tag_template "$tag_template" "$build_version" "$config_file")

            images=$(echo "$images" | jq -c \
                --arg source "$source" \
                --arg tag "$tag" \
                --arg ghcr_repo "$ghcr_repo" \
                --arg ghcr_image "ghcr.io/$owner/$ghcr_repo:$tag" \
                '. + [{source: $source, tag: $tag, ghcr_repo: $ghcr_repo, ghcr_image: $ghcr_image}]')
        done
    fi

    echo "$images"
}

# Check if a container has base_image_cache config
# Usage: has_base_cache <container_dir>
has_base_cache() {
    local container_dir="$1"
    local config_file="$container_dir/config.yaml"

    [[ -f "$config_file" ]] && \
        yq -e '.base_image_cache | length > 0' "$config_file" &>/dev/null
}

# Collect all cache images across all containers, deduplicated
# Usage: collect_all_cache_images <containers_json> <versions_json> <owner>
#   containers_json: JSON array of container names, e.g. '["ansible","postgres"]'
#   versions_json:   JSON object of {container: version}, e.g. '{"ansible":"latest","postgres":"18.1"}'
#   owner:           GHCR owner, e.g. "oorabona"
# Output: JSON array of {source, tag, ghcr_repo, ghcr_image} for each unique image to cache
collect_all_cache_images() {
    local containers_json="$1"
    local versions_json="$2"
    local owner="$3"

    local all_images="[]"

    # Iterate containers from JSON array
    local count
    count=$(echo "$containers_json" | jq -r 'length')

    for ((i = 0; i < count; i++)); do
        local container
        container=$(echo "$containers_json" | jq -r ".[$i]")
        local container_dir="./$container"
        local config_file="$container_dir/config.yaml"

        [[ ! -f "$config_file" ]] && continue
        has_base_cache "$container_dir" || continue

        # Get the detected version for this container
        local build_version
        build_version=$(echo "$versions_json" | jq -r --arg c "$container" '.[$c] // "latest"')

        # Read base_image_cache entries
        local entry_count
        entry_count=$(yq -r '.base_image_cache | length' "$config_file")

        for ((j = 0; j < entry_count; j++)); do
            local entry_images
            entry_images=$(_collect_entry_tags "$container_dir" "$config_file" "$j" "$build_version" "$owner")
            all_images=$(echo "$all_images $entry_images" | jq -c -s 'add')
        done
    done

    # Deduplicate by ghcr_image (same repo+tag cached once)
    echo "$all_images" | jq -c 'unique_by(.ghcr_image)'
}

# Get --build-arg flags for a container's cached base images
# Usage: get_cache_build_args <container_dir> <owner> [build_version]
#   container_dir: e.g. "./ansible"
#   owner:         GHCR owner, e.g. "oorabona"
#   build_version: detected version (for resolving ${VERSION} in tags)
# Output: space-separated --build-arg flags, e.g.:
#   --build-arg BASE_IMAGE=ghcr.io/oorabona/ubuntu-base
get_cache_build_args() {
    local container_dir="$1"
    local owner="$2"
    local build_version="${3:-latest}"
    local config_file="$container_dir/config.yaml"

    [[ ! -f "$config_file" ]] && return 0
    has_base_cache "$container_dir" || return 0

    local entry_count
    entry_count=$(yq -r '.base_image_cache | length' "$config_file")

    local args=""
    for ((i = 0; i < entry_count; i++)); do
        local arg ghcr_repo
        arg=$(yq -r ".base_image_cache[$i].arg" "$config_file")
        ghcr_repo=$(yq -r ".base_image_cache[$i].ghcr_repo" "$config_file")

        # The build-arg overrides the Dockerfile ARG with the GHCR repo path
        # The tag is handled by the Dockerfile's existing tag logic
        args+=" --build-arg ${arg}=ghcr.io/${owner}/${ghcr_repo}"
    done

    echo "$args"
}

# Export functions
export -f _resolve_tag_template _collect_entry_tags has_base_cache collect_all_cache_images get_cache_build_args
