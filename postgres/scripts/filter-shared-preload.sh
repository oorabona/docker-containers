#!/bin/bash
# Filter shared_preload_libraries to only include installed extensions
# This runs at build time to ensure PostgreSQL can start successfully

set -e

PRELOAD_LIBS="${1:-}"
PG_MAJOR="${2:-}"

if [[ -z "$PRELOAD_LIBS" ]]; then
    echo "No shared_preload_libraries to filter"
    exit 0
fi

echo "Filtering shared_preload_libraries: $PRELOAD_LIBS"

# Split the libraries and check each one
IFS=',' read -ra LIBS <<< "$PRELOAD_LIBS"
FILTERED_LIBS=""

for lib in "${LIBS[@]}"; do
    lib=$(echo "$lib" | xargs)  # trim whitespace
    
    # Check if the .so file exists
    if [[ -f "/usr/lib/postgresql/${PG_MAJOR}/lib/${lib}.so" ]]; then
        echo "✅ Found: ${lib}.so"
        if [[ -z "$FILTERED_LIBS" ]]; then
            FILTERED_LIBS="$lib"
        else
            FILTERED_LIBS="${FILTERED_LIBS},${lib}"
        fi
    else
        echo "⚠️  Not found: ${lib}.so (skipping)"
    fi
done

# Create the conf.d directory if it doesn't exist
mkdir -p /etc/postgresql/conf.d

# Write the filtered configuration
if [[ -n "$FILTERED_LIBS" ]]; then
    echo "Writing filtered shared_preload_libraries to conf.d..."
    cat > /etc/postgresql/conf.d/00-extensions.conf << EOF
# Filtered shared_preload_libraries (build time)
# Original: $PRELOAD_LIBS
# Filtered: $FILTERED_LIBS
shared_preload_libraries = '$FILTERED_LIBS'
EOF
    echo "✅ Configuration written with: $FILTERED_LIBS"
else
    echo "⚠️  No valid libraries found, skipping shared_preload_libraries configuration"
fi