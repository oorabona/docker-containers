#!/bin/bash
# Copy pre-generated configuration immediately after initdb
set -e

echo "🔧 [00-copy-config] Checking for pre-generated configuration..."

if [[ -n "$POSTGRES_CUSTOM_CONFIG" && -f "$POSTGRES_CUSTOM_CONFIG" ]]; then
    echo "📋 [00-copy-config] Copying pre-generated configuration to data directory..."
    cp "$POSTGRES_CUSTOM_CONFIG" "$PGDATA/postgresql.conf"
    echo "✅ [00-copy-config] Configuration copied successfully from $POSTGRES_CUSTOM_CONFIG"
    
    # Signal that PostgreSQL needs to reload config
    echo "🔄 [00-copy-config] Configuration will be active when PostgreSQL starts"
else
    echo "ℹ️  [00-copy-config] No custom configuration specified, using defaults"
fi