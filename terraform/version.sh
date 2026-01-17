#!/bin/bash
# Single-purpose: Get latest upstream Terraform version
# Returns version with -alpine suffix (our images are Alpine-based)
# Also defines registry pattern for published versions

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^[0-9]+\.[0-9]+\.[0-9]+-alpine$"
    exit 0
fi

# Get latest upstream version from HashiCorp registry using direct helper symlink
upstream_version=$("$(dirname "$0")/../helpers/latest-docker-tag" hashicorp/terraform "^[0-9]+\.[0-9]+\.[0-9]+$")

if [[ -n "$upstream_version" ]]; then
    echo "${upstream_version}-alpine"
else
    exit 1
fi
