#!/bin/bash
# Variant utilities for multi-image containers
# Used by build-container.sh and generate-dashboard.sh
#
# Containers with variants.yaml produce multiple images from one Dockerfile
# Structure supports multiple PostgreSQL versions with different variants per version

set -euo pipefail

# Check if a container has variants
has_variants() {
    local container_dir="$1"
    [[ -f "$container_dir/variants.yaml" ]]
}

# List all version tags defined in variants.yaml
# Output: one version tag per line (e.g., "18", "17", "16")
list_versions() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    yq -r '.versions[].tag' "$variants_file" 2>/dev/null || echo ""
}

# Get version count
version_count() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo "0"
        return
    fi

    yq -r '.versions | length' "$variants_file" 2>/dev/null || echo "0"
}

# List all variant names for a specific version
# Usage: list_variants <container_dir> [pg_version]
# Output: one variant name per line
list_variants() {
    local container_dir="$1"
    local pg_version="${2:-}"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    if [[ -n "$pg_version" ]]; then
        # New structure: get variants for specific version
        yq -r ".versions[] | select(.tag == \"$pg_version\") | .variants[].name" "$variants_file" 2>/dev/null || echo ""
    else
        # Fallback: try old structure or return first version's variants
        local result
        result=$(yq -r '.variants[].name' "$variants_file" 2>/dev/null)
        if [[ -z "$result" ]]; then
            # New structure: return first version's variants
            yq -r '.versions[0].variants[].name' "$variants_file" 2>/dev/null || echo ""
        else
            echo "$result"
        fi
    fi
}

# Get variant count for a specific version
variant_count() {
    local container_dir="$1"
    local pg_version="${2:-}"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo "0"
        return
    fi

    if [[ -n "$pg_version" ]]; then
        yq -r ".versions[] | select(.tag == \"$pg_version\") | .variants | length" "$variants_file" 2>/dev/null || echo "0"
    else
        # Fallback
        local result
        result=$(yq -r '.variants | length' "$variants_file" 2>/dev/null)
        if [[ -z "$result" || "$result" == "null" ]]; then
            yq -r '.versions[0].variants | length' "$variants_file" 2>/dev/null || echo "0"
        else
            echo "$result"
        fi
    fi
}

# Get variant property
# Usage: variant_property <container_dir> <variant_name> <property> [pg_version]
# Properties: suffix, flavor, description, default
variant_property() {
    local container_dir="$1"
    local variant_name="$2"
    local property="$3"
    local pg_version="${4:-}"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    if [[ -n "$pg_version" ]]; then
        yq -r ".versions[] | select(.tag == \"$pg_version\") | .variants[] | select(.name == \"$variant_name\") | .$property // \"\"" "$variants_file" 2>/dev/null || echo ""
    else
        # Fallback: try old structure
        local result
        result=$(yq -r ".variants[] | select(.name == \"$variant_name\") | .$property // \"\"" "$variants_file" 2>/dev/null)
        if [[ -z "$result" ]]; then
            # New structure: search in first version
            yq -r ".versions[0].variants[] | select(.name == \"$variant_name\") | .$property // \"\"" "$variants_file" 2>/dev/null || echo ""
        else
            echo "$result"
        fi
    fi
}

# Get the default variant name for a version
default_variant() {
    local container_dir="$1"
    local pg_version="${2:-}"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    if [[ -n "$pg_version" ]]; then
        yq -r ".versions[] | select(.tag == \"$pg_version\") | .variants[] | select(.default == true) | .name // \"\"" "$variants_file" 2>/dev/null | head -1
    else
        # Fallback
        local result
        result=$(yq -r '.variants[] | select(.default == true) | .name // ""' "$variants_file" 2>/dev/null | head -1)
        if [[ -z "$result" ]]; then
            yq -r '.versions[0].variants[] | select(.default == true) | .name // ""' "$variants_file" 2>/dev/null | head -1
        else
            echo "$result"
        fi
    fi
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

# Get base suffix from build config (e.g., "-alpine")
base_suffix() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo ""
        return
    fi

    yq -r '.build.base_suffix // ""' "$variants_file" 2>/dev/null || echo ""
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
# Usage: variant_image_tag <pg_version> <variant_name> <container_dir>
# Example: variant_image_tag "17" "vector" "./postgres" -> "17-vector-alpine"
variant_image_tag() {
    local pg_version="$1"
    local variant_name="$2"
    local container_dir="$3"

    local suffix
    suffix=$(variant_property "$container_dir" "$variant_name" "suffix" "$pg_version")
    local base_sfx
    base_sfx=$(base_suffix "$container_dir")

    if [[ -z "$suffix" ]]; then
        # No suffix = base variant
        echo "${pg_version}${base_sfx}"
    else
        # Insert variant suffix before base suffix
        echo "${pg_version}${suffix}${base_sfx}"
    fi
}

# Get all version+variant combinations for CI matrix
# Output: JSON array for GitHub Actions matrix
# Format: [{"version":"18","variant":"base","tag":"18-alpine","flavor":"base"}, ...]
list_build_matrix() {
    local container_dir="$1"
    local variants_file="$container_dir/variants.yaml"

    if [[ ! -f "$variants_file" ]]; then
        echo "[]"
        return
    fi

    local result="["
    local first=true

    while IFS= read -r pg_version; do
        [[ -z "$pg_version" ]] && continue

        while IFS= read -r variant_name; do
            [[ -z "$variant_name" ]] && continue

            local tag
            tag=$(variant_image_tag "$pg_version" "$variant_name" "$container_dir")
            local flavor
            flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$pg_version")
            local is_default
            is_default=$(variant_property "$container_dir" "$variant_name" "default" "$pg_version")

            if [[ "$first" != "true" ]]; then
                result+=","
            fi
            first=false

            result+="{\"version\":\"$pg_version\",\"variant\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false")}"
        done < <(list_variants "$container_dir" "$pg_version")
    done < <(list_versions "$container_dir")

    result+="]"
    echo "$result"
}

# Get all variant tags for a specific version (for dashboard display)
# Output: JSON array of {name, tag, flavor, description, default}
list_variant_tags() {
    local container_dir="$1"
    local pg_version="$2"
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
        tag=$(variant_image_tag "$pg_version" "$variant_name" "$container_dir")
        local flavor
        flavor=$(variant_property "$container_dir" "$variant_name" "flavor" "$pg_version")
        local description
        description=$(variant_property "$container_dir" "$variant_name" "description" "$pg_version")
        local is_default
        is_default=$(variant_property "$container_dir" "$variant_name" "default" "$pg_version")

        if [[ "$first" != "true" ]]; then
            result+=","
        fi
        first=false

        result+="{\"name\":\"$variant_name\",\"tag\":\"$tag\",\"flavor\":\"$flavor\",\"description\":\"$description\",\"default\":$([[ "$is_default" == "true" ]] && echo "true" || echo "false")}"
    done < <(list_variants "$container_dir" "$pg_version")

    result+="]"
    echo "$result"
}

# Export functions for use in other scripts
export -f has_variants list_versions version_count list_variants variant_count
export -f variant_property default_variant flavor_arg_name base_suffix
export -f requires_extensions variant_image_tag list_build_matrix list_variant_tags
