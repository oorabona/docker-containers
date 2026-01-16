#!/bin/bash
# Single-purpose: Get latest upstream WordPress version
# Returns WordPress version with -alpine suffix (our images are Alpine-based)
# Supports --registry-pattern for dashboard version detection

# Registry pattern for finding our published versions (X.Y.Z-alpine, excludes architecture suffixes)
REGISTRY_PATTERN="^[0-9]+\.[0-9]+\.[0-9]+-alpine$"

if [[ "$1" == "--registry-pattern" ]]; then
    echo "$REGISTRY_PATTERN"
    exit 0
fi

# Get latest upstream version from official WordPress registry
upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$")

if [[ -n "$upstream_version" ]]; then
    # Append -alpine suffix since our image is Alpine-based
    echo "${upstream_version}-alpine"
else
    exit 1
fi