#!/bin/bash
# Single-purpose: Get latest upstream PostgreSQL version
# Uses standard helper for consistency with other containers

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^[0-9]+\.[0-9]+$"
    exit 0
fi

# Get latest upstream version from official PostgreSQL registry using standard helper
"$(dirname "$0")/../helpers/latest-docker-tag" library/postgres "^[0-9]+\.[0-9]+$"
