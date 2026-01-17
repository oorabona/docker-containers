#!/bin/bash
# Get latest upstream Ansible version from PyPI
# Supports multiple output formats for different use cases:
#   version.sh                 → full version with suffix (e.g., 13.2.0-ubuntu)
#   version.sh --upstream      → raw upstream version (e.g., 13.2.0)
#   version.sh --tag-suffix    → just the suffix (e.g., -ubuntu)
#   version.sh --registry-pattern → regex for published version matching

source "$(dirname "$0")/../helpers/python-tags"

TAG_SUFFIX="-ubuntu"

# Handle options
case "$1" in
    --registry-pattern)
        echo "^[0-9]+\.[0-9]+\.[0-9]+${TAG_SUFFIX}$"
        exit 0
        ;;
    --tag-suffix)
        echo "$TAG_SUFFIX"
        exit 0
        ;;
esac

# Get latest upstream version from PyPI
upstream_version=$(get_pypi_latest_version ansible)

if [[ -z "$upstream_version" ]]; then
    exit 1
fi

case "$1" in
    --upstream)
        echo "$upstream_version"
        ;;
    *)
        echo "${upstream_version}${TAG_SUFFIX}"
        ;;
esac
