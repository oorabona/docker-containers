#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    latest-docker-tag library/postgres "^[0-9]+\.[0-9]+-alpine$"
}

# Use standardized version handling
handle_version_request "$1" "oorabona/postgres" "^[0-9]+\.[0-9]+-alpine$" "get_latest_upstream"
