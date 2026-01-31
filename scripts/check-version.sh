#!/usr/bin/env bash

# Version checking utility - focused on version detection only
# Part of make script decomposition for better Single Responsibility

# Source shared logging utilities
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/helpers/logging.sh"
source "$PROJECT_ROOT/helpers/version-utils.sh"

# Check container version function
check_container_version() {
    local target="$1"
    
    if [[ ! -d "$target" ]] || [[ ! -f "$target/Dockerfile" ]]; then
        log_error "$target is not a valid target (no Dockerfile found)!"
        return 1
    fi
    
    if [[ ! -f "$target/version.sh" ]]; then
        log_error "No version.sh script found in $target directory!"
        return 1
    fi
    
    # Get the latest upstream version (version.sh now single-purpose)
    pushd "${target}" > /dev/null 2>&1 || return 1
    local latest_version
    latest_version=$(./version.sh 2>/dev/null)
    local exit_code=$?
    
    # Validate the version output
    if [ $exit_code -eq 0 ] && [ -n "$latest_version" ] && [ "$latest_version" != "unknown" ] && [ "$latest_version" != "no-published-version" ]; then
        echo "$latest_version"
    else
        log_error "Failed to get latest upstream version for $target"
        popd > /dev/null 2>&1 || true
        echo "unknown"
        return 1
    fi
    
    # Check current published version using container-specific pattern
    local current_version
    current_version=$(get_current_published_version "oorabona/$target" || true)
    
    if [ -n "$current_version" ]; then
        log_success "Current published version: $current_version"
    else
        log_warning "No published version found (container not yet released)"
    fi

    popd > /dev/null 2>&1 || true
    return 0  # Explicit success return
}

# Get version for build process
get_build_version() {
    local target="$1"
    local wanted_version="$2"
    
    # Note: We assume validation has already been done by the calling function
    # since we're about to pushd into the directory
    
    pushd "${target}" > /dev/null 2>&1 || return 1
    
    if [[ ! -f "version.sh" ]]; then
        log_error "No version.sh script found in $target directory!"
        popd > /dev/null 2>&1 || true
        return 1
    fi
    
    local versions
    local exit_code
    
    # Handle version detection logic properly
    if [ "$wanted_version" = "latest" ]; then
        # Get latest upstream version
        versions=$(./version.sh 2>/dev/null)
        exit_code=$?
    elif [ "$wanted_version" = "current" ]; then
        # Get current published version using container-specific pattern
        versions=$(get_current_published_version "oorabona/$target")
        [[ -z "$versions" ]] && versions="unknown"
        exit_code=$?
    else
        # Use the specific version provided directly
        versions="$wanted_version"
        exit_code=0
    fi
    
    # Handle special cases
    if [ "$versions" = "no-published-version" ]; then
        log_warning "No published version found for $target, this will be an initial release"
        # For no-published-version, we'll use the latest upstream version
        # Try to get latest upstream version explicitly
        versions=$(./version.sh 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$versions" ]; then
            log_error "Could not determine version to build for $target"
            popd > /dev/null 2>&1 || true
            return 1
        fi
    elif [ $exit_code -ne 0 ] || [ -z "$versions" ]; then
        log_error "Version checking returned false, please ensure version is correct: $wanted_version"
        popd > /dev/null 2>&1 || true
        return 1
    fi
    
    echo "$versions"
    popd > /dev/null 2>&1 || true
    return 0  # Explicit success return
}

# Export functions for use by make script
export -f check_container_version
export -f get_build_version
