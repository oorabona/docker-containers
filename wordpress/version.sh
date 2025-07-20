#!/bin/bash
# Single-purpose: Get latest upstream WordPress version
# Returns latest WordPress version from official Docker registry

# Get latest upstream version from official WordPress registry using direct helper symlink
"$(dirname "$0")/../helpers/latest-docker-tag" library/wordpress "^[0-9]+\.[0-9]+\.[0-9]+$"