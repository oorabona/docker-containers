#!/bin/bash
# Build and push extension images for PostgreSQL containers
# Images are pushed to registry (ghcr.io) for use with COPY --from=
#
# Usage:
#   ./scripts/build-extensions.sh <container> [options]
#
# Examples:
#   ./scripts/build-extensions.sh postgres                    # Build & push all missing
#   ./scripts/build-extensions.sh postgres --pg-version 17    # Build for specific PG version
#   ./scripts/build-extensions.sh postgres --extension pgvector  # Build specific extension
#   ./scripts/build-extensions.sh postgres --force            # Rebuild even if exists
#   ./scripts/build-extensions.sh postgres --list             # List status of all extensions
#   ./scripts/build-extensions.sh postgres --local-only       # Build locally without pushing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../helpers/extension-utils.sh
source "$ROOT_DIR/helpers/extension-utils.sh"

# Defaults
CONTAINER=""
PG_VERSION=""
EXTENSION=""
FORCE=false
LIST_ONLY=false
LOCAL_ONLY=false
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $(basename "$0") <container> [options]

Build and push extension images for PostgreSQL containers.
Images are pushed to registry for use with COPY --from= in Dockerfiles.

Arguments:
  container              Container name (e.g., postgres)

Options:
  --pg-version VERSION   PostgreSQL major version (e.g., 17, 16)
                         Default: auto-detect from version.sh
  --extension NAME       Build only specific extension
  --force                Rebuild even if image already exists in registry
  --list                 List extension status without building
  --local-only           Build locally without pushing to registry
  --dry-run              Show what would be done without executing
  -h, --help             Show this help

Environment:
  EXTENSION_REGISTRY     Registry URL (default: ghcr.io)

Examples:
  $(basename "$0") postgres                        # Build & push all missing
  $(basename "$0") postgres --pg-version 17        # Build for PG 17
  $(basename "$0") postgres --extension pgvector   # Build only pgvector
  $(basename "$0") postgres --list                 # Show status
  $(basename "$0") postgres --local-only           # Build without push
EOF
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            --pg-version)
                PG_VERSION="$2"
                shift 2
                ;;
            --extension)
                EXTENSION="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --list)
                LIST_ONLY=true
                shift
                ;;
            --local-only)
                LOCAL_ONLY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                if [[ -z "$CONTAINER" ]]; then
                    CONTAINER="$1"
                else
                    log_error "Unexpected argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$CONTAINER" ]]; then
        log_error "Container name required"
        usage
    fi
}

# Detect PostgreSQL major version
detect_pg_version() {
    local container_dir="$ROOT_DIR/$CONTAINER"
    local version_script="$container_dir/version.sh"

    if [[ -n "$PG_VERSION" ]]; then
        echo "$PG_VERSION"
        return
    fi

    if [[ -x "$version_script" ]]; then
        local full_version
        full_version=$("$version_script" 2>/dev/null | head -1)
        pg_major_version "$full_version"
    else
        log_error "Cannot detect PG version. Use --pg-version or ensure version.sh exists."
        exit 1
    fi
}

# List extension status
list_extension_status() {
    local config_file="$1"
    local pg_major="$2"

    echo ""
    echo "Extension Status for PostgreSQL $pg_major"
    echo "=========================================="
    echo ""

    printf "%-15s %-10s %-12s %s\n" "Extension" "Version" "Status" "Image"
    printf "%-15s %-10s %-12s %s\n" "---------" "-------" "------" "-----"

    for ext in $(list_extensions_by_priority "$config_file"); do
        local version
        version=$(ext_config "$ext" "version" "$config_file")
        local image
        image=$(ext_image_name "$ext" "$version" "$pg_major")

        local status
        if image_exists_in_registry "$image" 2>/dev/null; then
            status="${GREEN}✓ exists${NC}"
        else
            status="${YELLOW}✗ missing${NC}"
        fi

        printf "%-15s %-10s " "$ext" "$version"
        echo -e "$status"
        printf "%-39s %s\n" "" "$image"
    done

    echo ""
}

# Build a single extension
build_extension() {
    local ext_name="$1"
    local config_file="$2"
    local pg_major="$3"
    local container_dir="$4"

    local version
    version=$(ext_config "$ext_name" "version" "$config_file")
    local repo
    repo=$(ext_config "$ext_name" "repo" "$config_file")

    local dockerfile="$container_dir/extensions/build/${ext_name}.Dockerfile"
    local context_dir="$container_dir/extensions"

    # Check if Dockerfile exists
    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not found: $dockerfile"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would build $ext_name $version for PG $pg_major"
        return 0
    fi

    # Build the image
    build_ext_image "$ext_name" "$version" "$repo" "$pg_major" "$dockerfile" "$context_dir"
}

# Push extension to registry
push_extension() {
    local ext_name="$1"
    local config_file="$2"
    local pg_major="$3"

    local version
    version=$(ext_config "$ext_name" "version" "$config_file")

    if [[ "$DRY_RUN" == "true" ]]; then
        local image
        image=$(ext_image_name "$ext_name" "$version" "$pg_major")
        log_info "[DRY-RUN] Would push $image"
        return 0
    fi

    push_ext_image "$ext_name" "$version" "$pg_major"
}

# Main
main() {
    parse_args "$@"

    # Validate container exists
    local container_dir="$ROOT_DIR/$CONTAINER"
    local config_file="$container_dir/extensions/config.yaml"

    if [[ ! -d "$container_dir" ]]; then
        log_error "Container directory not found: $container_dir"
        exit 1
    fi

    if [[ ! -f "$config_file" ]]; then
        log_error "Extension config not found: $config_file"
        exit 1
    fi

    # Check yq is available
    if ! command -v yq &>/dev/null; then
        log_error "yq is required for YAML parsing. Install with: brew install yq"
        exit 1
    fi

    # Detect PG version
    local pg_major
    pg_major=$(detect_pg_version)
    log_info "PostgreSQL major version: $pg_major"

    # Handle list mode
    if [[ "$LIST_ONLY" == "true" ]]; then
        list_extension_status "$config_file" "$pg_major"
        exit 0
    fi

    # Check registry auth (unless local-only or dry-run)
    if [[ "$LOCAL_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        check_registry_auth || log_warn "Continuing without registry auth check"
    fi

    # Build mode - determine which extensions to build
    local extensions_to_build=()

    if [[ -n "$EXTENSION" ]]; then
        # Build specific extension
        extensions_to_build=("$EXTENSION")
    else
        # Build all missing extensions
        for ext in $(list_extensions_by_priority "$config_file"); do
            local dockerfile="$container_dir/extensions/build/${ext}.Dockerfile"

            # Skip extensions without Dockerfile (marked as complex or not yet implemented)
            if [[ ! -f "$dockerfile" ]]; then
                log_warn "$ext: no Dockerfile (skipped)"
                continue
            fi

            local version
            version=$(ext_config "$ext" "version" "$config_file")
            local image
            image=$(ext_image_name "$ext" "$version" "$pg_major")

            if [[ "$FORCE" == "true" ]]; then
                extensions_to_build+=("$ext")
            elif ! image_exists_in_registry "$image" 2>/dev/null; then
                extensions_to_build+=("$ext")
            else
                log_ok "$ext $version already exists in registry"
            fi
        done
    fi

    if [[ ${#extensions_to_build[@]} -eq 0 ]]; then
        log_ok "All extensions are up to date"
        exit 0
    fi

    log_info "Extensions to build: ${extensions_to_build[*]}"

    # Build and push each extension
    local failed=()
    for ext in "${extensions_to_build[@]}"; do
        echo ""
        log_info "Processing: $ext"

        if build_extension "$ext" "$config_file" "$pg_major" "$container_dir"; then
            if [[ "$LOCAL_ONLY" == "true" ]]; then
                log_ok "$ext built locally"
            elif push_extension "$ext" "$config_file" "$pg_major"; then
                log_ok "$ext completed successfully"
            else
                log_error "$ext push failed"
                failed+=("$ext")
            fi
        else
            log_error "$ext build failed"
            failed+=("$ext")
        fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed extensions: ${failed[*]}"
        exit 1
    else
        if [[ "$LOCAL_ONLY" == "true" ]]; then
            log_ok "All extensions built locally"
        else
            log_ok "All extensions built and pushed successfully"
        fi
    fi
}

main "$@"
