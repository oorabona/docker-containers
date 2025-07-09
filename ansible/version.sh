#!/bin/bash

# Source the python helpers
source "$(dirname "$0")/../helpers/python-tags"

case "${1:-current}" in
    latest)
        # Get latest version from PyPI
        get_pypi_latest_version ansible
        ;;
    current|*)
        # Get our currently published version from Docker Hub
        source "$(dirname "$0")/../helpers/docker-tags"
        latest-docker-tag oorabona/ansible "^[0-9]+\.[0-9]+\.[0-9]+$"
        ;;
esac
