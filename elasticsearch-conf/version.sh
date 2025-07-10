#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version from GitHub releases
get_latest_upstream() {
    latest-git-tag kelseyhightower confd "v.+$"
}

# Use standardized version handling
handle_version_request "$1" "oorabona/elasticsearch-conf" "^v[0-9]+\.[0-9]+\.[0-9]+$" "get_latest_upstream"
