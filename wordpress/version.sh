#!/bin/bash
source "$(dirname "$0")/../helpers/docker-tags"

case "${1:-current}" in
    latest)
        # Get latest version from official WordPress registry
        latest-docker-tag library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        if ! current_version=$(latest-docker-tag oorabona/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$"); then
            echo "no-published-version"
            exit 1
        fi
        echo "$current_version"
        ;;
esac