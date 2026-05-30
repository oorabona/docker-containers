#!/bin/bash
# Build and push extension images for containers with compiled extensions
# Images are pushed to registry (ghcr.io) for use with COPY --from=
#
# Usage:
#   ./scripts/build-extensions.sh <container> [options]
#
# Examples:
#   ./scripts/build-extensions.sh postgres                       # Build & push all missing
#   ./scripts/build-extensions.sh postgres --major-version 17    # Build for specific version
#   ./scripts/build-extensions.sh postgres --extension pgvector  # Build specific extension
#   ./scripts/build-extensions.sh postgres --force               # Rebuild even if exists
#   ./scripts/build-extensions.sh postgres --list                # List status of all extensions
#   ./scripts/build-extensions.sh postgres --local-only          # Build locally without pushing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../helpers/extension-utils.sh
source "$ROOT_DIR/helpers/extension-utils.sh"
# shellcheck source=../helpers/version-set-resolver.sh
source "$ROOT_DIR/helpers/version-set-resolver.sh"

# Registry override: default to docker.io (raw builds); CI passes ghcr.io/oorabona.
# Must NOT appear in config.yaml build_args (schema guard R7 rejects it).
REMOTE_CR="${REMOTE_CR:-docker.io}"

# Override build_ext_image from extension-utils.sh to inject --build-arg REMOTE_CR.
# This ensures the trusted CI registry root reaches extension builder stages.
build_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local ext_repo="$3"
    local pg_major="$4"
    local dockerfile="$5"
    local context_dir="$6"

    local local_tag
    local_tag=$(ext_local_image_name "$ext_name" "$pg_major")

    log_info "Building $ext_name $ext_version for PostgreSQL $pg_major (REMOTE_CR=${REMOTE_CR})"

    $DOCKER build \
        -f "$dockerfile" \
        -t "$local_tag" \
        --build-arg REMOTE_CR="${REMOTE_CR}" \
        --build-arg MAJOR_VERSION="$pg_major" \
        --build-arg EXT_VERSION="$ext_version" \
        --build-arg EXT_REPO="$ext_repo" \
        "$context_dir"

    log_success "Built: $local_tag"
}

# Defaults
CONTAINER=""
MAJOR_VERSION=""
EXTENSION=""
FORCE=false
LIST_ONLY=false
LOCAL_ONLY=false
PULL_ONLY=false
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $(basename "$0") <container> [options]

Build and push extension images for containers with compiled extensions.
Images are pushed to registry for use with COPY --from= in Dockerfiles.

Arguments:
  container              Container name (e.g., postgres)

Options:
  --major-version VERSION   Major version (e.g., 17, 16)
                         Default: auto-detect from version.sh
  --extension NAME       Build only specific extension
  --force                Rebuild even if image already exists
  --list                 List extension status without building
  --local-only           Build locally without pushing to registry
  --pull-only            Pull images from registry (no build, no push)
  --dry-run              Show what would be done without executing
  -h, --help             Show this help

Environment:
  EXTENSION_REGISTRY     Registry URL (default: ghcr.io)

Examples:
  $(basename "$0") postgres                        # Build & push all missing
  $(basename "$0") postgres --major-version 17     # Build for version 17
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
            --major-version)
                MAJOR_VERSION="$2"
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
            --pull-only)
                PULL_ONLY=true
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

# Detect major version from version.sh
detect_major_version() {
    local container_dir="$ROOT_DIR/$CONTAINER"
    local version_script="$container_dir/version.sh"

    if [[ -n "$MAJOR_VERSION" ]]; then
        echo "$MAJOR_VERSION"
        return
    fi

    if [[ -x "$version_script" ]]; then
        local full_version
        full_version=$("$version_script" 2>/dev/null | head -1)
        # Extract major version (first number before dot or dash)
        echo "$full_version" | grep -oE '^[0-9]+' | head -1
    else
        log_error "Cannot detect version. Use --major-version or ensure version.sh exists."
        exit 1
    fi
}

# List extension status
list_extension_status() {
    local config_file="$1"
    local major_ver="$2"

    echo ""
    echo "Extension Status for $CONTAINER v$major_ver"
    echo "=========================================="
    echo ""

    printf "%-15s %-10s %-12s %s\n" "Extension" "Version" "Status" "Image"
    printf "%-15s %-10s %-12s %s\n" "---------" "-------" "------" "-----"

    for ext in $(list_extensions_by_priority "$config_file" "$major_ver"); do
        local version
        version=$(ext_config "$ext" "version" "$config_file")
        local image
        image=$(ext_image_name "$ext" "$version" "$major_ver")

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
# Args: ext_name config_file major_ver container_dir [ext_version]
# ext_version defaults to ext_config lookup when omitted (backward compat).
build_extension() {
    local ext_name="$1"
    local config_file="$2"
    local major_ver="$3"
    local container_dir="$4"
    local ext_version="${5:-}"

    if [[ -z "$ext_version" ]]; then
        ext_version=$(ext_config "$ext_name" "version" "$config_file")
    fi
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
        log_info "[DRY-RUN] Would build $ext_name $ext_version for $CONTAINER v$major_ver (REMOTE_CR=${REMOTE_CR})"
        log_info "[DRY-RUN]   --build-arg REMOTE_CR=${REMOTE_CR} --build-arg MAJOR_VERSION=$major_ver"
        return 0
    fi

    # Build the image
    build_ext_image "$ext_name" "$ext_version" "$repo" "$major_ver" "$dockerfile" "$context_dir"
}

# Tag extension with registry name (always needed for COPY --from= to work)
# Args: ext_name config_file major_ver [ext_version]
tag_extension() {
    local ext_name="$1"
    local config_file="$2"
    local major_ver="$3"
    local ext_version="${4:-}"

    if [[ -z "$ext_version" ]]; then
        ext_version=$(ext_config "$ext_name" "version" "$config_file")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        local image
        image=$(ext_image_name "$ext_name" "$ext_version" "$major_ver")
        log_info "[DRY-RUN] Would tag $image"
        return 0
    fi

    tag_ext_image "$ext_name" "$ext_version" "$major_ver"
}

# Push extension to registry
# Args: ext_name config_file major_ver [ext_version]
push_extension() {
    local ext_name="$1"
    local config_file="$2"
    local major_ver="$3"
    local ext_version="${4:-}"

    if [[ -z "$ext_version" ]]; then
        ext_version=$(ext_config "$ext_name" "version" "$config_file")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        local image
        image=$(ext_image_name "$ext_name" "$ext_version" "$major_ver")
        log_info "[DRY-RUN] Would push $image"
        return 0
    fi

    push_ext_image "$ext_name" "$ext_version" "$major_ver"
}

# Pull extension from registry
pull_extension() {
    local ext_name="$1"
    local config_file="$2"
    local major_ver="$3"

    local version
    version=$(ext_config "$ext_name" "version" "$config_file")

    if [[ "$DRY_RUN" == "true" ]]; then
        local image
        image=$(ext_image_name "$ext_name" "$version" "$major_ver")
        log_info "[DRY-RUN] Would pull $image"
        return 0
    fi

    pull_ext_image "$ext_name" "$version" "$major_ver"
}

# Main


# --- Helpers extracted from main() for readability ---

# Validate container dir, config, and yq are available. Exits on failure.
validate_prerequisites() {
    local container_dir="$ROOT_DIR/$CONTAINER"
    if [[ ! -d "$container_dir" ]]; then
        log_error "Container directory not found: $container_dir"
        exit 1
    fi
    if [[ ! -f "$container_dir/extensions/config.yaml" ]]; then
        log_error "Extension config not found: $container_dir/extensions/config.yaml"
        exit 1
    fi
    if ! command -v yq &>/dev/null; then
        log_error "yq is required for YAML parsing. Install with: brew install yq"
        exit 1
    fi
}

# Pull-only mode: pull extensions from registry, build missing ones locally.
# Exits 0 on success, 1 on failure.
handle_pull_only_mode() {
    local config_file="$1" major_ver="$2" container_dir="$3"

    log_info "Pull-only mode: pulling from registry, then building missing locally"

    local extensions_to_pull=()
    local extensions_to_build=()

    if [[ -n "$EXTENSION" ]]; then
        extensions_to_pull=("$EXTENSION")
    else
        while IFS= read -r ext; do
            local dockerfile="$container_dir/extensions/build/${ext}.Dockerfile"
            if [[ ! -f "$dockerfile" ]]; then
                log_warning "$ext: no Dockerfile (skipped)"
                continue
            fi
            extensions_to_pull+=("$ext")
        done < <(list_extensions_by_priority "$config_file" "$major_ver")
    fi

    for ext in "${extensions_to_pull[@]}"; do
        local version image
        version=$(ext_config "$ext" "version" "$config_file")
        image=$(ext_image_name "$ext" "$version" "$major_ver")

        if docker image inspect "$image" &>/dev/null && [[ "$FORCE" != "true" ]]; then
            log_success "$ext $version already exists locally"
            continue
        fi

        if pull_extension "$ext" "$config_file" "$major_ver" 2>/dev/null; then
            log_success "$ext $version pulled from registry"
        else
            log_warning "$ext $version not in registry, will build locally"
            extensions_to_build+=("$ext")
        fi
    done

    if [[ ${#extensions_to_build[@]} -eq 0 ]]; then
        log_success "All extensions pulled successfully"
        exit 0
    fi

    log_info "Extensions to build locally: ${extensions_to_build[*]}"
    build_tag_push_extensions "$config_file" "$major_ver" "$container_dir" "false" "${extensions_to_build[@]}"
}

# Build, tag, and optionally push a list of extensions. Exits 1 if any fail.
# Args: config_file major_ver container_dir push ext1 [ext2 ...]
build_tag_push_extensions() {
    local config_file="$1" major_ver="$2" container_dir="$3" do_push="$4"
    shift 4

    local failed=()
    for ext in "$@"; do
        echo ""
        log_info "Processing: $ext"

        local _ext_start=$SECONDS

        # Resolve ceiling (single configured version) and the full version set.
        # A non-zero return from _resolve_cached means the resolver script failed
        # (network/API/binary error) — NOT a no-resolver extension (which returns
        # exit 0 with a single-element array). Fail-closed: skip the build and
        # mark this extension as failed so the overall run exits non-zero (#558).
        local ceiling version_set_json
        ceiling=$(ext_config "$ext" "version" "$config_file")
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
            log_error "$ext: version-set resolver failed — skipping build"
            failed+=("$ext")
            continue
        fi

        local set_size
        set_size=$(echo "$version_set_json" | jq 'length')

        # Per-version tracking for the versionset artifact.
        local available_versions=()
        local excluded_entries=()

        # Inner loop over each version oldest→newest.
        local version
        while IFS= read -r version; do
            local ver_image
            ver_image=$(ext_image_name "$ext" "$version" "$major_ver")

            # Skip already-available versions.
            if ! _image_needs_build "$ver_image"; then
                if [[ "$LOCAL_ONLY" == "true" ]]; then
                    log_success "$ext $version already exists locally"
                else
                    log_success "$ext $version already exists in registry"
                fi
                available_versions+=("$version")
                continue
            fi

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would build $ext $version for $CONTAINER v$major_ver"
                available_versions+=("$version")
                continue
            fi

            # Attempt build → tag → push for this version.
            local build_ok=true
            if ! build_extension "$ext" "$config_file" "$major_ver" "$container_dir" "$version"; then
                build_ok=false
            fi

            if [[ "$build_ok" == "true" ]]; then
                if ! tag_extension "$ext" "$config_file" "$major_ver" "$version"; then
                    build_ok=false
                fi
            fi

            if [[ "$build_ok" == "true" ]] && [[ "$do_push" == "true" ]]; then
                if ! push_extension "$ext" "$config_file" "$major_ver" "$version"; then
                    build_ok=false
                fi
            fi

            if [[ "$build_ok" == "true" ]]; then
                log_success "$ext $version completed successfully"
                available_versions+=("$version")

                # Write per-version lineage file.
                local _ver_duration=$(( SECONDS - _ext_start ))
                local _ver_image
                _ver_image=$(ext_image_name "$ext" "$version" "$major_ver")
                local _ver_safe="${version//[^a-zA-Z0-9.-]/_}"
                local _ver_lineage_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-${_ver_safe}.json"
                mkdir -p "${ROOT_DIR}/.build-lineage"
                jq -nc \
                    --arg ext "$ext" \
                    --arg version "$version" \
                    --arg pg_major "$major_ver" \
                    --arg image "$_ver_image" \
                    --argjson duration "$_ver_duration" \
                    --arg built_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                    '{ext:$ext, version:$version, pg_major:$pg_major, image:$image, duration_seconds:$duration, built_at:$built_at}' \
                    > "$_ver_lineage_file"
                log_info "Extension lineage: $_ver_lineage_file (${_ver_duration}s)"
            else
                # Build/tag/push failed for this version.
                if [[ "$version" == "$ceiling" ]]; then
                    # Ceiling version MUST build — this is a fatal error.
                    log_error "$ext $version (ceiling) build failed"
                    failed+=("$ext@$version")
                else
                    # Older retained version — warn and continue (musl tolerance).
                    log_warning "$ext $version build failed (non-ceiling, skipping)"
                    excluded_entries+=("{\"version\":\"${version}\",\"reason\":\"build failed (musl)\"}")
                fi
            fi
        done < <(echo "$version_set_json" | jq -r '.[]')

        # Write versionset artifact only for multi-version (resolver-backed) extensions.
        if [[ "$set_size" -gt 1 ]]; then
            local _vs_lineage_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-versionset.json"
            mkdir -p "${ROOT_DIR}/.build-lineage"

            # Build JSON arrays for available and excluded.
            local available_json excluded_json resolved_json
            available_json=$(printf '%s\n' "${available_versions[@]+"${available_versions[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')
            excluded_json="[$(IFS=,; echo "${excluded_entries[*]+"${excluded_entries[*]}"}")]"
            resolved_json=$(echo "$version_set_json" | jq '.')

            jq -nc \
                --arg ext "$ext" \
                --arg pg_major "$major_ver" \
                --arg ceiling "$ceiling" \
                --argjson resolved "$resolved_json" \
                --argjson available "$available_json" \
                --argjson excluded "$excluded_json" \
                '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:$resolved, available:$available, excluded:$excluded}' \
                > "$_vs_lineage_file"
            log_info "Version-set lineage: $_vs_lineage_file"
        fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed extensions: ${failed[*]}"
        exit 1
    else
        if [[ "$do_push" == "true" ]]; then
            log_success "All extensions built and pushed successfully"
        else
            log_success "All extensions built locally"
        fi
    fi
}

# File-backed memoisation for resolve_version_set.
# In-memory variables cannot survive command-substitution subshells ($(...)), so
# each resolved JSON is written to a per-run temp directory keyed by
# "<ext>-<major>". The cache directory is created eagerly at source time so that
# every $(...) subshell inherits the path via the exported variable and reads from
# the same files. This guarantees resolve_version_set is invoked at most once per
# (ext, pg_major) across an entire run — both the pre-filter step inside
# _should_build_extension and the build loop inside build_tag_push_extensions see
# the same cached file.
_RESOLVER_CACHE_DIR="$(mktemp -d)"
export _RESOLVER_CACHE_DIR
# shellcheck disable=SC2064
trap "rm -rf \"${_RESOLVER_CACHE_DIR}\"" EXIT

_resolve_cached() {
    local ext="$1" major="$2"
    local cache_file="${_RESOLVER_CACHE_DIR}/${ext}-${major}.json"

    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    local result
    result=$(resolve_version_set "$ext" "$major") || return 1

    # Write atomically so a concurrent subshell never reads a partial file.
    local tmp_file
    tmp_file="$(mktemp "${_RESOLVER_CACHE_DIR}/${ext}-${major}.XXXXXX")"
    printf '%s' "$result" > "$tmp_file"
    mv "$tmp_file" "$cache_file"

    echo "$result"
}

# _image_needs_build <image>
# Returns 0 (build) or 1 (skip) for a single image tag based on LOCAL_ONLY,
# FORCE, docker inspect, and registry presence.
# NOTE: does NOT log the skip reason — callers that need logging do so themselves.
_image_needs_build() {
    local image="$1"

    if [[ "$LOCAL_ONLY" == "true" ]]; then
        if [[ "$FORCE" != "true" ]] && docker image inspect "$image" &>/dev/null; then
            return 1
        fi
        return 0
    fi

    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi

    if image_exists_in_registry "$image" 2>/dev/null; then
        return 1
    fi

    return 0
}

# Decide whether a given extension needs (re)building.
# Honors LOCAL_ONLY (image inspect), FORCE, and registry presence.
# Logs the skip reason itself so callers can stay terse.
# Returns 0 to build, 1 to skip.
# For extensions with a multi-version set, returns 0 if ANY version needs build.
_should_build_extension() {
    local ext="$1" config_file="$2" major_ver="$3" container_dir="$4"
    local dockerfile="$container_dir/extensions/build/${ext}.Dockerfile"

    if [[ ! -f "$dockerfile" ]]; then
        log_warning "$ext: no Dockerfile (skipped)"
        return 1
    fi

    local version image
    version=$(ext_config "$ext" "version" "$config_file")
    image=$(ext_image_name "$ext" "$version" "$major_ver")

    # Resolve the full version set (cached). A non-zero return from _resolve_cached
    # means the resolver script failed — NOT a no-resolver extension (which returns
    # exit 0). Propagate the failure so the caller can handle it as a hard error.
    local version_set_json
    if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
        log_error "$ext: version-set resolver failed in pre-filter check"
        return 2
    fi

    # Single-version path: preserve exact existing log strings for the 8-case tests.
    local set_size
    set_size=$(echo "$version_set_json" | jq 'length')

    if [[ "$set_size" -eq 1 ]]; then
        # Exactly the legacy path — same log strings as before.
        if [[ "$LOCAL_ONLY" == "true" ]]; then
            if [[ "$FORCE" != "true" ]] && docker image inspect "$image" &>/dev/null; then
                log_success "$ext $version already exists locally"
                return 1
            fi
            return 0
        fi

        if [[ "$FORCE" == "true" ]]; then
            return 0
        fi

        if image_exists_in_registry "$image" 2>/dev/null; then
            log_success "$ext $version already exists in registry"
            return 1
        fi

        return 0
    fi

    # Multi-version path: return 0 if any version in the set needs building.
    local ver
    while IFS= read -r ver; do
        local ver_image
        ver_image=$(ext_image_name "$ext" "$ver" "$major_ver")
        if _image_needs_build "$ver_image"; then
            return 0
        fi
    done < <(echo "$version_set_json" | jq -r '.[]')

    log_success "$ext all versions already available (skipping)"
    return 1
}

main() {
    parse_args "$@"

    validate_prerequisites

    local container_dir="$ROOT_DIR/$CONTAINER"
    local config_file="$container_dir/extensions/config.yaml"

    # Detect major version
    local major_ver
    major_ver=$(detect_major_version)
    log_info "$CONTAINER major version: $major_ver"

    # Handle list mode
    if [[ "$LIST_ONLY" == "true" ]]; then
        list_extension_status "$config_file" "$major_ver"
        exit 0
    fi

    # Check registry auth (unless local-only or dry-run)
    if [[ "$LOCAL_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        check_registry_auth || log_warning "Continuing without registry auth check"
    fi

    # Handle pull-only mode
    if [[ "$PULL_ONLY" == "true" ]]; then
        handle_pull_only_mode "$config_file" "$major_ver" "$container_dir"
        exit 0
    fi

    # Build mode - determine which extensions to build
    local extensions_to_build=()

    if [[ -n "$EXTENSION" ]]; then
        # Strict typo check: explicit --extension must have a real Dockerfile
        local _explicit_dockerfile="$container_dir/extensions/build/${EXTENSION}.Dockerfile"
        if [[ ! -f "$_explicit_dockerfile" ]]; then
            log_error "Extension '$EXTENSION': no Dockerfile at $_explicit_dockerfile"
            exit 1
        fi
        local _rc=0
        _should_build_extension "$EXTENSION" "$config_file" "$major_ver" "$container_dir" || _rc=$?
        case "$_rc" in
            0) extensions_to_build=("$EXTENSION") ;;
            1) : ;;
            *) log_error "$EXTENSION: version-set resolver failed — aborting (fail-closed)"; exit 1 ;;
        esac
    else
        while IFS= read -r ext; do
            local _rc=0
            _should_build_extension "$ext" "$config_file" "$major_ver" "$container_dir" || _rc=$?
            case "$_rc" in
                0) extensions_to_build+=("$ext") ;;
                1) : ;;
                *) log_error "$ext: version-set resolver failed — aborting (fail-closed)"; exit 1 ;;
            esac
        done < <(list_extensions_by_priority "$config_file" "$major_ver")
    fi

    if [[ ${#extensions_to_build[@]} -eq 0 ]]; then
        if [[ -n "$EXTENSION" ]]; then
            log_success "$EXTENSION already up to date"
        else
            log_success "All extensions are up to date"
        fi
        exit 0
    fi

    log_info "Extensions to build: ${extensions_to_build[*]}"

    # Determine push mode
    local do_push="true"
    [[ "$LOCAL_ONLY" == "true" ]] && do_push="false"

    build_tag_push_extensions "$config_file" "$major_ver" "$container_dir" "$do_push" "${extensions_to_build[@]}"
}

# Only run main when executed directly, not when sourced (e.g. by unit tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
