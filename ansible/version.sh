#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    # Source the python helpers
    source "$(dirname "$0")/../helpers/python-tags"
    get_pypi_latest_version ansible
}

# Use standardized version handling
handle_version_request "$1" "oorabona/ansible" "^[0-9]+\.[0-9]+\.[0-9]+$" "get_latest_upstream"
