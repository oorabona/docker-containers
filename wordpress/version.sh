#!/bin/bash
# Single-purpose: Get latest upstream WordPress version
# Returns latest WordPress version from official Docker registry

source "$(dirname "$0")/../helpers/docker-tags"

# Get latest upstream version from official WordPress registry
latest-docker-tag library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$"