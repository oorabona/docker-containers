#!/bin/bash
# Single-purpose: Get latest upstream Ansible version from PyPI
# Also defines registry pattern for published versions

source "$(dirname "$0")/../helpers/python-tags"

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^[0-9]+\.[0-9]+\.[0-9]+$"
    exit 0
fi

# Get latest upstream version from PyPI
get_pypi_latest_version ansible
