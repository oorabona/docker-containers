#!/bin/bash
# Unified PostgreSQL Extensions Manager
# Replaces extension-manager.sh + install-extensions.sh
# Build-time focused with minimal runtime

set -euo pipefail

# Source shared logging from project helpers (with fallback)
if [[ -f "$(dirname "$0")/../../helpers/logging.sh" ]]; then
    source "$(dirname "$0")/../../helpers/logging.sh"
else
    # Fallback logging functions for Docker build context
    log_info() { echo "ℹ️  [postgres-ext] $1" >&2; }
    log_warning() { echo "⚠️  [postgres-ext] $1" >&2; }
    log_error() { echo "❌ [postgres-ext] $1" >&2; }
    log_success() { echo "✅ [postgres-ext] $1" >&2; }
fi

# =============================================================================
# CONFIGURATION AND CONSTANTS
# =============================================================================

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

# Universal extensions (always beneficial, APT-based)
UNIVERSAL_EXTENSIONS=(
    "hypopg"
    "pg_qualstats"
    "postgres_fdw"
    "file_fdw"
)

# Extension installation methods  
declare -A EXTENSION_INSTALL_METHODS=(
    # APT packages (MAJOR_VERSION will be substituted at runtime)
    ["citus"]="apt:postgresql-MAJOR_VERSION-citus-13.1"
    ["postgis"]="apt:postgresql-MAJOR_VERSION-postgis-3 postgresql-MAJOR_VERSION-postgis-3-scripts"
    ["pg_cron"]="apt:postgresql-MAJOR_VERSION-cron"
    ["hypopg"]="apt:postgresql-MAJOR_VERSION-hypopg"
    ["pg_qualstats"]="apt:postgresql-MAJOR_VERSION-pg-qualstats"
    ["postgresql-contrib"]="apt:postgresql-contrib"
    
    # Source builds (with dynamic versions)
    ["pg_vector"]="source:pgvector"
    ["vector"]="source:pgvector"
    ["pg_net"]="source:pg_net" 
    ["pgjwt"]="source:pgjwt"
    ["pg_partman"]="source:pg_partman"
    
    # Precompiled packages
    ["pg_search"]="deb:paradedb"
)

# =============================================================================
# EXTENSION DETECTION AND MANAGEMENT
# =============================================================================

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
        log_warning "No extensions specified, using universal extensions only"
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

# NEW: Transform POSTGRES_EXTENSION_PROFILE to POSTGRES_EXTENSIONS outside Docker
# This function is called by the make script to transform profiles to extension lists
transform_profile_to_extensions() {
    local profile="$1"
    
    # Check if profile file exists locally - try multiple paths
    local profile_file=""
    local possible_paths=(
        "$(dirname "$0")/extensions/profiles/${profile}.conf"
        "./extensions/profiles/${profile}.conf"
        "../extensions/profiles/${profile}.conf"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path" ]]; then
            profile_file="$path"
            break
        fi
    done
    
    if [[ -n "$profile_file" ]]; then
        log_info "Transforming profile '$profile' to extensions list using: $profile_file"
        local extensions=$(grep -v '^#' "$profile_file" | grep -v '^$' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
        echo "$extensions"
    else
        log_error "Profile file not found for '$profile'. Tried paths: ${possible_paths[*]}"
        echo ""
    fi
}

load_extensions_from_profile() {
    local profiles=$1
    local all_extensions=""
    
    # Split profiles by + for composition support
    IFS='+' read -ra PROFILE_ARRAY <<< "$profiles"
    
    for profile in "${PROFILE_ARRAY[@]}"; do
        profile=$(echo "$profile" | xargs)
        # Try local path first (for make script calls), then container path
        local profile_file_local="$(dirname "$0")/extensions/profiles/${profile}.conf"
        local profile_file_container="/etc/postgresql/extensions/profiles/${profile}.conf"
        local profile_file=""
        
        if [[ -f "$profile_file_local" ]]; then
            profile_file="$profile_file_local"
        elif [[ -f "$profile_file_container" ]]; then
            profile_file="$profile_file_container"
        fi
        
        if [[ -n "$profile_file" ]]; then
            log_info "Loading extensions from profile: $profile"
            local profile_extensions=$(grep -v '^#' "$profile_file" | grep -v '^$' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
            
            if [[ -n "$all_extensions" && -n "$profile_extensions" ]]; then
                all_extensions="${all_extensions},${profile_extensions}"
            elif [[ -n "$profile_extensions" ]]; then
                all_extensions="$profile_extensions"
            fi
        else
            log_warning "Profile file not found: $profile (checked both local and container paths)"
        fi
    done
    
    echo "$all_extensions"
}

build_shared_preload_libraries() {
    local extensions=$1
    local preload_libs=""
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
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
# BUILD-TIME INSTALLATION (Docker build stage)
# =============================================================================

install_build() {
    local extensions="$1"
    
    if [[ -z "$extensions" ]]; then
        log_info "No extensions to install at build time"
        return 0
    fi
    
    log_info "BUILD-TIME: Installing extensions: $extensions"
    
    # Group extensions by installation method
    local apt_extensions=""
    local source_extensions=""
    local special_extensions=""
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        [[ -z "$ext" ]] && continue
        
        # Skip universal extensions (handled separately)
        [[ " ${UNIVERSAL_EXTENSIONS[*]} " =~ " ${ext} " ]] && continue
        
        if [[ -n "${EXTENSION_INSTALL_METHODS[$ext]:-}" ]]; then
            local method="${EXTENSION_INSTALL_METHODS[$ext]}"
            local type="${method%%:*}"
            
            case "$type" in
                "apt")
                    apt_extensions="${apt_extensions:+$apt_extensions,}$ext"
                    ;;
                "source")
                    source_extensions="${source_extensions:+$source_extensions,}$ext"
                    ;;
                "deb")
                    special_extensions="${special_extensions:+$special_extensions,}$ext"
                    ;;
            esac
        else
            # Check if it's covered by postgresql-contrib
            if [[ "$ext" =~ ^(pgcrypto|uuid-ossp|pg_trgm|btree_gin|btree_gist|pg_stat_statements)$ ]]; then
                apt_extensions="${apt_extensions:+$apt_extensions,}postgresql-contrib"
            else
                log_warning "Unknown installation method for extension: $ext"
            fi
        fi
    done
    
    # Install universal extensions first
    install_universal_extensions
    
    # Install by type for optimal Docker layers
    [[ -n "$apt_extensions" ]] && install_apt_extensions "$apt_extensions"
    [[ -n "$source_extensions" ]] && install_source_extensions "$source_extensions"
    [[ -n "$special_extensions" ]] && install_special_extensions "$special_extensions"
    
    log_success "BUILD-TIME: Extension installation completed"
}

install_universal_extensions() {
    log_info "Installing universal extensions..."
    
    apt-get update && apt-get install -y \
        postgresql-${MAJOR_VERSION}-hypopg \
        postgresql-${MAJOR_VERSION}-pg-qualstats \
        libcurl4 \
        && rm -rf /var/lib/apt/lists/*
    
    log_success "Universal extensions installed"
}

install_apt_extensions() {
    local extensions="$1"
    log_info "Installing APT extensions: $extensions"
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    local packages_to_install=()
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        case "$ext" in
            "citus")
                # Setup Citus repository
                curl -s https://install.citusdata.com/community/deb.sh | bash
                # Ensure libcurl4 runtime dependency is available
                apt-get update && apt-get install -y libcurl4
                packages_to_install+=("postgresql-${MAJOR_VERSION}-citus-13.1")
                ;;
            "postgis")
                packages_to_install+=("postgresql-${MAJOR_VERSION}-postgis-3" "postgresql-${MAJOR_VERSION}-postgis-3-scripts")
                ;;
            "pg_cron")
                packages_to_install+=("postgresql-${MAJOR_VERSION}-cron")
                ;;
            "postgresql-contrib")
                packages_to_install+=("postgresql-contrib")
                ;;
        esac
    done
    
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        apt-get update
        apt-get install -y "${packages_to_install[@]}"
        rm -rf /var/lib/apt/lists/*
    fi
    
    log_success "APT extensions installed"
}

install_source_extensions() {
    local extensions="$1"
    log_info "Building source extensions: $extensions"
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        case "$ext" in
            "pg_vector"|"vector")
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
    
    log_success "Source extensions built"
}

install_special_extensions() {
    local extensions="$1"
    log_info "Installing special package extensions: $extensions"
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        case "$ext" in
            "pg_search")
                install_paradedb
                ;;
        esac
    done
    
    log_success "Special extensions installed"
}

# =============================================================================
# SOURCE BUILD FUNCTIONS (with dynamic versions)
# =============================================================================

build_pg_vector() {
    local version="${PGVECTOR_VERSION:-latest}"
    log_info "Building pg_vector $version..."
    
    if [[ "$version" == "latest" ]]; then
        git clone --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector
    else
        # Remove 'v' prefix if present to avoid double 'v'
        version="${version#v}"
        git clone --branch "v$version" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector
    fi
    
    cd /tmp/pgvector
    make clean && make OPTFLAGS="" && make install
    cd /
    rm -rf /tmp/pgvector
    
    log_success "pg_vector built and installed"
}

build_pg_net() {
    local version="${PGNET_VERSION:-latest}"
    log_info "Building pg_net $version..."
    
    if [[ "$version" == "latest" ]]; then
        git clone --depth 1 https://github.com/supabase/pg_net.git /tmp/pg_net
    else
        # Remove 'v' prefix if present to avoid double 'v'
        version="${version#v}"
        git clone --branch "v$version" --depth 1 https://github.com/supabase/pg_net.git /tmp/pg_net
    fi
    
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
    local version="${PGPARTMAN_VERSION:-latest}"
    log_info "Building pg_partman $version..."
    
    if [[ "$version" == "latest" ]]; then
        git clone --depth 1 https://github.com/pgpartman/pg_partman.git /tmp/pg_partman
    else
        # Remove 'v' prefix if present to avoid double 'v'
        version="${version#v}"
        git clone --branch "v$version" --depth 1 https://github.com/pgpartman/pg_partman.git /tmp/pg_partman
    fi
    
    cd /tmp/pg_partman
    make NO_BGW=1 install
    cd /
    rm -rf /tmp/pg_partman
    
    log_success "pg_partman built and installed"
}

install_paradedb() {
    local version="${PARADEDB_VERSION:-latest}"
    log_info "Installing ParadeDB pg_search $version..."
    
    if [[ "$version" == "latest" ]]; then
        # Get latest version from GitHub API
        version=$(curl -s "https://api.github.com/repos/paradedb/paradedb/releases/latest" | jq -r '.tag_name')
    fi
    
    # Remove 'v' prefix if present
    version="${version#v}"
    
    apt-get update
    cd /tmp
    wget -q --no-check-certificate -O pg_search.deb \
        "https://github.com/paradedb/paradedb/releases/download/v${version}/postgresql-${MAJOR_VERSION}-pg-search_${version}-1PARADEDB-bookworm_amd64.deb"
    apt-get install -y ./pg_search.deb
    rm -f pg_search.deb
    rm -rf /var/lib/apt/lists/*
    
    log_success "ParadeDB pg_search installed"
}

# =============================================================================
# BUILD-TIME CONFIGURATION
# =============================================================================

configure_build_time() {
    local extensions="$1"
    
    log_info "BUILD-TIME: Configuring extensions: $extensions"
    
    # Generate shared_preload_libraries configuration
    local preload_libs=$(build_shared_preload_libraries "$extensions")
    
    # Create configuration directory
    mkdir -p "${POSTGRES_CONFIG_DIR:-/etc/postgresql/generated}"
    
    # Generate postgresql.conf with shared_preload_libraries
    cat > "${POSTGRES_CONFIG_DIR:-/etc/postgresql/generated}/postgresql.conf" << EOF
# PostgreSQL Configuration - Build-time generated (refactored)
# Extensions: $extensions
# Generated: $(date)

# Core PostgreSQL Settings
max_connections = 100
superuser_reserved_connections = 3

# Memory Settings 
shared_buffers = 256MB
effective_cache_size = 1GB
work_mem = 4MB
maintenance_work_mem = 64MB
dynamic_shared_memory_type = posix

# WAL Settings
wal_level = replica
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 1GB
min_wal_size = 80MB

# Query Planner
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200

# Parallel Processing (PostgreSQL 14+ compatible)
max_worker_processes = 8
max_parallel_workers = 4
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 2

# Analytics Query Optimization (PostgreSQL 14+ compatible)
enable_partitionwise_join = on
enable_partitionwise_aggregate = on
parallel_setup_cost = 1000.0
parallel_tuple_cost = 0.1

# Logging
log_destination = 'stderr'
logging_collector = off
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] '

# Shared preload libraries for extensions
shared_preload_libraries = '$preload_libs'

# Extension-specific settings
track_activities = on
track_counts = on

EOF
    
    # Write extensions list for runtime use (use postgres user directory instead of /tmp)
    echo -n "$extensions" > /var/lib/postgresql/postgres_extensions.txt
    
    # Generate SQL activation script
    generate_activation_script "$extensions" "/var/lib/postgresql/activate-extensions.sql"
    
    # Generate setup-config script for docker-entrypoint-initdb.d
    generate_setup_config_script
    
    log_success "BUILD-TIME: Configuration completed"
}

generate_activation_script() {
    local extensions="$1"
    local output_file="$2"
    
    local preload_libs=$(build_shared_preload_libraries "$extensions")
    
    if [[ -z "$preload_libs" ]]; then
        log_info "No shared_preload_libraries extensions to activate"
        echo "-- No extensions requiring activation" > "$output_file"
        return 0
    fi
    
    log_info "Generating activation script for: $preload_libs"
    
    cat > "$output_file" << 'EOF'
-- PostgreSQL Extension Activation Script
-- Auto-generated for shared_preload_libraries extensions

\echo 'Activating shared_preload_libraries extensions...'

DO $$
DECLARE
    ext_name TEXT;
    ext_list TEXT[] := string_to_array('PLACEHOLDER_EXTENSIONS', ',');
BEGIN
    FOREACH ext_name IN ARRAY ext_list LOOP
        ext_name := trim(ext_name);
        IF ext_name != '' THEN
            BEGIN
                EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', ext_name);
                RAISE NOTICE '✅ Extension % activated successfully', ext_name;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '❌ Failed to activate extension %: %', ext_name, SQLERRM;
            END;
        END IF;
    END LOOP;
END $$;

\echo 'Extension activation completed!'
EOF
    
    # Replace placeholder with actual extensions
    sed -i "s/PLACEHOLDER_EXTENSIONS/$preload_libs/g" "$output_file"
    
    log_success "Activation script generated: $output_file"
}

generate_setup_config_script() {
    local setup_script="/docker-entrypoint-initdb.d/00-setup-config.sh"
    
    log_info "Generating setup-config script"
    
    cat > "$setup_script" << 'EOF'
#!/bin/bash
# Auto-generated configuration setup script
# Copies pre-generated PostgreSQL configuration

echo "🔧 Copying pre-generated PostgreSQL configuration..."

if [[ -f "/etc/postgresql/generated/postgresql.conf" ]]; then
    cp "/etc/postgresql/generated/postgresql.conf" "/var/lib/postgresql/data/postgresql.conf"
    echo "✅ Pre-generated configuration applied to /var/lib/postgresql/data/postgresql.conf"
else
    echo "⚠️  No pre-generated configuration found, using defaults"
fi
EOF
    
    chmod +x "$setup_script"
    log_success "Setup-config script generated"
}

# =============================================================================
# RUNTIME OPERATIONS (minimal)
# =============================================================================

runtime_setup() {
    log_info "RUNTIME: Minimal setup..."
    
    # Load extensions list from build-time
    local extensions=""
    if [[ -f "/var/lib/postgresql/postgres_extensions.txt" ]]; then
        extensions=$(cat /var/lib/postgresql/postgres_extensions.txt)
        log_info "RUNTIME: Loaded extensions from build-time: $extensions"
    else
        log_warning "RUNTIME: No extensions list found from build-time"
        extensions=$(detect_extensions)
    fi
    
    # Export for other scripts
    export DETECTED_EXTENSIONS="$extensions"
    export SHARED_PRELOAD_LIBS=$(build_shared_preload_libraries "$extensions")
    
    log_success "RUNTIME: Setup completed"
}

activate_extensions() {
    local database="${1:-${POSTGRES_DB:-postgres}}"
    local user="${2:-${POSTGRES_USER:-postgres}}"
    
    if [[ -f "/var/lib/postgresql/activate-extensions.sql" ]]; then
        log_info "RUNTIME: Activating extensions in database $database..."
        
        if psql -U "$user" -d "$database" -f "/var/lib/postgresql/activate-extensions.sql" > /dev/null 2>&1; then
            log_success "RUNTIME: Extensions activated successfully"
            return 0
        else
            log_warning "RUNTIME: Extension activation had issues (may be normal if already activated)"
            return 1
        fi
    else
        log_info "RUNTIME: No activation script found"
        return 0
    fi
}

# =============================================================================
# MAIN INTERFACE
# =============================================================================

main() {
    case "${1:-}" in
        "transform_profile")
            shift
            transform_profile_to_extensions "$1"
            ;;
        "install_build")
            shift
            local extensions="${1:-$(detect_extensions)}"
            install_build "$extensions"
            ;;
        "configure_build_time")
            shift
            local extensions="${1:-$(detect_extensions)}"
            configure_build_time "$extensions"
            ;;
        "runtime_setup")
            runtime_setup
            ;;
        "activate")
            shift
            activate_extensions "$@"
            ;;
        "detect")
            detect_extensions
            ;;
        *)
            echo "Usage: $0 [transform_profile|install_build|configure_build_time|runtime_setup|activate|detect] [extensions]"
            echo ""
            echo "Local operations:"
            echo "  transform_profile <profile>  - Transform profile to extensions list (for make script)"
            echo ""
            echo "Build-time operations:"
            echo "  install_build [ext_list]     - Install extensions during Docker build"
            echo "  configure_build_time [ext]   - Generate configuration at build time"
            echo ""
            echo "Runtime operations:"
            echo "  runtime_setup               - Minimal runtime initialization"
            echo "  activate [db] [user]        - Activate extensions in database"
            echo "  detect                      - Detect enabled extensions"
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
