#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

# Function to get latest upstream version
get_latest_upstream() {
    # Get latest version from official Logstash registry
    latest-docker-tag library/logstash "^[0-9]+\.[0-9]+$"
}

# Use standardized version handling
handle_version_request "$1" "oorabona/logstash" "^[0-9]+\.[0-9]+$" "get_latest_upstream"
