#!/bin/bash
source "$(dirname "$0")/../helpers/docker-tags"

case "${1:-current}" in
    latest)
        # Get latest version from official Terraform registry
        latest-docker-tag hashicorp/terraform "^[0-9]+\.[0-9]+\.[0-9]+$"
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        latest-docker-tag oorabona/terraform "^[0-9]+\.[0-9]+\.[0-9]+$"
        ;;
esac
