#!/bin/bash
# Single-purpose: Get latest upstream Logstash version
# Also defines registry pattern for published versions

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^[0-9]+\.[0-9]+$"
    exit 0
fi

# Get latest upstream version from official Logstash registry using direct helper symlink
"$(dirname "$0")/../helpers/latest-docker-tag" library/logstash "^[0-9]+\.[0-9]+$"
