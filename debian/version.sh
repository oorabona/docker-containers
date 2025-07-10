#!/bin/bash
source "$(dirname "$0")/../helpers/docker-tags"

case "${1:-current}" in
    latest)
        # Get latest version from official Debian registry
        latest-docker-tag library/debian "^(bookworm|bullseye|buster)$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        if ! current_version=$(latest-docker-tag oorabona/debian "^(bookworm|bullseye|buster)$"); then
            echo "no-published-version"
            exit 1
        fi
        echo "$current_version"
        ;;
esac
