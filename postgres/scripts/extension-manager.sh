#!/bin/bash
# Centralized PostgreSQL Extension Manager
# Handles detection, installation, configuration and activation of extensions
# Used by both build-time (Dockerfile) and runtime (entrypoint)

set -e

# =============================================================================
# CONSTANTS AND CONFIGURATION
# =============================================================================

# Extension versions (centralized)
declare -A EXTENSION_VERSIONS=(
    ["pgvector"]="v0.8.0"
    ["pg_net"]="v0.19.3" 
    ["pg_partman"]="v5.2.4"
    ["paradedb"]="v0.17.2"
)

# Extensions requiring shared_preload_libraries
SHARED_PRELOAD_EXTENSIONS=(
    "citus"
    "pg_cron"
    "pg_stat_statements" 
    "pg_net"
    "pg_search"
    "pg_qualstats"
    "auto_explain"
)

# Universal extensions (always beneficial)
UNIVERSAL_EXTENSIONS=(
    "hypopg"
    "pg_qualstats"
    "postgres_fdw"
    "file_fdw"
)

# Extension installation methods
declare -A EXTENSION_INSTALL_METHODS=(
    # APT packages
    ["citus"]="apt:postgresql-15-citus-13.1|curl https://install.citusdata.com/community/deb.sh | bash"
    ["postgis"]="apt:postgresql-15-postgis-3 postgresql-15-postgis-3-scripts"
    ["pg_cron"]="apt:postgresql-15-cron"
    ["postgresql-contrib"]="apt:postgresql-contrib"
    ["hypopg"]="apt:postgresql-15-hypopg"
    ["pg_qualstats"]="apt:postgresql-15-pg-qualstats"
    
    # Source builds
    ["pg_vector"]="source:https://github.com/pgvector/pgvector.git"
    ["pg_net"]="source:https://github.com/supabase/pg_net.git"
    ["pgjwt"]="source:https://github.com/michelp/pgjwt.git"
    ["pg_partman"]="source:https://github.com/pgpartman/pg_partman.git"
    
    # Precompiled packages
    ["pg_search"]="deb:paradedb"
)

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_info() {
    echo "🔧 [ext-mgr] $1" >&2
}

log_warning() {
    echo "⚠️  [ext-mgr] $1" >&2
}

log_error() {
    echo "❌ [ext-mgr] $1" >&2
}

log_success() {
    echo "✅ [ext-mgr] $1" >&2
}

# =============================================================================
# EXTENSION DETECTION AND MANAGEMENT
# =============================================================================

# Detect enabled extensions from environment or profiles
detect_extensions() {
    local extensions=""
    
    # Priority 1: Use POSTGRES_EXTENSIONS if specified
    if [[ -n "${POSTGRES_EXTENSIONS:-}" ]]; then
        extensions="$POSTGRES_EXTENSIONS"
        log_info "Using extensions from POSTGRES_EXTENSIONS: $extensions"
    # Priority 2: Load from profile if specified  
    elif [[ -n "${POSTGRES_EXTENSION_PROFILE:-}" ]]; then
        extensions=$(load_extensions_from_profile "$POSTGRES_EXTENSION_PROFILE")
        log_info "Using extensions from profile '$POSTGRES_EXTENSION_PROFILE': $extensions"
    else
        log_warning "No extensions or profile specified, using universal extensions only"
        extensions=""
    fi
    
    # Always add universal extensions
    local universal_list=$(printf "%s," "${UNIVERSAL_EXTENSIONS[@]}" | sed 's/,$//')
    if [[ -n "$extensions" ]]; then
        extensions="$extensions,$universal_list"
    else
        extensions="$universal_list"
    fi
    
    # Remove duplicates and clean
    extensions=$(echo "$extensions" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    
    log_info "Final extensions list: $extensions"
    echo "$extensions"
}

# Load extensions from profile(s) - supports composition with +
load_extensions_from_profile() {
    local profiles=$1
    local all_extensions=""
    
    # Split profiles by + for composition support
    IFS='+' read -ra PROFILE_ARRAY <<< "$profiles"
    
    for profile in "${PROFILE_ARRAY[@]}"; do
        profile=$(echo "$profile" | xargs)  # trim whitespace
        local profile_file="/etc/postgresql/extensions/profiles/${profile}.conf"
        
        if [[ -f "$profile_file" ]]; then
            log_info "Loading extensions from profile: $profile"
            local profile_extensions=$(grep -v '^#' "$profile_file" | grep -v '^$' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
            
            if [[ -n "$all_extensions" && -n "$profile_extensions" ]]; then
                all_extensions="${all_extensions},${profile_extensions}"
            elif [[ -n "$profile_extensions" ]]; then
                all_extensions="$profile_extensions"
            fi
        else
            log_warning "Profile file not found: $profile_file"
        fi
    done
    
    echo "$all_extensions"
}

# Determine which extensions require shared_preload_libraries
build_shared_preload_libraries() {
    local extensions=$1
    local preload_libs=""
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)  # trim whitespace
        for preload_ext in "${SHARED_PRELOAD_EXTENSIONS[@]}"; do
            if [[ "$ext" == "$preload_ext" ]] || [[ "$ext" == "vector" && "$preload_ext" == "pg_vector" ]]; then
                if [[ -z "$preload_libs" ]]; then
                    preload_libs="$preload_ext"
                else
                    preload_libs="$preload_libs,$preload_ext"
                fi
                break
            fi
        done
    done
    
    echo "$preload_libs"
}

# =============================================================================
# EXTENSION INSTALLATION (BUILD-TIME)
# =============================================================================

# Install extensions during Docker build
install_extensions() {
    local extensions="$1"
    local mode="${2:-build}"  # build or runtime
    
    if [[ -z "$extensions" ]]; then
        log_info "No extensions to install"
        return 0
    fi
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    log_info "Installing extensions: $extensions"
    
    # Group extensions by installation method for efficiency
    local apt_packages=()
    local source_builds=()
    local deb_packages=()
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        [[ -z "$ext" ]] && continue
        
        # Determine installation method
        if [[ -n "${EXTENSION_INSTALL_METHODS[$ext]:-}" ]]; then
            local method="${EXTENSION_INSTALL_METHODS[$ext]}"
            local type="${method%%:*}"
            
            case "$type" in
                "apt")
                    apt_packages+=("$ext")
                    ;;
                "source")
                    source_builds+=("$ext")
                    ;;
                "deb")
                    deb_packages+=("$ext")
                    ;;
            esac
        else
            # Check if it's covered by postgresql-contrib
            if [[ "$ext" =~ ^(pgcrypto|uuid-ossp|pg_trgm|btree_gin|btree_gist|pg_stat_statements)$ ]]; then
                apt_packages+=("postgresql-contrib")
            else
                log_warning "Unknown installation method for extension: $ext"
            fi
        fi
    done
    
    # Install APT packages (efficient single update)
    if [[ ${#apt_packages[@]} -gt 0 ]]; then
        install_apt_extensions "${apt_packages[@]}"
    fi
    
    # Install from source (only during build)
    if [[ ${#source_builds[@]} -gt 0 && "$mode" == "build" ]]; then
        install_source_extensions "${source_builds[@]}"
    fi
    
    # Install DEB packages
    if [[ ${#deb_packages[@]} -gt 0 ]]; then
        install_deb_extensions "${deb_packages[@]}"
    fi
    
    log_success "Extension installation completed"
}

# Install APT-based extensions
install_apt_extensions() {
    local extensions=("$@")
    log_info "Installing APT extensions: ${extensions[*]}"
    
    local packages_to_install=()
    local special_setup_needed=()
    
    for ext in "${extensions[@]}"; do
        case "$ext" in
            "citus")
                special_setup_needed+=("citus")
                packages_to_install+=("postgresql-15-citus-13.1")
                ;;
            "postgresql-contrib")
                packages_to_install+=("postgresql-contrib")
                ;;
            *)
                if [[ -n "${EXTENSION_INSTALL_METHODS[$ext]:-}" ]]; then
                    local method="${EXTENSION_INSTALL_METHODS[$ext]}"
                    local packages="${method#apt:}"
                    packages_to_install+=($packages)
                fi
                ;;
        esac
    done
    
    # Handle special setups first
    for special in "${special_setup_needed[@]}"; do
        case "$special" in
            "citus")
                log_info "Setting up Citus repository..."
                curl -s https://install.citusdata.com/community/deb.sh | bash
                ;;
        esac
    done
    
    # Install all packages in one go
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        apt-get update
        apt-get install -y "${packages_to_install[@]}"
        rm -rf /var/lib/apt/lists/*
    fi
}

# Install source-based extensions
install_source_extensions() {
    local extensions=("$@")
    log_info "Building source extensions: ${extensions[*]}"
    
    for ext in "${extensions[@]}"; do
        case "$ext" in
            "pg_vector")
                build_pg_vector
                ;;
            "pg_net")
                build_pg_net
                ;;
            "pgjwt")
                build_pgjwt
                ;;
            "pg_partman")
                build_pg_partman
                ;;
        esac
    done
}

# Install DEB package extensions
install_deb_extensions() {
    local extensions=("$@")
    log_info "Installing DEB extensions: ${extensions[*]}"
    
    for ext in "${extensions[@]}"; do
        case "$ext" in
            "pg_search")
                install_paradedb
                ;;
        esac
    done
}

# =============================================================================
# SOURCE BUILD FUNCTIONS (optimized for debug + cache)
# =============================================================================

build_pg_vector() {
    local version="${EXTENSION_VERSIONS[pgvector]}"
    log_info "Building pg_vector $version..."
    
    git clone --branch "$version" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector
    cd /tmp/pgvector
    make clean && make OPTFLAGS="" && make install
    cd /
    rm -rf /tmp/pgvector
    
    log_success "pg_vector built and installed"
}

build_pg_net() {
    local version="${EXTENSION_VERSIONS[pg_net]}"
    log_info "Building pg_net $version..."
    
    git clone --branch "$version" --depth 1 https://github.com/supabase/pg_net.git /tmp/pg_net
    cd /tmp/pg_net
    make && make install
    cd /
    rm -rf /tmp/pg_net
    
    log_success "pg_net built and installed"
}

build_pgjwt() {
    log_info "Building pgjwt..."
    
    git clone --depth 1 https://github.com/michelp/pgjwt.git /tmp/pgjwt
    cd /tmp/pgjwt
    make install
    cd /
    rm -rf /tmp/pgjwt
    
    log_success "pgjwt built and installed"
}

build_pg_partman() {
    local version="${EXTENSION_VERSIONS[pg_partman]}"
    log_info "Building pg_partman $version..."
    
    git clone --branch "$version" --depth 1 https://github.com/pgpartman/pg_partman.git /tmp/pg_partman
    cd /tmp/pg_partman
    make NO_BGW=1 install
    cd /
    rm -rf /tmp/pg_partman
    
    log_success "pg_partman built and installed"
}

install_paradedb() {
    local version="${EXTENSION_VERSIONS[paradedb]}"
    log_info "Installing ParadeDB pg_search $version..."
    
    apt-get update
    cd /tmp
    wget -q --no-check-certificate -O pg_search.deb \
        "https://github.com/paradedb/paradedb/releases/download/${version}/postgresql-15-pg-search_${version#v}-1PARADEDB-bookworm_amd64.deb"
    apt-get install -y ./pg_search.deb
    rm -f pg_search.deb
    rm -rf /var/lib/apt/lists/*
    
    log_success "ParadeDB pg_search installed"
}

# =============================================================================
# EXTENSION ACTIVATION (RUNTIME)
# =============================================================================

# Generate SQL script for activating shared_preload_libraries extensions
generate_activation_script() {
    local extensions="$1"
    local output_file="$2"
    
    if [[ -z "$extensions" ]]; then
        log_info "No extensions requiring activation"
        return 0
    fi
    
    local preload_libs=$(build_shared_preload_libraries "$extensions")
    
    if [[ -z "$preload_libs" ]]; then
        log_info "No shared_preload_libraries extensions found"
        return 0
    fi
    
    log_info "Generating activation script for: $preload_libs"
    
    cat > "$output_file" << EOF
-- PostgreSQL Extension Activation Script
-- Generated by extension-manager.sh
-- Extensions requiring shared_preload_libraries: $preload_libs

EOF

    IFS=',' read -ra PRELOAD_ARRAY <<< "$preload_libs"
    
    for ext in "${PRELOAD_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        [[ -z "$ext" ]] && continue
        
        case "$ext" in
            "citus")
                cat >> "$output_file" << EOF
-- Activate Citus extension
DO \$\$
BEGIN
    CREATE EXTENSION IF NOT EXISTS citus;
    RAISE NOTICE '✅ Citus extension activated';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '❌ Failed to activate citus: %', SQLERRM;
END \$\$;

EOF
                ;;
            "pg_search")
                cat >> "$output_file" << EOF
-- Activate pg_search extension
DO \$\$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_search;
    RAISE NOTICE '✅ pg_search extension activated';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '❌ Failed to activate pg_search: %', SQLERRM;
END \$\$;

EOF
                ;;
            "pg_net")
                cat >> "$output_file" << EOF
-- Activate pg_net extension
DO \$\$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net;
    RAISE NOTICE '✅ pg_net extension activated';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '❌ Failed to activate pg_net: %', SQLERRM;
END \$\$;

EOF
                ;;
            "pg_cron")
                cat >> "$output_file" << EOF
-- Activate pg_cron extension (in postgres database)
DO \$\$
BEGIN
    CREATE EXTENSION IF NOT EXISTS dblink;
    PERFORM dblink_exec('dbname=postgres', 'CREATE EXTENSION IF NOT EXISTS pg_cron');
    RAISE NOTICE '✅ pg_cron extension activated in postgres database';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING '❌ Failed to activate pg_cron: %', SQLERRM;
END \$\$;

EOF
                ;;
        esac
    done
    
    echo "SELECT 'All shared_preload_libraries extensions processed!' as final_status;" >> "$output_file"
    
    log_success "Activation script generated: $output_file"
}

# Activate extensions at runtime
activate_extensions() {
    local extensions="$1"
    local database="${2:-${POSTGRES_DB:-postgres}}"
    local user="${3:-${POSTGRES_USER:-postgres}}"
    
    # Generate and execute activation script
    local activation_script="/tmp/activate-extensions.sql"
    generate_activation_script "$extensions" "$activation_script"
    
    if [[ -f "$activation_script" ]]; then
        log_info "Activating shared_preload_libraries extensions..."
        if psql -U "$user" -d "$database" -f "$activation_script" > /dev/null 2>&1; then
            log_success "Extensions activated successfully"
            return 0
        else
            log_warning "Extension activation had issues (may be normal if already activated)"
            return 1
        fi
    fi
}

# =============================================================================
# MAIN INTERFACE FUNCTIONS
# =============================================================================

# Main function for build-time operations
main_build() {
    local extensions=$(detect_extensions)
    local preload_libs=$(build_shared_preload_libraries "$extensions")
    
    # Export for use by other scripts
    export DETECTED_EXTENSIONS="$extensions"
    export SHARED_PRELOAD_LIBS="$preload_libs"
    
    # Generate basic configuration
    if [[ -n "${POSTGRES_CONFIG_DIR:-}" ]]; then
        # Use build-config.sh for main configuration if available
        if [[ -f "/usr/local/bin/build-config.sh" ]]; then
            log_info "Using build-config.sh for configuration generation"
            /usr/local/bin/build-config.sh build
        fi
        
        # Add shared_preload_libraries to config
        if [[ -n "$preload_libs" ]]; then
            echo "shared_preload_libraries = '$preload_libs'" >> "$POSTGRES_CONFIG_DIR/postgresql.conf"
            log_success "shared_preload_libraries set to: $preload_libs"
        fi
    fi
    
    # Generate activation script for runtime
    generate_activation_script "$extensions" "/usr/local/bin/activate-extensions.sql"
    
    log_success "Build-time extension management completed"
}

# Main function for runtime operations  
main_runtime() {
    local extensions=$(detect_extensions)
    
    # Export for other scripts
    export DETECTED_EXTENSIONS="$extensions"
    export SHARED_PRELOAD_LIBS=$(build_shared_preload_libraries "$extensions")
    
    # Write extensions list for SQL scripts
    echo -n "$extensions" > /tmp/postgres_extensions.txt
    
    log_info "Runtime extension management completed"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Allow sourcing this script or running directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "build")
            main_build
            ;;
        "runtime")
            main_runtime
            ;;
        "detect")
            detect_extensions
            ;;
        "install")
            shift
            install_extensions "$*" "build"
            ;;
        "activate")
            shift
            activate_extensions "$*"
            ;;
        *)
            echo "Usage: $0 [build|runtime|detect|install|activate]"
            echo "  build    - Full build-time setup"
            echo "  runtime  - Runtime initialization"  
            echo "  detect   - Detect enabled extensions"
            echo "  install  - Install specified extensions"
            echo "  activate - Activate specified extensions"
            exit 1
            ;;
    esac
fi