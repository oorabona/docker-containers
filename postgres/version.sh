#!/bin/bash
# Single-purpose: Get latest upstream PostgreSQL version
# Also defines registry pattern for published versions
#
# Usage:
#   ./version.sh                  # Latest version (any major)
#   ./version.sh 17               # Latest version for major 17
#   ./version.sh --registry-pattern       # Pattern for any version
#   ./version.sh --registry-pattern 17    # Pattern for major 17

MAJOR_VERSION=""
REGISTRY_PATTERN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry-pattern)
            REGISTRY_PATTERN=true
            shift
            ;;
        [0-9]*)
            MAJOR_VERSION="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Build pattern based on major version
if [[ -n "$MAJOR_VERSION" ]]; then
    PATTERN="^${MAJOR_VERSION}\.[0-9]+-alpine$"
else
    PATTERN="^[0-9]+\.[0-9]+-alpine$"
fi

# For make script: registry pattern for published versions
if [[ "$REGISTRY_PATTERN" == "true" ]]; then
    echo "$PATTERN"
    exit 0
fi

# Get latest upstream version from official PostgreSQL registry
"$(dirname "$0")/../helpers/latest-docker-tag" library/postgres "$PATTERN"
