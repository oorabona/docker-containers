#!/bin/bash
source "$(dirname "$0")/../helpers/git-tags"

case "${1:-current}" in
    latest)
        # Get latest version from upstream repository
        latest-git-tag lmenezes elasticsearch-kopf "v.+$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        source "$(dirname "$0")/../helpers/docker-tags"
        if ! current_version=$(latest-docker-tag oorabona/es-kopf "^v[0-9]+\.[0-9]+\.[0-9]+$"); then
            echo "no-published-version"
            exit 1
        fi
        echo "$current_version"
        ;;
esac
