#!/bin/bash
source "$(dirname "$0")/../helpers/git-tags"

case "${1:-current}" in
    latest)
        # Get latest version from upstream repository
        latest-git-tag yrutschle sslh "v.+$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        source "$(dirname "$0")/../helpers/docker-tags"
        latest-docker-tag oorabona/sslh "^v[0-9]+\.[0-9]+\.[0-9]+$"
        ;;
esac
