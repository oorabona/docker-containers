#!/bin/bash
source "$(dirname "$0")/../helpers/docker-tags"

case "${1:-current}" in
    latest)
        # Get latest version from official PHP registry
        latest-docker-tag library/php "^[0-9]+\.[0-9]+\.[0-9]+-fpm-alpine$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        if ! current_version=$(latest-docker-tag oorabona/php "^[0-9]+\.[0-9]+\.[0-9]+-fpm-alpine$"); then
            echo "no-published-version"
            exit 1
        fi
        echo "$current_version"
        ;;
esac