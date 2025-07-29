#!/bin/bash
# Custom PostgreSQL entrypoint with extension profile support
set -e

# Function to load extension profile
load_extension_profile() {
    local profile=$1
    local profile_file="/etc/postgresql/extensions/profiles/${profile}.conf"
    
    if [[ -f "$profile_file" ]]; then
        echo "Loading extension profile: $profile"
        # Extract extension names from profile file (ignore comments and empty lines)
        grep -v '^#' "$profile_file" | grep -v '^$' | awk '{print $1}' > /tmp/extensions_to_load.txt
        export POSTGRES_EXTENSIONS_FROM_PROFILE=$(cat /tmp/extensions_to_load.txt | tr '\n' ',' | sed 's/,$//')
    else
        echo "Profile file not found: $profile_file"
    fi
}

# Function to enable extensions based on configuration
enable_extensions() {
    local extensions=""
    
    # Priority 1: Use POSTGRES_EXTENSIONS if specified (from .env or build arg)
    if [[ -n "$POSTGRES_EXTENSIONS" ]]; then
        extensions="$POSTGRES_EXTENSIONS"
        echo "Using custom extensions from POSTGRES_EXTENSIONS"
    # Priority 2: Load from profile if specified
    elif [[ -n "$POSTGRES_EXTENSION_PROFILE" ]]; then
        load_extension_profile "$POSTGRES_EXTENSION_PROFILE"
        extensions="$POSTGRES_EXTENSIONS_FROM_PROFILE"
        echo "Using extensions from profile: $POSTGRES_EXTENSION_PROFILE"
    fi
    
    # Export for use in init scripts
    export POSTGRES_ENABLED_EXTENSIONS="$extensions"
    echo "Extensions to enable: $POSTGRES_ENABLED_EXTENSIONS"
}

# Main execution
echo "Starting PostgreSQL with modern extensions..."

# Configure extensions
enable_extensions

# Write extensions list to a file that SQL scripts can read
if [[ -n "$POSTGRES_ENABLED_EXTENSIONS" ]]; then
    # Advanced cleaning - remove all whitespace issues and normalize
    cleaned_extensions=$(echo "$POSTGRES_ENABLED_EXTENSIONS" | \
        tr -d '\n\r' | \
        sed 's/[[:space:]]*,[[:space:]]*/,/g' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        tr -d '\0')
    echo -n "$cleaned_extensions" > /tmp/postgres_extensions.txt
else
    echo -n "" > /tmp/postgres_extensions.txt
fi

# Call the original PostgreSQL entrypoint from the base image
exec /usr/local/bin/docker-entrypoint.sh "$@"
