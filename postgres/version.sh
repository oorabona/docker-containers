#!/bin/bash
# PostgreSQL Version and Extension Management Script
# Single source of truth for all versioning and build-time configuration.

set -euo pipefail

# --- Helper Functions for Version Detection ---

# Fetches the latest GitHub release tag for a given repository.
get_github_latest() {
    local repo="$1"
    local fallback_version="$2"
    local version
    version=$(curl -s "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' || echo "")
    if [[ -n "$version" ]]; then
        echo "$version"
    else
        echo "$fallback_version"
    fi
}

# Fetches the latest pgjwt version from GitHub tags
get_pgjwt_version() {
    local version
    version=$(curl -s "https://api.github.com/repos/michelp/pgjwt/tags" 2>/dev/null | grep '"name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//' || echo "")
    if [[ -n "$version" ]]; then
        echo "$version"
    else
        echo "0.2.0"  # fallback
    fi
}

# Simple logger function
log_info() {
    echo "INFO: $1" >&2
}

# Build shared_preload_libraries based on extensions
build_shared_preload_libraries() {
    local extensions="$1"
    local preload_libs=""
    
    # Extensions that require shared_preload_libraries
    declare -A preload_required=(
        ["citus"]="citus"
        ["pg_cron"]="pg_cron"
        ["pg_net"]="pg_net"
        ["pg_stat_statements"]="pg_stat_statements"
        ["pg_search"]="pg_search"
        ["pg_qualstats"]="pg_qualstats"
    )
    
    # Citus must always be first if present
    if echo "$extensions" | grep -q "citus"; then
        preload_libs="citus"
    fi
    
    # Add other extensions
    for ext in "${!preload_required[@]}"; do
        if [[ "$ext" != "citus" ]] && echo "$extensions" | grep -q "$ext"; then
            if [[ -n "$preload_libs" ]]; then
                preload_libs="${preload_libs},${preload_required[$ext]}"
            else
                preload_libs="${preload_required[$ext]}"
            fi
        fi
    done
    
    echo "$preload_libs"
}

# --- Main Logic ---

# For make script: registry pattern for published versions
if [[ "${1:-}" = "--registry-pattern" ]]; then
    # Support both standard and profile-tagged versions
    echo "^[0-9]+\.[0-9]+(-[a-z0-9-]+)?$"
    exit 0
fi

# Mode 1: Return PostgreSQL version (for standard version check)
if [[ $# -eq 0 ]] || [[ "${1:-}" != "--build-args" ]]; then
    PG_VERSION=$("$(dirname "$0")/../helpers/latest-docker-tag" library/postgres "^[0-9]+\.[0-9]+$")
    
    # If a profile is specified, append it to the version tag
    if [[ -n "${POSTGRES_PROFILE:-}" ]]; then
        echo "${PG_VERSION}-${POSTGRES_PROFILE}"
    else
        echo "$PG_VERSION"
    fi
    exit 0
fi

# Mode 2: Generate and export all build arguments for docker-compose
# This mode is called by the build script.

log_info "🔧 Generating build arguments for PostgreSQL..."

# --- Version Detection ---
PG_VERSION=$("$(dirname "$0")/../helpers/latest-docker-tag" library/postgres "^[0-9]+\.[0-9]+$")
PG_MAJOR_VERSION=$(echo "$PG_VERSION" | cut -d. -f1)
PGVECTOR_VERSION=$(get_github_latest "pgvector/pgvector" "0.8.0")
PGNET_VERSION=$(get_github_latest "supabase/pg_net" "0.13.0")
PGPARTMAN_VERSION=$(get_github_latest "pgpartman/pg_partman" "5.2.2")
PARADEDB_VERSION=$(get_github_latest "paradedb/paradedb" "0.12.1")
PGJWT_VERSION=$(get_pgjwt_version)

# --- Extension Profile Logic ---
# Use extensions from environment if set (by build script)
POSTGRES_EXTENSIONS=${POSTGRES_EXTENSIONS:-"pg_stat_statements,hypopg,pg_qualstats"}

# Generate shared_preload_libraries
SHARED_PRELOAD_LIBS=$(build_shared_preload_libraries "$POSTGRES_EXTENSIONS")

log_info "  PostgreSQL Version: $PG_VERSION (Major: $PG_MAJOR_VERSION)"
log_info "  Extensions to build: $POSTGRES_EXTENSIONS"
log_info "  Shared preload libraries: $SHARED_PRELOAD_LIBS"

# --- Create final version tag ---
# If a profile is specified, append it to the version tag
if [[ -n "${POSTGRES_PROFILE:-}" ]]; then
    FINAL_VERSION="${PG_VERSION}-${POSTGRES_PROFILE}"
else
    FINAL_VERSION="$PG_VERSION"
fi

# --- Output Build Arguments ---
# This output will be evaluated by the calling build script.
# Format: export KEY="VALUE"
cat <<EOF
export VERSION="$FINAL_VERSION"
export PG_BASE_VERSION="$PG_VERSION"
export MAJOR_VERSION="$PG_MAJOR_VERSION"
export PGVECTOR_VERSION="$PGVECTOR_VERSION"
export PGNET_VERSION="$PGNET_VERSION"
export PGPARTMAN_VERSION="$PGPARTMAN_VERSION"
export PARADEDB_VERSION="$PARADEDB_VERSION"
export PGJWT_VERSION="$PGJWT_VERSION"
export POSTGRES_EXTENSIONS="$POSTGRES_EXTENSIONS"
export SHARED_PRELOAD_LIBRARIES="$SHARED_PRELOAD_LIBS"
EOF
