#!/bin/bash
# Extension Compatibility Validation Script
# Validates extension combinations against compatibility matrix

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTGRES_DIR="$(dirname "$SCRIPT_DIR")"
COMPATIBILITY_MATRIX="$POSTGRES_DIR/compatibility-matrix.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Function to validate JSON compatibility matrix
validate_matrix_format() {
    log_info "Validating compatibility matrix format..."
    
    if [[ ! -f "$COMPATIBILITY_MATRIX" ]]; then
        log_error "Compatibility matrix not found: $COMPATIBILITY_MATRIX"
        return 1
    fi
    
    if ! jq empty "$COMPATIBILITY_MATRIX" 2>/dev/null; then
        log_error "Compatibility matrix is not valid JSON"
        return 1
    fi
    
    # Check required sections
    local required_sections=("tested_combinations" "known_incompatibilities" "performance_requirements" "installation_methods")
    
    for section in "${required_sections[@]}"; do
        if ! jq -e ".compatibility_matrix.$section" "$COMPATIBILITY_MATRIX" >/dev/null; then
            log_error "Missing required section: $section"
            return 1
        fi
    done
    
    log_success "Compatibility matrix format is valid"
    return 0
}

# Function to validate extension combination
validate_extension_combination() {
    local extensions="$1"
    local profile_name="$2"
    
    log_info "Validating extension combination: $extensions"
    
    # Check for known incompatibilities
    local incompatibilities=$(jq -r '.compatibility_matrix.known_incompatibilities[] | select(.status != "resolved") | .extensions | join(",")' "$COMPATIBILITY_MATRIX")
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    # Check each extension against known incompatibilities
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)  # trim whitespace
        
        # Check if this extension is in any unresolved incompatibility
        while IFS= read -r incompatible_combo; do
            if [[ -n "$incompatible_combo" ]] && echo "$incompatible_combo" | grep -q "$ext"; then
                log_warning "Extension '$ext' has known compatibility issues"
            fi
        done <<< "$incompatibilities"
    done
    
    # Validate against tested profile if specified
    if [[ -n "$profile_name" ]]; then
        local profile_exists=$(jq -e ".compatibility_matrix.tested_combinations.\"$profile_name\"" "$COMPATIBILITY_MATRIX" >/dev/null && echo "true" || echo "false")
        
        if [[ "$profile_exists" == "true" ]]; then
            log_success "Profile '$profile_name' found in compatibility matrix"
            
            # Check if all requested extensions are in the profile
            local profile_extensions=$(jq -r ".compatibility_matrix.tested_combinations.\"$profile_name\".extensions[].name" "$COMPATIBILITY_MATRIX" | tr '\n' ',' | sed 's/,$//')
            
            for ext in "${EXT_ARRAY[@]}"; do
                ext=$(echo "$ext" | xargs)
                if [[ -n "$ext" ]] && ! echo "$profile_extensions" | grep -q "$ext"; then
                    log_warning "Extension '$ext' not found in profile '$profile_name'"
                fi
            done
        else
            log_warning "Profile '$profile_name' not found in compatibility matrix"
        fi
    fi
    
    return 0
}

# Function to check performance requirements
validate_performance_requirements() {
    local extensions="$1"
    
    log_info "Checking performance requirements for extensions: $extensions"
    
    local min_memory=$(jq -r '.compatibility_matrix.performance_requirements.minimum_memory' "$COMPATIBILITY_MATRIX")
    local rec_memory=$(jq -r '.compatibility_matrix.performance_requirements.recommended_memory' "$COMPATIBILITY_MATRIX")
    local min_cpu=$(jq -r '.compatibility_matrix.performance_requirements.minimum_cpu_cores' "$COMPATIBILITY_MATRIX")
    local rec_cpu=$(jq -r '.compatibility_matrix.performance_requirements.recommended_cpu_cores' "$COMPATIBILITY_MATRIX")
    
    log_info "Minimum requirements: Memory: $min_memory, CPU cores: $min_cpu"
    log_info "Recommended: Memory: $rec_memory, CPU cores: $rec_cpu"
    
    # Check if high-performance extensions are requested
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    local needs_high_memory=false
    local needs_high_cpu=false
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        case "$ext" in
            "vector"|"pg_search"|"citus")
                needs_high_memory=true
                needs_high_cpu=true
                ;;
            "postgis"|"pg_partman")
                needs_high_memory=true
                ;;
        esac
    done
    
    if [[ "$needs_high_memory" == "true" ]]; then
        log_warning "Extensions require high memory allocation - consider using recommended settings"
    fi
    
    if [[ "$needs_high_cpu" == "true" ]]; then
        log_warning "Extensions benefit from multiple CPU cores for parallel processing"
    fi
    
    log_success "Performance requirements check completed"
    return 0
}

# Function to show installation methods for extensions
show_installation_methods() {
    local extensions="$1"
    
    log_info "Installation methods for requested extensions:"
    
    IFS=',' read -ra EXT_ARRAY <<< "$extensions"
    
    for ext in "${EXT_ARRAY[@]}"; do
        ext=$(echo "$ext" | xargs)
        if [[ -n "$ext" ]]; then
            # Find installation method for this extension
            local method=""
            local found=false
            
            for method_type in source apt contrib deb; do
                local extensions_in_method=$(jq -r ".compatibility_matrix.installation_methods.\"$method_type\".extensions[]" "$COMPATIBILITY_MATRIX" 2>/dev/null | tr '\n' ' ')
                if echo "$extensions_in_method" | grep -q "$ext"; then
                    method="$method_type"
                    found=true
                    break
                fi
            done
            
            if [[ "$found" == "true" ]]; then
                local description=$(jq -r ".compatibility_matrix.installation_methods.\"$method\".description" "$COMPATIBILITY_MATRIX")
                echo "  📦 $ext: $method ($description)"
            else
                echo "  ❓ $ext: installation method not documented"
            fi
        fi
    done
    
    return 0
}

# Function to generate compatibility report
generate_compatibility_report() {
    local extensions="$1"
    local profile_name="$2"
    
    log_info "=== PostgreSQL Extension Compatibility Report ==="
    echo ""
    echo "Requested Extensions: $extensions"
    echo "Profile: ${profile_name:-none}"
    echo "Date: $(date)"
    echo ""
    
    # Matrix validation
    if validate_matrix_format; then
        echo "✅ Compatibility matrix format: VALID"
    else
        echo "❌ Compatibility matrix format: INVALID"
        return 1
    fi
    
    # Extension combination validation
    if validate_extension_combination "$extensions" "$profile_name"; then
        echo "✅ Extension combination: COMPATIBLE"
    else
        echo "❌ Extension combination: ISSUES FOUND"
    fi
    
    # Performance requirements
    validate_performance_requirements "$extensions"
    
    # Installation methods
    show_installation_methods "$extensions"
    
    echo ""
    log_success "Compatibility report completed"
    return 0
}

# Main execution
case "${1:-validate}" in
    "validate")
        extensions="${POSTGRES_EXTENSIONS:-}"
        profile="${POSTGRES_EXTENSION_PROFILE:-}"
        
        if [[ -z "$extensions" && -z "$profile" ]]; then
            log_error "No extensions or profile specified"
            echo "Usage: $0 validate [extensions] [profile]"
            echo "Or set POSTGRES_EXTENSIONS and/or POSTGRES_EXTENSION_PROFILE environment variables"
            exit 1
        fi
        
        generate_compatibility_report "$extensions" "$profile"
        ;;
    "matrix")
        if validate_matrix_format; then
            log_success "Compatibility matrix is valid"
            jq '.compatibility_matrix | keys' "$COMPATIBILITY_MATRIX"
        else
            exit 1
        fi
        ;;
    "profiles")
        log_info "Available extension profiles:"
        jq -r '.compatibility_matrix.tested_combinations | keys[]' "$COMPATIBILITY_MATRIX" | while read -r profile; do
            local description=$(jq -r ".compatibility_matrix.tested_combinations.\"$profile\".description" "$COMPATIBILITY_MATRIX")
            echo "  📋 $profile: $description"
        done
        ;;
    "methods")
        log_info "Available installation methods:"
        jq -r '.compatibility_matrix.installation_methods | to_entries[] | "  📦 \(.key): \(.value.description)"' "$COMPATIBILITY_MATRIX"
        ;;
    *)
        echo "Usage: $0 [validate|matrix|profiles|methods]"
        echo "  validate - Validate extension combination (default)"
        echo "  matrix   - Validate compatibility matrix format"
        echo "  profiles - List available extension profiles"
        echo "  methods  - List installation methods"
        exit 1
        ;;
esac