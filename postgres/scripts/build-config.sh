#!/bin/bash
# Dynamic PostgreSQL Configuration Builder
# Generates postgresql.conf based on enabled extensions and profile

set -e

# Configuration paths
TEMPLATE_DIR="/etc/postgresql/config-templates"
EXTENSION_TEMPLATE_DIR="$TEMPLATE_DIR/extensions"
PROFILE_TEMPLATE_DIR="$TEMPLATE_DIR/profiles"
OUTPUT_CONFIG="/tmp/postgresql.conf"

# Logging functions
log_info() {
    echo "🔧 [build-config] $1" >&2
}

log_warning() {
    echo "⚠️  [build-config] $1" >&2
}

log_error() {
    echo "❌ [build-config] $1" >&2
}

# Function to detect enabled extensions
detect_enabled_extensions() {
    local extensions=""
    
    # Priority 1: Use POSTGRES_EXTENSIONS if specified
    if [[ -n "$POSTGRES_EXTENSIONS" ]]; then
        extensions="$POSTGRES_EXTENSIONS"
        log_info "Using extensions from POSTGRES_EXTENSIONS: $extensions"
    # Priority 2: Load from profile if specified  
    elif [[ -n "$POSTGRES_EXTENSION_PROFILE" ]]; then
        extensions=$(load_extensions_from_profile "$POSTGRES_EXTENSION_PROFILE")
        log_info "Using extensions from profile '$POSTGRES_EXTENSION_PROFILE': $extensions"
    else
        log_warning "No extensions or profile specified, using base configuration only"
        extensions=""
    fi
    
    # Always add universal extensions that provide general benefits
    local universal_extensions="hypopg,pg_qualstats,postgres_fdw,file_fdw"
    if [[ -n "$extensions" ]]; then
        extensions="$extensions,$universal_extensions"
    else
        extensions="$universal_extensions"
    fi
    
    log_info "Final extensions list (including universals): $extensions"
    echo "$extensions"
}

# Function to load extensions from profile(s) - supports composition
load_extensions_from_profile() {
    local profiles=$1
    local all_extensions=""
    
    # Split profiles by + for composition support
    IFS='+' read -ra PROFILE_ARRAY <<< "$profiles"
    
    for profile in "${PROFILE_ARRAY[@]}"; do
        # Trim whitespace
        profile=$(echo "$profile" | xargs)
        local profile_file="/etc/postgresql/extensions/profiles/${profile}.conf"
        
        if [[ -f "$profile_file" ]]; then
            log_info "Loading extensions from profile: $profile"
            # Extract extension names from profile file (ignore comments and empty lines)
            local profile_extensions=$(grep -v '^#' "$profile_file" | grep -v '^$' | awk '{print $1}' | tr '\n' ',' | sed 's/,$//')
            
            # Append to all extensions (deduplication handled later)
            if [[ -n "$all_extensions" && -n "$profile_extensions" ]]; then
                all_extensions="${all_extensions},${profile_extensions}"
            elif [[ -n "$profile_extensions" ]]; then
                all_extensions="$profile_extensions"
            fi
        else
            log_warning "Profile file not found: $profile_file"
        fi
    done
    
    # Remove duplicates
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
        all_extensions=$(printf "%s," "${unique_extensions[@]}" | sed 's/,$//')
    fi
    
    echo "$all_extensions"
}

# Function to determine shared_preload_libraries
build_shared_preload_libraries() {
    local extensions=$1
    local preload_libs=""
    
    # Extensions that require shared_preload_libraries
    local preload_extensions=(
        "citus"
        "pg_cron" 
        "pg_stat_statements"
        "pg_net"
        "pg_search"
        "pg_qualstats"
        "auto_explain"
    )
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)  # trim whitespace
        for preload_ext in "${preload_extensions[@]}"; do
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

# Function to determine deployment profile
detect_deployment_profile() {
    local profile="${POSTGRES_DEPLOYMENT_PROFILE:-}"
    
    # Auto-detect if not specified
    if [[ -z "$profile" ]]; then
        if [[ "${POSTGRES_MODE:-single}" == "single" && "${NODE_ENV:-}" == "development" ]]; then
            profile="dev"
        elif [[ -n "$CITUS_SHARD_COUNT" ]] || [[ "$POSTGRES_EXTENSION_PROFILE" == *"analytics"* ]]; then
            profile="analytics" 
        else
            profile="prod"
        fi
    fi
    
    log_info "Using deployment profile: $profile"
    echo "$profile"
}

# Function to validate extension compatibility
validate_extension_compatibility() {
    local extensions=$1
    local warnings=()
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    # Check for known incompatibilities
    local has_citus=false
    local has_pg_search=false
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        case "$ext" in
            "citus") has_citus=true ;;
            "pg_search") has_pg_search=true ;;
        esac
    done
    
    # Log warnings for potential issues
    if [[ "$has_citus" == true && "$has_pg_search" == true ]]; then
        log_warning "Citus + pg_search: ensure proper distributed table setup for search indexes"
    fi
    
    # More compatibility checks can be added here
    return 0
}

# Function to set default environment variables
set_default_env_vars() {
    # PostgreSQL base settings with defaults
    export POSTGRES_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-100}"
    export POSTGRES_SUPERUSER_RESERVED_CONNECTIONS="${POSTGRES_SUPERUSER_RESERVED_CONNECTIONS:-3}"
    export POSTGRES_SHARED_BUFFERS="${POSTGRES_SHARED_BUFFERS:-256MB}"
    export POSTGRES_EFFECTIVE_CACHE_SIZE="${POSTGRES_EFFECTIVE_CACHE_SIZE:-1GB}"
    export POSTGRES_WORK_MEM="${POSTGRES_WORK_MEM:-4MB}"
    export POSTGRES_MAINTENANCE_WORK_MEM="${POSTGRES_MAINTENANCE_WORK_MEM:-64MB}"
    export POSTGRES_WAL_BUFFERS="${POSTGRES_WAL_BUFFERS:-16MB}"
    export POSTGRES_CHECKPOINT_TIMEOUT="${POSTGRES_CHECKPOINT_TIMEOUT:-5min}"
    export POSTGRES_MAX_WAL_SIZE="${POSTGRES_MAX_WAL_SIZE:-1GB}"
    export POSTGRES_MIN_WAL_SIZE="${POSTGRES_MIN_WAL_SIZE:-80MB}"
    export POSTGRES_DEFAULT_STATISTICS_TARGET="${POSTGRES_DEFAULT_STATISTICS_TARGET:-100}"
    export POSTGRES_RANDOM_PAGE_COST="${POSTGRES_RANDOM_PAGE_COST:-1.1}"
    export POSTGRES_EFFECTIVE_IO_CONCURRENCY="${POSTGRES_EFFECTIVE_IO_CONCURRENCY:-200}"
    export POSTGRES_LOG_MIN_DURATION_STATEMENT="${POSTGRES_LOG_MIN_DURATION_STATEMENT:-1000}"
    export POSTGRES_LOG_STATEMENT="${POSTGRES_LOG_STATEMENT:-none}"
    export POSTGRES_LOG_CONNECTIONS="${POSTGRES_LOG_CONNECTIONS:-off}"
    export POSTGRES_LOG_DISCONNECTIONS="${POSTGRES_LOG_DISCONNECTIONS:-off}"
    export POSTGRES_TRACK_FUNCTIONS="${POSTGRES_TRACK_FUNCTIONS:-none}"
    export POSTGRES_LOCALE="${POSTGRES_LOCALE:-C}"
    export POSTGRES_TIMEZONE="${POSTGRES_TIMEZONE:-UTC}"
    
    # Extension-specific defaults
    export CITUS_SHARD_COUNT="${CITUS_SHARD_COUNT:-32}"
    export CITUS_SHARD_REPLICATION_FACTOR="${CITUS_SHARD_REPLICATION_FACTOR:-1}"
    export CITUS_USE_SECONDARY_NODES="${CITUS_USE_SECONDARY_NODES:-never}"
    export CITUS_MAX_PREPARED_TRANSACTIONS="${CITUS_MAX_PREPARED_TRANSACTIONS:-200}"
    export PG_NET_DATABASE_NAME="${PG_NET_DATABASE_NAME:-postgres}"
    export PG_NET_TTL="${PG_NET_TTL:-300}"
    export PG_NET_BATCH_SIZE="${PG_NET_BATCH_SIZE:-100}"
    export PG_CRON_DATABASE_NAME="${PG_CRON_DATABASE_NAME:-postgres}"
    export PG_VECTOR_PROBES="${PG_VECTOR_PROBES:-1}"
    export PG_STAT_STATEMENTS_MAX="${PG_STAT_STATEMENTS_MAX:-5000}"
    export PG_STAT_STATEMENTS_TRACK="${PG_STAT_STATEMENTS_TRACK:-all}"
    export PG_QUALSTATS_MAX="${PG_QUALSTATS_MAX:-1000}"
    export PG_QUALSTATS_ENABLED="${PG_QUALSTATS_ENABLED:-on}"
    export PG_QUALSTATS_SAMPLE_RATE="${PG_QUALSTATS_SAMPLE_RATE:-0.1}"
    export HYPOPG_WORK_MEM="${HYPOPG_WORK_MEM:-8MB}"
}

# Function to apply configuration template by sourcing bash scripts
apply_template() {
    local template_file=$1
    local output_file=$2
    
    if [[ -f "$template_file" ]]; then
        log_info "Applying template: $(basename "$template_file")"
        
        # Source the template file as a bash script
        # The template should output PostgreSQL configuration directly
        if source "$template_file" >> "$output_file" 2>/dev/null; then
            echo "" >> "$output_file"  # Add blank line between sections
        else
            log_warning "Failed to source template: $template_file"
        fi
    else
        log_warning "Template not found: $template_file"
    fi
}

# Main configuration building function
build_configuration() {
    log_info "Starting PostgreSQL configuration generation"
    
    # Set default environment variables
    set_default_env_vars
    
    # Detect configuration parameters
    local extensions=$(detect_enabled_extensions)
    local deployment_profile=$(detect_deployment_profile)
    local preload_libs=$(build_shared_preload_libraries "$extensions")
    
    # Validate compatibility
    validate_extension_compatibility "$extensions"
    
    # Start with clean output file
    echo "# PostgreSQL Configuration - Generated $(date)" > "$OUTPUT_CONFIG"
    echo "# Extensions: $extensions" >> "$OUTPUT_CONFIG"
    echo "# Deployment Profile: $deployment_profile" >> "$OUTPUT_CONFIG"
    echo "" >> "$OUTPUT_CONFIG"
    
    # Apply base configuration
    apply_template "$TEMPLATE_DIR/postgresql.base.conf.template" "$OUTPUT_CONFIG"
    
    # Apply deployment profile configuration
    apply_template "$PROFILE_TEMPLATE_DIR/${deployment_profile}.conf.template" "$OUTPUT_CONFIG"
    
    # Apply extension-specific configurations
    if [[ -n "$extensions" ]]; then
        echo "# Extension-specific configurations" >> "$OUTPUT_CONFIG"
        
        # Extensions that require shared_preload_libraries - only apply templates if they're in preload_libs
        local preload_required=("citus" "pg_cron" "pg_stat_statements" "pg_net" "pg_search" "pg_qualstats" "auto_explain")
        
        IFS=',' read -ra EXT_ARRAY <<< "$extensions"
        for ext in "${EXT_ARRAY[@]}"; do
            ext=$(echo "$ext" | xargs)  # trim whitespace
            if [[ -n "$ext" ]]; then
                # Check if this extension requires shared_preload_libraries
                local requires_preload=false
                for preload_ext in "${preload_required[@]}"; do
                    if [[ "$ext" == "$preload_ext" ]] || [[ "$ext" == "vector" && "$preload_ext" == "pg_vector" ]]; then
                        requires_preload=true
                        break
                    fi
                done
                
                # Only apply template if:
                # 1. Extension doesn't require preload, OR
                # 2. Extension requires preload AND is in preload_libs
                local should_apply_template=false
                if [[ "$requires_preload" == "false" ]]; then
                    should_apply_template=true
                elif [[ "$preload_libs" == *"$ext"* ]]; then
                    should_apply_template=true
                fi
                
                if [[ "$should_apply_template" == "true" ]]; then
                    # Handle extension name variations
                    local template_name="$ext"
                    case "$ext" in
                        "vector"|"pg_vector") template_name="pg_vector" ;;
                        "postgis") template_name="postgis" ;;
                        "citus") template_name="citus" ;;
                        "pg_net") template_name="pg_net" ;;
                        "pg_cron") template_name="pg_cron" ;;
                        "pg_search") template_name="pg_search" ;;
                        "pg_stat_statements") template_name="pg_stat_statements" ;;
                        "hypopg") template_name="hypopg" ;;
                        "pg_qualstats") template_name="pg_qualstats" ;;
                    esac
                    
                    apply_template "$EXTENSION_TEMPLATE_DIR/${template_name}.conf.template" "$OUTPUT_CONFIG"
                else
                    log_info "Skipping template for $ext (not in shared_preload_libraries)"
                fi
            fi
        done
    fi
    
    # Export preload_libs for Dockerfile to use
    echo "$preload_libs" > "/tmp/preload_libs.txt"
    
    log_info "Configuration generated successfully: $OUTPUT_CONFIG"
    log_info "Shared preload libraries: $preload_libs"
    
    # Copy to final location
    if [[ -n "${POSTGRES_CONFIG_DIR:-}" ]]; then
        cp "$OUTPUT_CONFIG" "$POSTGRES_CONFIG_DIR/postgresql.conf"
        log_info "Configuration copied to: $POSTGRES_CONFIG_DIR/postgresql.conf"
    fi
}

# Script execution
case "${1:-build}" in
    "build")
        build_configuration
        ;;
    "validate")
        extensions=$(detect_enabled_extensions)
        validate_extension_compatibility "$extensions"
        log_info "Configuration validation completed"
        ;;
    "preview")
        build_configuration
        echo "Generated configuration preview:"
        cat "$OUTPUT_CONFIG"
        ;;
    *)
        echo "Usage: $0 [build|validate|preview]"
        echo "  build    - Generate postgresql.conf (default)"
        echo "  validate - Validate extension compatibility"
        echo "  preview  - Generate and display configuration"
        exit 1
        ;;
esac