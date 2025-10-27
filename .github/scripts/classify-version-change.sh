#!/bin/bash
#
# Version Change Classification Script
# Determines if a version change is major (requires PR) or minor/patch (auto-build)
#
# Usage: ./classify-version-change.sh <current_version> <new_version>
# 
# Output: Always exactly two lines, in this order:
#   change_type=VALUE
#   reason=DESCRIPTION
#   (No other output will be produced except on error)
# 
# Where:
#   - change_type: "major" or "minor"
#   - reason: Human-readable description of the change
# 
# Examples:
#   change_type=major
#   reason=🆕 New container - first publication
#   
#   change_type=major
#   reason=🔄 Major version update detected (1 → 2)
#   
#   change_type=minor
#   reason=🚀 Minor/patch version update detected

set -euo pipefail

current_version="${1:-}"
new_version="${2:-}"

# Check for required new version
if [[ -z "$new_version" ]]; then
    echo "Usage: $0 <current_version> <new_version>"
    exit 1
fi

# Handle case where current_version is empty (new container or no current version)
if [[ -z "$current_version" ]]; then
    echo "change_type=major"
    echo "reason=🆕 New container - first publication"
    exit 0
fi

# Function to extract major version from various formats
extract_major_version() {
    local version="$1"
    
    # Remove common prefixes
    version=$(echo "$version" | sed 's/^v//i')
    
    # Semver: 1.2.3 -> 1
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Major.Minor: 1.2 -> 1
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Date-based: 2024.1, 2024-01, 20240101 -> 2024
    if [[ "$version" =~ ^([0-9]{4})[-\.]?([0-9]{1,2})? ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # PHP-style: 8.1, 8.2 -> 8
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Single number: 15, 16 -> number itself
    if [[ "$version" =~ ^([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Alpine/suffix versions: 3.18-alpine -> 3
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Default: return first number found
    if [[ "$version" =~ ([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # If no numbers found, return the version as-is
    echo "$version"
}

# Extract major versions
current_major=$(extract_major_version "$current_version")
new_major=$(extract_major_version "$new_version")

# Debug output (can be enabled with DEBUG=1)
if [[ "${DEBUG:-}" == "1" ]]; then
    echo "DEBUG: Current version: $current_version -> Major: $current_major" >&2
    echo "DEBUG: New version: $new_version -> Major: $new_major" >&2
fi

# Compare major versions
if [[ "$current_major" != "$new_major" ]]; then
    echo "change_type=major"
    echo "reason=🔄 Major version update detected ($current_major → $new_major)"
else
    echo "change_type=minor"
    echo "reason=🚀 Minor/patch version update detected"
fi
