#!/bin/bash
# Single-purpose: Get latest upstream Debian version
# Also defines registry pattern for published versions

source "$(dirname "$0")/../helpers/docker-tags"

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^(bookworm|bullseye|buster)$"
    exit 0
fi

# Get latest upstream version from official Debian registry
latest-docker-tag library/debian "^(bookworm|bullseye|buster)$"
