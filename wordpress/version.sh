#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    latest-docker-tag library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$"
}

# Use standardized version handling
handle_version_request "$1" "oorabona/wordpress" "^[0-9]+\.[0-9]+\.[0-9]+$" "get_latest_upstream"