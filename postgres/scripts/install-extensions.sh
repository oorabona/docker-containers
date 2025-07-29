#!/bin/bash
# Docker-optimized Extension Installation Script
# Designed for efficient Docker layers with good debug visibility
# Called by Dockerfile during build process

set -e

# Source the extension manager
source "$(dirname "$0")/extension-manager.sh"

# =============================================================================
# DOCKER BUILD OPTIMIZED FUNCTIONS
# =============================================================================

# Install build dependencies (separate layer for caching)
install_build_dependencies() {
    log_info "Installing build dependencies..."
    
    apt-get update && apt-get install -y \
        build-essential \
        postgresql-server-dev-15 \
        git \
        curl \
        wget \
        ca-certificates \
        pkg-config \
        libssl-dev \
        libzstd-dev \
        liblz4-dev \
        libcurl4-openssl-dev \
        && rm -rf /var/lib/apt/lists/*
    
    log_success "Build dependencies installed"
}

# Install system packages (separate layer for debug)
install_system_packages() {
    log_info "Installing system packages..."
    
    apt-get update && apt-get install -y \
        curl \
        ca-certificates \
        wget \
        git \
        gnupg \
        lsb-release \
        locales-all \
        gettext-base \
        bc \
        && rm -rf /var/lib/apt/lists/*
    
    log_success "System packages installed"
}

# Install universal extensions (always beneficial - separate layer)
install_universal_extensions() {
    log_info "Installing universal extensions..."
    
    apt-get update && apt-get install -y \
        postgresql-15-hypopg \
        postgresql-15-pg-qualstats \
        && rm -rf /var/lib/apt/lists/*
    
    log_success "Universal extensions installed"
}

# Group and install APT extensions by type (smart layering)
install_grouped_apt_extensions() {
    local extensions="$1"
    
    if [[ -z "$extensions" ]]; then
        log_info "No APT extensions to install"
        return 0
    fi
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    # Group by installation complexity for optimal layers
    local simple_packages=()
    local complex_setups=()
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        [[ -z "$ext" ]] && continue
        
        case "$ext" in
            # Complex setups (need repository addition)
            "citus")
                complex_setups+=("$ext")
                ;;
            # Simple package installs
            "postgis"|"pg_cron"|"postgresql-contrib")
                simple_packages+=("$ext")
                ;;
        esac
    done
    
    # Install complex setups first (each in own layer for debug)
    for ext in "${complex_setups[@]}"; do
        case "$ext" in
            "citus")
                log_info "Installing Citus (complex setup)..."
                curl -s https://install.citusdata.com/community/deb.sh | bash
                apt-get update && apt-get install -y postgresql-15-citus-13.1
                rm -rf /var/lib/apt/lists/*
                log_success "Citus installed"
                ;;
        esac
    done
    
    # Install simple packages together (efficient single layer)
    if [[ ${#simple_packages[@]} -gt 0 ]]; then
        log_info "Installing simple APT extensions: ${simple_packages[*]}"
        
        apt-get update
        local packages_to_install=()
        
        for ext in "${simple_packages[@]}"; do
            case "$ext" in
                "postgis")
                    packages_to_install+=("postgresql-15-postgis-3" "postgresql-15-postgis-3-scripts")
                    ;;
                "pg_cron")
                    packages_to_install+=("postgresql-15-cron")
                    ;;
                "postgresql-contrib")
                    packages_to_install+=("postgresql-contrib")
                    ;;
            esac
        done
        
        apt-get install -y "${packages_to_install[@]}"
        rm -rf /var/lib/apt/lists/*
        
        log_success "Simple APT extensions installed"
    fi
}

# Build source extensions (each in separate layer for debug/cache)
# Note: Only works in build context with build dependencies
build_source_extensions() {
    local extensions="$1"
    
    if [[ -z "$extensions" ]]; then
        log_info "No source extensions to build"
        return 0
    fi
    
    # Check if we have build tools available
    if ! command -v make &> /dev/null; then
        log_warning "Build tools not available - source extensions should be built in builder stage"
        log_info "Skipping source extensions in runtime: $extensions"
        return 0
    fi
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        [[ -z "$ext" ]] && continue
        
        # Each extension in its own layer for better debug + cache
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
}

# Install special package extensions (separate layer for debug)
install_special_packages() {
    local extensions="$1"
    
    if [[ -z "$extensions" ]]; then
        log_info "No special packages to install"
        return 0
    fi
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        [[ -z "$ext" ]] && continue
        
        case "$ext" in
            "pg_search")
                log_info "Installing ParadeDB pg_search (special package)..."
                install_paradedb
                ;;
        esac
    done
}

# =============================================================================
# MAIN INSTALLATION ORCHESTRATOR
# =============================================================================

main() {
    local mode="${1:-auto}"
    local requested_extensions="${2:-}"
    
    case "$mode" in
        "deps")
            # Layer 1: Build dependencies
            install_build_dependencies
            ;;
        "system")
            # Layer 2: System packages  
            install_system_packages
            ;;
        "universal")
            # Layer 3: Universal extensions
            install_universal_extensions
            ;;
        "extensions")
            # Layer 4+: Extension installation
            local extensions="${requested_extensions:-$(detect_extensions)}"
            
            log_info "Installing extensions with smart layering: $extensions"
            
            # Group extensions by installation method
            local apt_extensions=""
            local source_extensions=""
            local special_extensions=""
            
            IFS=',' read -ra EXT_ARRAY <<< "$extensions"
            
            for ext in "${EXT_ARRAY[@]}"; do
                ext=$(echo "$ext" | xargs)
                [[ -z "$ext" ]] && continue
                
                # Skip universal extensions (already installed)
                [[ " ${UNIVERSAL_EXTENSIONS[*]} " =~ " ${ext} " ]] && continue
                
                case "$ext" in
                    # APT-based
                    "citus"|"postgis"|"pg_cron")
                        apt_extensions="${apt_extensions:+$apt_extensions,}$ext"
                        ;;
                    # Source-based  
                    "pg_vector"|"vector"|"pg_net"|"pgjwt"|"pg_partman")
                        source_extensions="${source_extensions:+$source_extensions,}$ext"
                        ;;
                    # Special packages
                    "pg_search")
                        special_extensions="${special_extensions:+$special_extensions,}$ext"
                        ;;
                    # postgresql-contrib extensions
                    "pgcrypto"|"uuid-ossp"|"pg_trgm"|"btree_gin"|"btree_gist"|"pg_stat_statements")
                        apt_extensions="${apt_extensions:+$apt_extensions,}postgresql-contrib"
                        ;;
                esac
            done
            
            # Install in optimal layer order
            install_grouped_apt_extensions "$apt_extensions"
            build_source_extensions "$source_extensions"  
            install_special_packages "$special_extensions"
            ;;
        "auto")
            # Full auto installation (all layers)
            install_build_dependencies
            install_system_packages
            install_universal_extensions
            
            local extensions=$(detect_extensions)
            "$0" "extensions" "$extensions"
            ;;
        "--help"|"-h"|"help")
            echo "Usage: $0 [deps|system|universal|extensions|auto] [extension_list]"
            echo ""
            echo "Layer-optimized installation modes:"
            echo "  deps       - Install build dependencies (Layer 1)"
            echo "  system     - Install system packages (Layer 2)"  
            echo "  universal  - Install universal extensions (Layer 3)"
            echo "  extensions - Install specific extensions (Layer 4+)"
            echo "  auto       - Install everything automatically"
            echo ""
            echo "Examples:"
            echo "  $0 auto                                    # Install everything"
            echo "  $0 extensions 'citus,pg_vector,postgis'   # Install specific extensions"
            exit 0
            ;;
        *)
            echo "Error: Unknown mode '$mode'"
            echo "Use '$0 --help' for usage information"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"