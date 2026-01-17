#!/bin/bash
# Variant utilities for multi-image containers
# Used by build-container.sh and generate-dashboard.sh
#
# Containers with variants.yaml produce multiple images from one Dockerfile

set -euo pipefail

# Check if a container has variants
has_variants() {
    local container_dir="$1"
    [[ -f "$container_dir/variants.yaml" ]]
}

# List all variant names for a container
# Output: one variant name per line
list_variants() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    yq -r '.variants[].name' "$variants_file" 2>/dev/null || echo ""
}

# Get variant count
variant_count() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo "0"
        return
    fi

    yq -r '.variants | length' "$variants_file" 2>/dev/null || echo "0"
}

# Get variant property
# Usage: variant_property <container_dir> <variant_name> <property>
# Properties: suffix, flavor, description, default
variant_property() {
    local container_dir="$1"
    local variant_name="$2"
    local property="$3"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    yq -r ".variants[] | select(.name == \"$variant_name\") | .$property // \"\"" "$variants_file" 2>/dev/null || echo ""
}

# Get the default variant name
default_variant() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    yq -r '.variants[] | select(.default == true) | .name // ""' "$variants_file" 2>/dev/null | head -1
}

# Get flavor arg name from build config
flavor_arg_name() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo "FLAVOR"
        return
    fi

    yq -r '.build.flavor_arg // "FLAVOR"' "$variants_file" 2>/dev/null || echo "FLAVOR"
}

# Check if variants require extensions to be built first
requires_extensions() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        return 1
    fi

    local result
    result=$(yq -r '.build.requires_extensions // false' "$variants_file" 2>/dev/null || echo "false")
    [[ "$result" == "true" ]]
}

# Generate image tag for a variant
# Usage: variant_image_tag <base_version> <variant_name> <container_dir>
# Example: variant_image_tag "17-alpine" "vector" "./postgres" -> "17-vector-alpine"
variant_image_tag() {
    local base_version="$1"
    local variant_name="$2"
    local container_dir="$3"

    local suffix
    suffix=$(variant_property "$container_dir" "$variant_name" "suffix")

    if [[ -z "$suffix" ]]; then
        # No suffix = base variant, use original version
        echo "$base_version"
    else
        # Insert suffix before the last part (e.g., "17-alpine" -> "17-vector-alpine")
        # Handle versions like "17.5-alpine" or "17-alpine"
        if [[ "$base_version" =~ ^([0-9]+(\.[0-9]+)?)-(.+)$ ]]; then
            local version_part="${BASH_REMATCH[1]}"
            local suffix_part="${BASH_REMATCH[3]}"
            echo "${version_part}${suffix}-${suffix_part}"
        else
            # Fallback: just append suffix
            echo "${base_version}${suffix}"
        fi
    fi
}

# Get all variant tags for a container version
# Output: JSON array of {name, tag, flavor, description}
list_variant_tags() {
    local container_dir="$1"
    local base_version="$2"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo "[]"
        return
    fi

    local result="["
    local first=true

    while IFS= read -r variant_name; do
        [[ -z "$variant_name" ]] && continue

        local tag
        tag=$(variant_image_tag "$base_version" "$variant_name" "$container_dir")
        local flavor
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor")
        local description
        description=$(variant_property "$container_dir" "$variant_name" "description")
        local is_default
        is_default=$(variant_property "$container_dir" "$variant_name" "default")

        if [[ "$first" != "true" ]]; then
            result+=","
        fi
        first=false

        result+="{\"name\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"description\":\"$description\",\"default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false")}"
    done < <(list_variants "$container_dir")

    result+="]"
    echo "$result"
}

# Export functions for use in other scripts
export -f has_variants list_variants variant_count variant_property default_variant
export -f flavor_arg_name requires_extensions variant_image_tag list_variant_tags
