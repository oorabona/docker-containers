#!/bin/bash
# PostgreSQL Dynamic Version Management
# Detects PostgreSQL and extension versions automatically
# No hardcoding - either explicit version or auto-detection

set -euo pipefail

# Source project helpers for consistency (with fallback)
if [[ -f "$(dirname "$0")/../../helpers/logging.sh" ]]; then
    source "$(dirname "$0")/../../helpers/logging.sh"
else
    # Fallback logging functions for Docker build context
    log_info() { echo "ℹ️  [postgres-ver] $1" >&2; }
    log_warning() { echo "⚠️  [postgres-ver] $1" >&2; }
    log_error() { echo "❌ [postgres-ver] $1" >&2; }
    log_success() { echo "✅ [postgres-ver] $1" >&2; }
fi

# =============================================================================
# POSTGRESQL VERSION DETECTION
# =============================================================================

get_postgres_version() {
    local version=""
    
    # Priority 1: Explicit VERSION environment variable
    if [[ -n "${VERSION:-}" ]]; then
        version="$VERSION"
        log_info "Using explicit PostgreSQL version: $version"
    # Priority 2: Auto-detect from upstream using project helper
    else
        log_info "Auto-detecting latest PostgreSQL version..."
        version=$("$(dirname "$0")/../../helpers/latest-docker-tag" library/postgres "^[0-9]+\.[0-9]+$")
        
        if [[ -z "$version" || "$version" == "unknown" ]]; then
            log_error "Failed to auto-detect PostgreSQL version"
            exit 1
        fi
        
        log_success "Auto-detected PostgreSQL version: $version"
    fi
    
    # Validate version format
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid PostgreSQL version format: $version (expected: X.Y)"
        exit 1
    fi
    
    echo "$version"
}

get_major_version() {
    local full_version="${1:-$(get_postgres_version)}"
    echo "$full_version" | cut -d'.' -f1
}

# =============================================================================
# EXTENSION VERSION DETECTION
# =============================================================================

get_extension_version() {
    local extension="$1"
    local explicit_var="${extension^^}_VERSION"  # Convert to uppercase
    explicit_var="${explicit_var//[^A-Z0-9_]/_}"  # Replace invalid chars with _
    
    # Check for explicit version first (e.g., PGVECTOR_VERSION, PG_NET_VERSION)
    local explicit_version="${!explicit_var:-}"
    if [[ -n "$explicit_version" ]]; then
        log_info "Using explicit version for $extension: $explicit_version"
        echo "$explicit_version"
        return 0
    fi
    
    # Auto-detect from GitHub releases or fallback to latest
    local version=""
    case "$extension" in
        "pg_vector"|"pgvector")
            version=$(get_github_latest_version "pgvector/pgvector")
            ;;
        "pg_net")
            version=$(get_github_latest_version "supabase/pg_net")
            ;;
        "pg_partman")
            version=$(get_github_latest_version "pgpartman/pg_partman")
            ;;
        "paradedb"|"pg_search")
            version=$(get_github_latest_version "paradedb/paradedb")
            ;;
        "pgjwt")
            # pgjwt doesn't use releases, use latest commit
            version="latest"
            log_info "Extension $extension uses latest commit (no releases)"
            ;;
        *)
            # Default to latest for unknown extensions
            version="latest"
            log_warning "Unknown extension $extension, using 'latest'"
            ;;
    esac
    
    if [[ -z "$version" || "$version" == "null" ]]; then
        log_warning "Failed to detect version for $extension, using 'latest'"
        version="latest"
    else
        log_success "Auto-detected $extension version: $version"
    fi
    
    echo "$version"
}

get_github_latest_version() {
    local repo="$1"
    local api_url="https://api.github.com/repos/$repo/releases/latest"
    
    log_info "Fetching latest version for $repo..."
    
    # Use curl with timeout and error handling
    local response
    if response=$(curl -s --fail --max-time 30 "$api_url" 2>/dev/null); then
        local version=$(echo "$response" | jq -r '.tag_name' 2>/dev/null)
        
        # Remove 'v' prefix if present
        version="${version#v}"
        
        # Validate we got a real version
        if [[ -n "$version" && "$version" != "null" && "$version" != "" ]]; then
            echo "$version"
            return 0
        fi
    fi
    
    # If GitHub API fails, return empty (caller will handle fallback)
    log_warning "Failed to fetch version from GitHub API for $repo"
    echo ""
    return 1
}

# =============================================================================
# VERSION VALIDATION AND EXPORT
# =============================================================================

validate_versions() {
    local postgres_version="$1"
    local major_version="$2"
    shift 2
    local extensions=("$@")
    
    log_info "Validating versions..."
    log_info "PostgreSQL: $postgres_version (major: $major_version)"
    
    # Validate PostgreSQL version
    if [[ ! "$postgres_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid PostgreSQL version: $postgres_version"
        return 1
    fi
    
    # Check if major version matches
    local calculated_major=$(echo "$postgres_version" | cut -d'.' -f1)
    if [[ "$major_version" != "$calculated_major" ]]; then
        log_error "Major version mismatch: $major_version != $calculated_major"
        return 1
    fi
    
    # Validate extension versions
    for ext in "${extensions[@]}"; do
        [[ -z "$ext" ]] && continue
        local ext_version=$(get_extension_version "$ext")
        log_info "Extension $ext: $ext_version"
    done
    
    log_success "All versions validated successfully"
    return 0
}

export_versions_for_docker() {
    local postgres_version="$1"
    local extensions_list="$2"
    
    local major_version=$(get_major_version "$postgres_version")
    
    # Export PostgreSQL versions
    export VERSION="$postgres_version"
    export MAJOR_VERSION="$major_version"
    
    # Export extension versions
    if [[ -n "$extensions_list" ]]; then
        IFS=',' read -ra EXT_ARRAY <<< "$extensions_list"
        
        for ext in "${EXT_ARRAY[@]}"; do
            ext=$(echo "$ext" | xargs)  # trim whitespace
            [[ -z "$ext" ]] && continue
            
            local ext_version=$(get_extension_version "$ext")
            
            # Convert extension name to environment variable name
            case "$ext" in
                "pg_vector"|"vector")
                    export PGVECTOR_VERSION="$ext_version"
                    ;;
                "pg_net")
                    export PGNET_VERSION="$ext_version"
                    ;;
                "pg_partman")
                    export PGPARTMAN_VERSION="$ext_version"
                    ;;
                "paradedb"|"pg_search")
                    export PARADEDB_VERSION="$ext_version"
                    ;;
                "pgjwt")
                    export PGJWT_VERSION="$ext_version"
                    ;;
            esac
        done
    fi
    
    # Log exported versions
    log_info "Exported versions for Docker build:"
    log_info "  VERSION=$VERSION"
    log_info "  MAJOR_VERSION=$MAJOR_VERSION"
    [[ -n "${PGVECTOR_VERSION:-}" ]] && log_info "  PGVECTOR_VERSION=$PGVECTOR_VERSION"
    [[ -n "${PGNET_VERSION:-}" ]] && log_info "  PGNET_VERSION=$PGNET_VERSION"
    [[ -n "${PGPARTMAN_VERSION:-}" ]] && log_info "  PGPARTMAN_VERSION=$PGPARTMAN_VERSION"
    [[ -n "${PARADEDB_VERSION:-}" ]] && log_info "  PARADEDB_VERSION=$PARADEDB_VERSION"
    [[ -n "${PGJWT_VERSION:-}" ]] && log_info "  PGJWT_VERSION=$PGJWT_VERSION"
}

# =============================================================================
# BUILD ARGS GENERATION FOR MAKE SCRIPT
# =============================================================================

generate_build_args() {
    local postgres_version="$1"
    local extensions_list="$2"
    
    local major_version=$(get_major_version "$postgres_version")
    local build_args=""
    
    # PostgreSQL versions
    build_args="--build-arg VERSION=$postgres_version"
    build_args="$build_args --build-arg MAJOR_VERSION=$major_version"
    
    # Extension versions
    if [[ -n "$extensions_list" ]]; then
        IFS=',' read -ra EXT_ARRAY <<< "$extensions_list"
        
        for ext in "${EXT_ARRAY[@]}"; do
            ext=$(echo "$ext" | xargs)
            [[ -z "$ext" ]] && continue
            
            local ext_version=$(get_extension_version "$ext")
            
            case "$ext" in
                "pg_vector"|"vector")
                    build_args="$build_args --build-arg PGVECTOR_VERSION=$ext_version"
                    ;;
                "pg_net")
                    build_args="$build_args --build-arg PGNET_VERSION=$ext_version"
                    ;;
                "pg_partman")
                    build_args="$build_args --build-arg PGPARTMAN_VERSION=$ext_version"
                    ;;
                "paradedb"|"pg_search")
                    build_args="$build_args --build-arg PARADEDB_VERSION=$ext_version"
                    ;;
                "pgjwt")
                    build_args="$build_args --build-arg PGJWT_VERSION=$ext_version"
                    ;;
            esac
        done
    fi
    
    echo "$build_args"
}

# =============================================================================
# MAIN INTERFACE
# =============================================================================

main() {
    case "${1:-detect}" in
        "postgres")
            get_postgres_version
            ;;
        "major")
            get_major_version
            ;;
        "extension")
            shift
            get_extension_version "$@"
            ;;
        "validate")
            shift
            local postgres_version="$1"
            local major_version="$2"
            shift 2
            validate_versions "$postgres_version" "$major_version" "$@"
            ;;
        "export")
            shift
            local postgres_version="${1:-$(get_postgres_version)}"
            local extensions_list="${2:-${POSTGRES_EXTENSIONS:-}}"
            export_versions_for_docker "$postgres_version" "$extensions_list"
            ;;
        "build-args")
            shift
            local postgres_version="${1:-$(get_postgres_version)}"
            local extensions_list="${2:-${POSTGRES_EXTENSIONS:-}}"
            generate_build_args "$postgres_version" "$extensions_list"
            ;;
        "detect"|"")
            # Default: detect and export everything
            local postgres_version=$(get_postgres_version)
            local extensions_list="${POSTGRES_EXTENSIONS:-}"
            
            echo "PostgreSQL Version: $postgres_version"
            echo "Major Version: $(get_major_version "$postgres_version")"
            
            if [[ -n "$extensions_list" ]]; then
                echo "Extensions: $extensions_list"
                IFS=',' read -ra EXT_ARRAY <<< "$extensions_list"
                for ext in "${EXT_ARRAY[@]}"; do
                    ext=$(echo "$ext" | xargs)
                    [[ -z "$ext" ]] && continue
                    echo "  $ext: $(get_extension_version "$ext")"
                done
            fi
            ;;
        "--help"|"-h"|"help")
            echo "Usage: $0 [command] [args...]"
            echo ""
            echo "Commands:"
            echo "  postgres              - Get PostgreSQL version"
            echo "  major                 - Get major version number"
            echo "  extension <name>      - Get extension version"
            echo "  validate <pg> <maj> <exts...> - Validate versions"
            echo "  export [pg] [exts]    - Export versions as environment variables"
            echo "  build-args [pg] [exts] - Generate Docker build arguments"
            echo "  detect                - Detect and display all versions (default)"
            echo ""
            echo "Environment variables:"
            echo "  VERSION               - Explicit PostgreSQL version"
            echo "  POSTGRES_EXTENSIONS   - Comma-separated extension list"
            echo "  <EXT>_VERSION         - Explicit extension version (e.g., PGVECTOR_VERSION)"
            exit 0
            ;;
        *)
            echo "Error: Unknown command '$1'"
            echo "Use '$0 --help' for usage information"
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
