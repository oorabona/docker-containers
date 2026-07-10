#!/usr/bin/env bash
# Get latest upstream Tor version.
#
#   version.sh --upstream         -> raw upstream version, e.g. 0.4.9.11
#   version.sh --tag-suffix       -> image tag suffix, e.g. -alpine
#   version.sh --registry-pattern -> regex for published default tags

set -euo pipefail

TAG_SUFFIX="-alpine"

case "${1:-}" in
    --registry-pattern)
        echo "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+${TAG_SUFFIX}$"
        exit 0
        ;;
    --tag-suffix)
        echo "$TAG_SUFFIX"
        exit 0
        ;;
esac

upstream_version=$("$(dirname "$0")/../helpers/latest-gitlab-tag" "tpo%2Fcore%2Ftor" \
    --tag-filter '^tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    --version-extract '^tor-([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$')

if [[ -z "$upstream_version" ]]; then
    exit 1
fi

case "${1:-}" in
    --upstream)
        echo "$upstream_version"
        ;;
    *)
        echo "${upstream_version}${TAG_SUFFIX}"
        ;;
esac
