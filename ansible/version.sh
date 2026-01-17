#!/bin/bash
# Single-purpose: Get latest upstream Ansible version from PyPI
# Returns version with -ubuntu suffix (our images are Ubuntu-based)
# Also defines registry pattern for published versions

source "$(dirname "$0")/../helpers/python-tags"

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^[0-9]+\.[0-9]+\.[0-9]+-ubuntu$"
    exit 0
fi

# Get latest upstream version from PyPI
upstream_version=$(get_pypi_latest_version ansible)

if [[ -n "$upstream_version" ]]; then
    echo "${upstream_version}-ubuntu"
else
    exit 1
fi
