#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    latest-docker-tag library/php "^[0-9]+\.[0-9]+\.[0-9]+-fpm-alpine$"
}

# Use standardized version handling
handle_version_request "$1" "oorabona/php" "^[0-9]+\.[0-9]+\.[0-9]+-fpm-alpine$" "get_latest_upstream"