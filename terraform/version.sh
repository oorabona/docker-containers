#!/bin/bash
# Single-purpose: Get latest upstream Terraform version
# Also defines registry pattern for published versions

source "$(dirname "$0")/../helpers/docker-tags"

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^[0-9]+\.[0-9]+\.[0-9]+$"
    exit 0
fi

# Get latest upstream version from HashiCorp registry
latest-docker-tag hashicorp/terraform "^[0-9]+\.[0-9]+\.[0-9]+$"
