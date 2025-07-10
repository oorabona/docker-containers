#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    latest-docker-tag library/debian "^(bookworm|bullseye|buster)$"
}

# Use standardized version handling
handle_version_request "$1" "oorabona/debian" "^(bookworm|bullseye|buster)$" "get_latest_upstream"
