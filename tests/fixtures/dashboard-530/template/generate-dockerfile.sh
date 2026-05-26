#!/usr/bin/env bash
# Minimal generate-dockerfile.sh for dashboard-530 template fixture.
# Reads config.yaml::distros.<flavor>.base_image and expands the template.
# Args: <template_file> <flavor> [<version>] [<build_flavor>]
set -euo pipefail

template_file="${1:?template file required}"
flavor="${2:?flavor required}"
# version and build_flavor are optional (used by real generators, not needed here)

script_dir="$(cd "$(dirname "$0")" && pwd)"
config_file="$script_dir/config.yaml"

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: config.yaml not found at $config_file" >&2
    exit 1
fi

# Read base_image for this distro/flavor
base_image=$(yq -r ".distros[\"$flavor\"].base_image // \"\"" "$config_file" 2>/dev/null || true)
if [[ -z "$base_image" ]]; then
    echo "ERROR: no distros.$flavor.base_image in $config_file" >&2
    exit 1
fi

# Expand template: replace @@BASE_IMAGE@@ with FROM <base_image>
while IFS= read -r line; do
    case "$line" in
        "@@BASE_IMAGE@@")
            echo "FROM $base_image"
            ;;
        *)
            echo "${line//@@FLAVOR@@/$flavor}"
            ;;
    esac
done < "$template_file"
