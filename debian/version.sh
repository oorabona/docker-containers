#!/bin/bash
# Single-purpose: Get latest upstream Debian version
# Also defines registry pattern for published versions

# For make script: registry pattern for published versions
if [ "$1" = "--registry-pattern" ]; then
    echo "^(trixie|bookworm|bullseye)$"
    exit 0
fi

if [ "$1" = "--numeric-alias-image" ]; then
    echo "library/debian"
    exit 0
fi

if [ "$1" = "--numeric-alias-pattern" ]; then
    echo "^[0-9]+$"
    exit 0
fi

# Debian tags are plain codenames (trixie/bookworm/bullseye) — no suffix.
if [ "$1" = "--tag-suffix" ]; then
    echo ""
    exit 0
fi

# Get latest upstream version from official Debian registry using direct helper symlink
"$(dirname "$0")/../helpers/latest-docker-tag" library/debian "^(trixie|bookworm|bullseye)$"
