#!/bin/bash
# PostgreSQL Extension Profile Parser
# Parses .conf files from extensions/profiles/ and returns extension list
# Usage: ./parse-profile.sh <profile-name>
# Example: ./parse-profile.sh ai-ml

set -euo pipefail

# Source shared logging utilities
source "$(dirname "$0")/../../helpers/logging.sh"

# Function to parse profile configuration file
parse_profile() {
    local profile_name="$1"
    local profile_file="$(dirname "$0")/../extensions/profiles/${profile_name}.conf"
    
    if [[ ! -f "$profile_file" ]]; then
        log_error "Profile '$profile_name' not found at: $profile_file"
        log_info "Available profiles:"
        find "$(dirname "$0")/../extensions/profiles/" -name "*.conf" -exec basename {} .conf \; | sort
        return 1
    fi
    
    log_info "Parsing profile: $profile_file"
    
    # Extract extension names from profile file
    # - Remove comments (everything after #)
    # - Remove empty lines
    # - Remove leading/trailing whitespace
    # - Extract first word (extension name)
    local extensions
    extensions=$(grep -v '^[[:space:]]*#' "$profile_file" | \
                grep -v '^[[:space:]]*$' | \
                sed 's/#.*//' | \
                awk '{print $1}' | \
                grep -v '^[[:space:]]*$' | \
                sort -u)
    
    if [[ -z "$extensions" ]]; then
        log_error "No extensions found in profile '$profile_name'"
        return 1
    fi
    
    # Convert to comma-separated list
    echo "$extensions" | tr '\n' ',' | sed 's/,$//'
}

# Function to list available profiles
list_profiles() {
    local profiles_dir="$(dirname "$0")/../extensions/profiles"
    log_info "Available profiles:"
    find "$profiles_dir" -name "*.conf" -exec basename {} .conf \; | sort
}

# Main logic
main() {
    if [[ $# -eq 0 ]]; then
        log_error "Usage: $0 <profile-name>"
        list_profiles
        exit 1
    fi
    
    local profile_name="$1"
    
    # Special case: list available profiles
    if [[ "$profile_name" == "--list" ]]; then
        list_profiles
        exit 0
    fi
    
    # Parse the requested profile
    parse_profile "$profile_name"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi