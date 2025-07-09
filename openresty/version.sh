#!/bin/bash
source "$(dirname "$0")/../helpers/git-tags"

case "${1:-current}" in
    latest)
        # Get latest version from upstream repository
        latest-git-tag openresty openresty | cut -c2-
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        source "$(dirname "$0")/../helpers/docker-tags"
        latest-docker-tag oorabona/openresty "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"
        ;;
esac
