#!/bin/bash
# Single-purpose: Get latest upstream WordPress version
# Returns latest WordPress version from official Docker registry
# Supports --registry-pattern for dashboard version detection

# Registry pattern for finding our published versions (excludes architecture suffixes)
REGISTRY_PATTERN="^[0-9]+\.[0-9]+\.[0-9]+$"

if [[ "$1" == "--registry-pattern" ]]; then
    echo "$REGISTRY_PATTERN"
    exit 0
fi

# Get latest upstream version from official WordPress registry using direct helper symlink
"$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "$REGISTRY_PATTERN"