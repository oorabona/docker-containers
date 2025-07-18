#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    # Get latest version from upstream repository
    source "$(dirname "$0")/../helpers/git-tags"
    latest-git-tag openvpn openvpn
}

# Use standardized version handling
handle_version_request "$1" "oorabona/openvpn" "^v[0-9]+\.[0-9]+\.[0-9]+$" "get_latest_upstream"
