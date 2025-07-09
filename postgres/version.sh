#!/bin/bash
source "$(dirname "$0")/../helpers/docker-tags"

case "${1:-current}" in
    latest)
        # Get latest version from official PostgreSQL registry
        latest-docker-tag library/postgres "^[0-9]+\.[0-9]+$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        latest-docker-tag oorabona/postgres "^[0-9]+\.[0-9]+$"
        ;;
esac
