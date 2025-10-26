#!/bin/bash
# PostgreSQL Configuration Setup
# Applies the pre-generated configuration from build time

set -e

echo "🔧 Setting up PostgreSQL configuration..."

# PostgreSQL configuration file location
PGCONF="${PGDATA}/postgresql.conf"

# Wait for PostgreSQL to create the config file
for i in {1..30}; do
    if [[ -f "$PGCONF" ]]; then
        break
    fi
    echo "⏳ Waiting for postgresql.conf to be created..."
    sleep 1
done

if [[ ! -f "$PGCONF" ]]; then
    echo "❌ Error: postgresql.conf not found at $PGCONF after 30 seconds"
    exit 1
fi

# Apply the pre-generated configuration from build time
if [[ -f "/etc/postgresql/generated/postgresql.conf" ]]; then
    echo "📝 Applying pre-generated PostgreSQL configuration..."
    # Backup original config
    cp "$PGCONF" "${PGCONF}.original"
    # Apply our generated config
    cp "/etc/postgresql/generated/postgresql.conf" "$PGCONF"
    echo "✅ Pre-generated configuration applied successfully"
    
    # Show what's configured
    echo "📋 Configuration summary:"
    grep -E "^shared_preload_libraries|^max_connections|^shared_buffers" "$PGCONF" | head -5
    
    # Show extensions info
    if [[ -f "/etc/postgresql/postgres_extensions.txt" ]]; then
        echo "📦 Extensions list: $(cat /etc/postgresql/postgres_extensions.txt)"
    fi
    if [[ -f "/etc/postgresql/shared_preload_libraries.txt" ]]; then
        echo "🔧 Shared preload libraries: $(cat /etc/postgresql/shared_preload_libraries.txt)"
    fi
else
    echo "⚠️  No pre-generated configuration found, using fallback with shared_preload_libraries"
    
    # Fallback: Create basic configuration with shared_preload_libraries if available
    if [[ -f "/etc/postgresql/shared_preload_libraries.txt" ]]; then
        SHARED_PRELOAD_LIBS=$(cat /etc/postgresql/shared_preload_libraries.txt)
        if [[ -n "$SHARED_PRELOAD_LIBS" ]]; then
            echo "🔧 Adding shared_preload_libraries to configuration: $SHARED_PRELOAD_LIBS"
            echo "" >> "$PGCONF"
            echo "# Extensions configuration (fallback)" >> "$PGCONF"
            echo "shared_preload_libraries = '$SHARED_PRELOAD_LIBS'" >> "$PGCONF"
        fi
    fi
    
    # Add include_dir for additional configuration
    if ! grep -q "include_dir = '/etc/postgresql/conf.d'" "$PGCONF" 2>/dev/null; then
        echo "" >> "$PGCONF"
        echo "# Include additional configuration files" >> "$PGCONF"
        echo "include_dir = '/etc/postgresql/conf.d'" >> "$PGCONF"
    fi
fi

# Show what extensions will be loaded (if conf.d exists)
if [ -f "/etc/postgresql/conf.d/00-extensions.conf" ]; then
    echo "✅ Additional extensions configuration:"
    cat /etc/postgresql/conf.d/00-extensions.conf
fi

echo "🎯 PostgreSQL configuration setup completed!"