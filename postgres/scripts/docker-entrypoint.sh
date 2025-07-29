#!/bin/bash
# Custom PostgreSQL entrypoint with extension profile support
set -e

# Function to load extension profile(s) - supports composition with +
load_extension_profile() {
    local profiles=$1
    local all_extensions=""
    
    # Split profiles by + for composition support
    IFS='+' read -ra PROFILE_ARRAY <<< "$profiles"
    
    for profile in "${PROFILE_ARRAY[@]}"; do
        # Trim whitespace
        profile=$(echo "$profile" | xargs)
        local profile_file="/etc/postgresql/extensions/profiles/${profile}.conf"
        
        if [[ -f "$profile_file" ]]; then
            echo "Loading extension profile: $profile"
            # Extract extension names from profile file (ignore comments and empty lines)
            local profile_extensions=$(grep -v '^#' "$profile_file" | grep -v '^$' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
            
            # Append to all extensions (avoiding duplicates will be handled later)
            if [[ -n "$all_extensions" && -n "$profile_extensions" ]]; then
                all_extensions="${all_extensions},${profile_extensions}"
            elif [[ -n "$profile_extensions" ]]; then
                all_extensions="$profile_extensions"
            fi
        else
            echo "Warning: Profile file not found: $profile_file"
        fi
    done
    
    # Remove duplicates and export
    if [[ -n "$all_extensions" ]]; then
        # Convert to array, remove duplicates, convert back to comma-separated
        IFS=',' read -ra EXT_ARRAY <<< "$all_extensions"
        local unique_extensions=()
        for ext in "${EXT_ARRAY[@]}"; do
            ext=$(echo "$ext" | xargs)  # trim whitespace
            if [[ ! " ${unique_extensions[@]} " =~ " ${ext} " ]] && [[ -n "$ext" ]]; then
                unique_extensions+=("$ext")
            fi
        done
        export POSTGRES_EXTENSIONS_FROM_PROFILE=$(printf "%s," "${unique_extensions[@]}" | sed 's/,$//')
        echo "Composed profile extensions: $POSTGRES_EXTENSIONS_FROM_PROFILE"
    else
        export POSTGRES_EXTENSIONS_FROM_PROFILE=""
        echo "No extensions found in specified profiles"
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
echo "Starting PostgreSQL with modern extensions and dynamic configuration..."

# Configure extensions
enable_extensions

# Write extensions list to a file that SQL scripts can read (including universals)
if [[ -n "$POSTGRES_ENABLED_EXTENSIONS" ]]; then
    # Advanced cleaning - remove all whitespace issues and normalize
    cleaned_extensions=$(echo "$POSTGRES_ENABLED_EXTENSIONS" | \
        tr -d '\n\r' | \
        sed 's/[[:space:]]*,[[:space:]]*/,/g' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        tr -d '\0')
    
    # Add universal extensions that provide general benefits
    universal_extensions="hypopg,pg_qualstats,postgres_fdw,file_fdw"
    if [[ -n "$cleaned_extensions" ]]; then
        final_extensions="$cleaned_extensions,$universal_extensions"
    else
        final_extensions="$universal_extensions"
    fi
    
    echo -n "$final_extensions" > /tmp/postgres_extensions.txt
else
    echo -n "hypopg,pg_qualstats,postgres_fdw,file_fdw" > /tmp/postgres_extensions.txt
fi

# Set environment variables for configuration generation - but don't generate the config yet
export POSTGRES_CONFIG_DIR="/var/lib/postgresql/data"
export POSTGRES_EXTENSIONS="$POSTGRES_ENABLED_EXTENSIONS"

# Start PostgreSQL with pre-generated configuration
echo "🔧 Starting PostgreSQL with build-time configuration..."

# Set environment variable for the original entrypoint to use our config
if [[ -f "/etc/postgresql/generated/postgresql.conf" ]]; then
    export POSTGRES_INITDB_ARGS="--data-checksums"
    echo "📋 Pre-generated configuration will be applied during initialization"
fi

# Start PostgreSQL in background to handle post-startup extension activation
echo "🚀 Starting PostgreSQL with automatic extension activation..."
/usr/local/bin/docker-entrypoint.sh "$@" &
POSTGRES_PID=$!

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
while ! pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" > /dev/null 2>&1; do
    sleep 1
done

# Execute post-startup extension activation if the script exists
if [[ -f "/usr/local/bin/activate-extensions.sql" ]]; then
    echo "🔧 Activating shared_preload_libraries extensions..."
    sleep 2  # Give PostgreSQL a moment to fully start
    if psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -f "/usr/local/bin/activate-extensions.sql" > /dev/null 2>&1; then
        echo "✅ Extensions activated successfully"
    else
        echo "⚠️  Extension activation had some issues (may be normal if already activated)"
    fi
else
    echo "ℹ️  No shared_preload_libraries extensions to activate"
fi

# Wait for the main PostgreSQL process
wait $POSTGRES_PID
