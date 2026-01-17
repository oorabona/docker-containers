#!/bin/bash
# Jekyll version discovery script
# Fetches the latest stable Jekyll version from RubyGems

set -euo pipefail

# Check for flags
if [[ "${1:-}" == "--registry-pattern" ]]; then
    # Pattern for matching our published tags: X.Y.Z-alpine
    echo '^[0-9]+\.[0-9]+\.[0-9]+-alpine$'
    exit 0
fi

# Fetch latest Jekyll version from RubyGems API
JEKYLL_VERSION=$(curl -sf "https://rubygems.org/api/v1/versions/jekyll/latest.json" | jq -r '.version' 2>/dev/null)

if [[ -z "$JEKYLL_VERSION" || "$JEKYLL_VERSION" == "null" ]]; then
    echo "Failed to fetch Jekyll version" >&2
    exit 1
fi

# Output version with alpine suffix (our tag format)
echo "${JEKYLL_VERSION}-alpine"
