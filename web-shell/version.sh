#!/bin/bash
# Get latest upstream ttyd version (drives web-shell container versioning)
# Supports multiple output formats for different use cases:
#   version.sh                 → full version with suffix (e.g., 1.7.7-debian)
#   version.sh --upstream      → raw upstream version (e.g., 1.7.7)
#   version.sh --tag-suffix    → just the suffix (e.g., -debian)
#   version.sh --registry-pattern → regex for published version matching

TAG_SUFFIX="-debian"

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

# Get latest upstream version from GitHub releases
upstream_version=$("$(dirname "$0")/../helpers/latest-github-release" tsl0922/ttyd --strip-v)

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
