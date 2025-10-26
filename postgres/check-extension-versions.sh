#!/bin/bash
# Extension Version Checker and Updater
# This script checks for the latest versions of PostgreSQL extensions

set -e

echo "🔍 Checking extension versions for PostgreSQL 15..."

# Function to get latest GitHub release
get_latest_release() {
    local repo=$1
    curl -s "https://api.github.com/repos/$repo/releases/latest" | \
        grep '"tag_name":' | \
        sed -E 's/.*"([^"]+)".*/\1/' | \
        head -1
}

# Function to check if version exists for PostgreSQL 15
check_pg15_compatibility() {
    local repo=$1
    local version=$2
    echo "Checking $repo compatibility with PostgreSQL 15..."
}

echo "📦 Current versions in Dockerfile:"
echo "  - pg_vector: v0.8.0"
echo "  - pg_net: v0.19.3" 
echo "  - pg_partman: v5.2.4"
echo "  - pg_search: v0.17.2"

echo ""
echo "🔄 Checking for latest versions..."

# Check pg_vector
echo "🔍 pg_vector latest:"
PGVECTOR_LATEST=$(get_latest_release "pgvector/pgvector" 2>/dev/null)
if [ -z "$PGVECTOR_LATEST" ]; then
    PGVECTOR_LATEST="v0.8.0 (fallback)"
fi
echo "  Latest: $PGVECTOR_LATEST"

# Check pg_net  
echo "🔍 pg_net latest:"
PGNET_LATEST=$(get_latest_release "supabase/pg_net" 2>/dev/null)
if [ -z "$PGNET_LATEST" ]; then
    PGNET_LATEST="v0.19.3 (fallback)"
fi
echo "  Latest: $PGNET_LATEST"

# Check pg_partman
echo "🔍 pg_partman latest:" 
PGPARTMAN_LATEST=$(get_latest_release "pgpartman/pg_partman" 2>/dev/null)
if [ -z "$PGPARTMAN_LATEST" ]; then
    PGPARTMAN_LATEST="v5.2.4 (fallback)"
fi
echo "  Latest: $PGPARTMAN_LATEST"

# Check ParadeDB
echo "🔍 ParadeDB latest:"
PARADEDB_LATEST=$(get_latest_release "paradedb/paradedb" 2>/dev/null)
if [ -z "$PARADEDB_LATEST" ]; then
    PARADEDB_LATEST="v0.17.2 (fallback)"
fi
echo "  Latest: $PARADEDB_LATEST"

echo ""
echo "📋 Extension compatibility matrix for PostgreSQL 15:"
echo "  ✅ Citus: 13.1 (PostgreSQL 15 compatible)"
echo "  ✅ PostGIS: 3.x (PostgreSQL 15 compatible)"  
echo "  ✅ pg_cron: 1.6+ (PostgreSQL 15 compatible)"
echo "  ✅ pg_stat_statements: Built-in (PostgreSQL 15 native)"
echo "  ✅ Contrib extensions: Built-in (PostgreSQL 15 native)"

echo ""
echo "⚠️  Recommended updates needed:"
echo "  1. Review extension versions above"
echo "  2. Test compatibility with PostgreSQL 15"
echo "  3. Update Dockerfile with latest compatible versions"
echo "  4. Test build and functionality"

echo ""
echo "🔧 To update versions, edit the Dockerfile and change:"
echo "  - Line ~28: pg_vector version"
echo "  - Line ~40: pg_net version"  
echo "  - Line ~62: pg_partman version"
echo "  - Line ~137: ParadeDB version (ensure PostgreSQL 15 support)"
