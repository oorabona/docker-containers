#!/bin/bash
# Single-purpose: Get latest upstream OpenVPN version
# Also defines registry pattern for published versions

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^v[0-9]+\.[0-9]+\.[0-9]+$"
    exit 0
fi

# Get latest upstream version from GitHub releases using direct helper symlink
"$(dirname "$0")/../helpers/latest-git-tag" openvpn openvpn
