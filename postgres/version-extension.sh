#!/bin/bash
# Get latest upstream version for PostgreSQL extensions
#
# Usage:
#   ./version-extension.sh <extension-name>     # Latest version
#   ./version-extension.sh --list               # List all extensions
#   ./version-extension.sh --all                # All extensions with versions
#   ./version-extension.sh --json <extension>   # JSON output
#
# Examples:
#   ./version-extension.sh pgvector
#   ./version-extension.sh citus
#   ./version-extension.sh --all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/extensions/config.yaml"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

error() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}Warning:${NC} $*" >&2; }

# Check dependencies
check_deps() {
    if ! command -v yq &>/dev/null; then
        error "yq not found. Install with: brew install yq"
    fi
    if ! command -v curl &>/dev/null; then
        error "curl not found"
    fi
}

# Get extension repo from config
get_ext_repo() {
    local ext_name="$1"
    yq -r ".extensions.${ext_name}.repo // \"\"" "$CONFIG_FILE"
}

# Get extension configured version from config
get_ext_configured_version() {
    local ext_name="$1"
    yq -r ".extensions.${ext_name}.version // \"\"" "$CONFIG_FILE"
}

# Get latest release version from GitHub API
# Handles both "v1.2.3" and "1.2.3" tag formats
get_github_latest_version() {
    local repo="$1"
    local response
    local version

    # Try GitHub API (rate limited without auth, but usually works for single requests)
    response=$(curl -sL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)

    # Extract tag_name
    version=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)

    # If no release found, try tags
    if [[ -z "$version" || "$version" == "null" ]]; then
        response=$(curl -sL \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
            "https://api.github.com/repos/${repo}/tags?per_page=1" 2>/dev/null)

        version=$(echo "$response" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # Strip 'v' prefix if present
    version="${version#v}"

    echo "$version"
}

# List all extensions
list_extensions() {
    yq -r '.extensions | keys | .[]' "$CONFIG_FILE"
}

# Get version for a single extension
get_extension_version() {
    local ext_name="$1"
    local json_output="${2:-false}"

    local repo
    repo=$(get_ext_repo "$ext_name")

    if [[ -z "$repo" ]]; then
        error "Extension '$ext_name' not found in config"
    fi

    local latest_version
    latest_version=$(get_github_latest_version "$repo")

    if [[ -z "$latest_version" ]]; then
        error "Could not fetch latest version for $ext_name from $repo"
    fi

    if [[ "$json_output" == "true" ]]; then
        local configured_version
        configured_version=$(get_ext_configured_version "$ext_name")
        local needs_update="false"
        if [[ "$configured_version" != "$latest_version" ]]; then
            needs_update="true"
        fi
        echo "{\"extension\":\"$ext_name\",\"repo\":\"$repo\",\"latest\":\"$latest_version\",\"configured\":\"$configured_version\",\"needs_update\":$needs_update}"
    else
        echo "$latest_version"
    fi
}

# Get all extensions with their versions
get_all_versions() {
    local json_output="${1:-false}"

    if [[ "$json_output" == "true" ]]; then
        echo "["
        local first=true
    fi

    for ext in $(list_extensions); do
        local repo
        repo=$(get_ext_repo "$ext")
        local latest
        latest=$(get_github_latest_version "$repo" 2>/dev/null || echo "")
        local configured
        configured=$(get_ext_configured_version "$ext")

        if [[ "$json_output" == "true" ]]; then
            [[ "$first" == "true" ]] || echo ","
            first=false
            local needs_update="false"
            [[ "$configured" != "$latest" ]] && needs_update="true"
            echo "  {\"extension\":\"$ext\",\"repo\":\"$repo\",\"latest\":\"${latest:-unknown}\",\"configured\":\"$configured\",\"needs_update\":$needs_update}"
        else
            local status=""
            if [[ -n "$latest" && "$configured" != "$latest" ]]; then
                status=" ${YELLOW}(update: $configured -> $latest)${NC}"
            elif [[ -z "$latest" ]]; then
                status=" ${RED}(fetch failed)${NC}"
            else
                status=" ${GREEN}(up to date)${NC}"
            fi
            echo -e "$ext: $configured$status"
        fi
    done

    if [[ "$json_output" == "true" ]]; then
        echo "]"
    fi
}

# Update version in config.yaml
update_config_version() {
    local ext_name="$1"
    local new_version="$2"

    if ! yq -i ".extensions.${ext_name}.version = \"$new_version\"" "$CONFIG_FILE"; then
        error "Failed to update version for $ext_name"
    fi
    echo "Updated $ext_name to version $new_version"
}

# Main
main() {
    check_deps

    local json_output=false
    local update_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                list_extensions
                exit 0
                ;;
            --all)
                shift
                [[ "${1:-}" == "--json" ]] && json_output=true
                get_all_versions "$json_output"
                exit 0
                ;;
            --json)
                json_output=true
                shift
                ;;
            --update)
                update_mode=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS] [extension-name]"
                echo ""
                echo "Options:"
                echo "  --list           List all extension names"
                echo "  --all            Show all extensions with versions"
                echo "  --json           Output in JSON format"
                echo "  --update <ext>   Update config with latest version"
                echo "  -h, --help       Show this help"
                echo ""
                echo "Examples:"
                echo "  $0 pgvector           # Get latest pgvector version"
                echo "  $0 --all              # Show all extension versions"
                echo "  $0 --update citus     # Update citus to latest"
                exit 0
                ;;
            *)
                if [[ "$update_mode" == "true" ]]; then
                    ext_name="$1"
                    latest=$(get_extension_version "$ext_name")
                    update_config_version "$ext_name" "$latest"
                else
                    get_extension_version "$1" "$json_output"
                fi
                exit 0
                ;;
        esac
    done

    # No arguments - show help
    echo "Usage: $0 [--list|--all|--json|--update] [extension-name]"
    echo "Run '$0 --help' for more information."
}

main "$@"
