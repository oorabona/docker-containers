#!/bin/bash
# Single-purpose: Get latest upstream PostgreSQL version
# Updated for modern PostgreSQL container with Citus support

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    # Updated pattern for modern PostgreSQL versions
    echo "^[0-9]+\.[0-9]+-modern$"
    exit 0
fi

# Get latest upstream version from official PostgreSQL registry
# Using PostgreSQL 15 as stable base for modern extensions
POSTGRES_VERSION="15"

# Check if we can get the latest minor version
if command -v curl >/dev/null 2>&1; then
    # Try to get latest 15.x version from Docker Hub API
    LATEST_MINOR=$(curl -s "https://registry.hub.docker.com/v2/repositories/library/postgres/tags/?page_size=100" | \
        grep -o '"name":"15\.[0-9]*"' | \
        sed 's/"name":"//g' | sed 's/"//g' | \
        sort -V | tail -1)
    
    if [[ -n "$LATEST_MINOR" ]]; then
        echo "$LATEST_MINOR"
    else
        echo "$POSTGRES_VERSION"
    fi
else
    # Fallback to base version
    echo "$POSTGRES_VERSION"
fi
