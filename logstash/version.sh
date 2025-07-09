#!/bin/bash
source "$(dirname "$0")/../helpers/docker-tags"

case "${1:-current}" in
    latest)
        # Get latest version from official Logstash registry
        latest-docker-tag library/logstash "^[0-9]+\.[0-9]+$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        latest-docker-tag oorabona/logstash "^[0-9]+\.[0-9]+$"
        ;;
esac
