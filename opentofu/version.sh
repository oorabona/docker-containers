#!/bin/bash
# Get latest upstream OpenTofu version.
# Supports multiple output formats for different use cases:
#   version.sh                    → full version with suffix (e.g., 1.12.6-alpine)
#   version.sh --upstream         → raw upstream version (e.g., 1.12.6)
#   version.sh --tag-suffix       → just the suffix (e.g., -alpine)
#   version.sh --registry-pattern → regex for published version matching

TAG_SUFFIX="-alpine"

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

upstream_version=$("$(dirname "$0")/../helpers/latest-github-release" opentofu/opentofu --strip-v)

if [[ -z "$upstream_version" ]]; then
    exit 1
fi

case "$1" in
    --upstream) echo "$upstream_version" ;;
    *) echo "${upstream_version}${TAG_SUFFIX}" ;;
esac
