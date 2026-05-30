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

    if ! $DOCKER build \
        -f "$dockerfile" \
        -t "$local_tag" \
        --build-arg REMOTE_CR="${REMOTE_CR}" \
        --build-arg MAJOR_VERSION="$pg_major" \
        --build-arg EXT_VERSION="$ext_version" \
        --build-arg EXT_REPO="$ext_repo" \
        "$context_dir"; then
        log_error "Docker build failed for $ext_name $ext_version (pg${pg_major})"
        return 1
    fi

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
# For extensions backed by a version-set resolver, each resolved version is
# reported individually so that partial registry presence is visible.
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
        local ceiling version_set_json
        ceiling=$(ext_config "$ext" "version" "$config_file")

        # Resolve the full version set (cached). On resolver failure degrade
        # to the single ceiling so --list is never blocked by upstream outage.
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
            log_warning "$ext: version-set resolver failed — showing ceiling only (LOCAL_ONLY)"
            version_set_json="[\"${ceiling}\"]"
        fi

        local ver
        while IFS= read -r ver; do
            local image
            image=$(ext_image_name "$ext" "$ver" "$major_ver")

            local status
            if image_exists_in_registry "$image" 2>/dev/null; then
                status="${GREEN}✓ exists${NC}"
            else
                status="${YELLOW}✗ missing${NC}"
            fi

            printf "%-15s %-10s " "$ext" "$ver"
            echo -e "$status"
            printf "%-39s %s\n" "" "$image"
        done < <(echo "$version_set_json" | jq -r '.[]')
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
# Args: ext_name config_file major_ver [ext_version]
# ext_version defaults to ext_config lookup when omitted (backward compat).
pull_extension() {
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
        log_info "[DRY-RUN] Would pull $image"
        return 0
    fi

    pull_ext_image "$ext_name" "$ext_version" "$major_ver"
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
# For version-set extensions, every resolved version is pulled/built individually.
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
        local ceiling version_set_json
        ceiling=$(ext_config "$ext" "version" "$config_file")

        # Resolve the full version set. On failure, degrade to ceiling on either
        # the local recovery path (LOCAL_ONLY=true) or the pull-only recovery path
        # (PULL_ONLY=true), where a transient resolver outage must not block a
        # local image fetch. Keep fail-closed for the true publish path (neither
        # flag set).
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
            if [[ "$LOCAL_ONLY" == "true" || "$PULL_ONLY" == "true" ]]; then
                log_warning "$ext: version-set resolver failed — degrading to ceiling $ceiling (recovery path)"
                version_set_json="[\"${ceiling}\"]"
            else
                log_error "$ext: version-set resolver failed — aborting pull-only (fail-closed)"
                exit 1
            fi
        fi

        local ver
        while IFS= read -r ver; do
            local image
            image=$(ext_image_name "$ext" "$ver" "$major_ver")

            if docker image inspect "$image" &>/dev/null && [[ "$FORCE" != "true" ]]; then
                log_success "$ext $ver already exists locally"
                continue
            fi

            if pull_extension "$ext" "$config_file" "$major_ver" "$ver" 2>/dev/null; then
                log_success "$ext $ver pulled from registry"
            else
                log_warning "$ext $ver not in registry, will build locally"
                extensions_to_build+=("${ext}@${ver}")
            fi
        done < <(echo "$version_set_json" | jq -r '.[]')
    done

    if [[ ${#extensions_to_build[@]} -eq 0 ]]; then
        log_success "All extensions pulled successfully"
        return 0
    fi

    # Deduplicate to extension names; build_tag_push_extensions will skip any
    # version already present locally (via _image_needs_build with LOCAL_ONLY=true).
    local -A _seen_exts=()
    local unique_exts_to_build=()
    for ext_ver in "${extensions_to_build[@]}"; do
        local ext="${ext_ver%%@*}"
        if [[ -z "${_seen_exts[$ext]:-}" ]]; then
            _seen_exts[$ext]=1
            unique_exts_to_build+=("$ext")
        fi
    done

    log_info "Extensions to build locally: ${unique_exts_to_build[*]}"
    # Build with LOCAL_ONLY semantics (do_push=false) so only locally absent
    # versions are built — pulled versions already in docker are skipped.
    LOCAL_ONLY=true build_tag_push_extensions "$config_file" "$major_ver" "$container_dir" "false" "${unique_exts_to_build[@]}"
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

        # Resolve ceiling (single configured version) and the full version set.
        # A non-zero return from _resolve_cached means the resolver script failed
        # (network/API/binary error) — NOT a no-resolver extension (which returns
        # exit 0 with a single-element array). On the publish/CI path, fail-closed:
        # mark the extension failed so the run exits non-zero. On the local
        # recovery path (LOCAL_ONLY=true), degrade to the ceiling version so a
        # transient upstream outage never blocks a manual rebuild.
        local ceiling version_set_json
        ceiling=$(ext_config "$ext" "version" "$config_file")
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
            if [[ "$LOCAL_ONLY" == "true" ]]; then
                log_warning "$ext: version-set resolver failed — degrading to ceiling $ceiling (LOCAL_ONLY)"
                version_set_json="[\"$ceiling\"]"
            else
                log_error "$ext: version-set resolver failed — skipping build"
                failed+=("$ext")
                continue
            fi
        fi

        local set_size
        set_size=$(echo "$version_set_json" | jq 'length')

        # Remove stale per-version duration lineage files from any previous run
        # so only this run's files survive for sum_flavor_extension_durations.
        # _cleanup_stale_duration_files is a no-op under DRY_RUN.
        _cleanup_stale_duration_files "$ext" "$major_ver"

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
                continue
            fi

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would build $ext $version for $CONTAINER v$major_ver"
                continue
            fi

            # Capture a fresh start time for this version so each lineage file
            # records only that version's own build time (#558).
            local _ver_start=$SECONDS

            # Attempt build for this version.
            local compile_ok=true
            if ! build_extension "$ext" "$config_file" "$major_ver" "$container_dir" "$version"; then
                compile_ok=false
            fi

            if [[ "$compile_ok" == "false" ]]; then
                # Compile failure: ceiling is fatal; non-ceiling is tolerated (musl compat).
                if [[ "$version" == "$ceiling" ]]; then
                    log_error "$ext $version (ceiling) build failed"
                    failed+=("$ext@$version")
                else
                    log_warning "$ext $version build failed (non-ceiling, skipping)"
                fi
                continue
            fi

            # Tag failure is always fatal — it is a registry/infra error, not musl.
            if ! tag_extension "$ext" "$config_file" "$major_ver" "$version"; then
                log_error "$ext $version tag failed (infra error)"
                failed+=("$ext@$version")
                continue
            fi

            # Push failure is always fatal.
            if [[ "$do_push" == "true" ]]; then
                if ! push_extension "$ext" "$config_file" "$major_ver" "$version"; then
                    log_error "$ext $version push failed"
                    failed+=("$ext@$version")
                    continue
                fi
            fi

            log_success "$ext $version completed successfully"

            # Record this version as built-this-run so _emit_versionset_artifact
            # can union it with the registry probe (guards against GHCR lag).
            if [[ "$DRY_RUN" != "true" ]]; then
                printf '%s\n' "$version" >> "${_BUILT_THIS_RUN_DIR}/${ext}-${major_ver}"
            fi

            # Write per-version lineage file with this version's own duration.
            # Dry runs must not mutate .build-lineage.
            if [[ "$DRY_RUN" != "true" ]]; then
                local _ver_duration=$(( SECONDS - _ver_start ))
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
            fi
        done < <(echo "$version_set_json" | jq -r '.[]')

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
# "<ext>-<major>". The cache directory is created at source time so that every
# $(...) subshell inherits the path via the exported variable. The EXIT trap
# that removes this directory is installed ONLY inside the execution guard
# below (when the script runs as a program), so sourcing this file never
# clobbers the caller's own EXIT trap.
_RESOLVER_CACHE_DIR="$(mktemp -d)"
export _RESOLVER_CACHE_DIR

# Per-run tracking of successfully built+pushed versions to guard against
# GHCR/Docker Hub propagation lag: a version whose push succeeded this run
# is counted available regardless of what the post-push registry probe sees.
# File layout: ${_BUILT_THIS_RUN_DIR}/<ext>-<major>  (one version per line)
# Only versions that completed build + tag + push (do_push=true) or
# build + tag (LOCAL_ONLY=true) without error are recorded.
_BUILT_THIS_RUN_DIR="$(mktemp -d)"
export _BUILT_THIS_RUN_DIR

_resolve_cached() {
    local ext="$1" major="$2"
    local cache_file="${_RESOLVER_CACHE_DIR}/${ext}-${major}.json"

    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    local result
    result=$(resolve_version_set "$ext" "$major") || return 1

    # Validate: must be a non-empty JSON array where every element is a string.
    # If the resolver exits 0 but emits malformed output or an empty array,
    # treat it as a resolver failure (fail-closed) and do NOT cache the bad value.
    if ! echo "$result" | jq -e 'type == "array" and length > 0 and (all(.[]; type == "string"))' > /dev/null 2>&1; then
        log_error "resolver for $ext returned invalid version set (not a non-empty string array): $result"
        return 1
    fi

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

# _image_present <image>
# Pure presence check — answers "does this image exist where the consumer will
# read it", FORCE-INDEPENDENT.
#
# Decision table (checked in order):
#   LOCAL_ONLY=true  OR  PULL_ONLY=true  → docker image inspect  (local store)
#   else (push/CI path)                  → image_exists_in_registry
#
# Used exclusively by _emit_versionset_artifact so that FORCE=true rebuilds and
# pull-only local-build fallbacks are reflected correctly in the artifact's
# available/excluded split.  The build-decision path (_image_needs_build) is
# left unchanged because FORCE must still bypass the skip-existing check there.
_image_present() {
    local image="$1"

    if [[ "$LOCAL_ONLY" == "true" || "$PULL_ONLY" == "true" ]]; then
        docker image inspect "$image" &>/dev/null
        return $?
    fi

    image_exists_in_registry "$image" 2>/dev/null
    return $?
}

# _image_present_3state <image>
# 3-state presence probe for versionset availability computation ONLY.
# Returns:
#   0  PRESENT          — image confirmed in registry / local store
#   1  ABSENT           — definitively absent (explicit not-found signal from registry:
#                         "manifest unknown", "not found", "name unknown", "404", etc.;
#                         or local inspect returned 1 in LOCAL_ONLY/PULL_ONLY mode)
#   2  ERROR            — probe failed ambiguously (toomanyrequests, denied, unauthorized,
#                         no such host, network unreachable, EOF, context deadline, empty
#                         stderr, etc.) — caller must treat as unknown (fail-closed)
#
# Decision table (same routing as _image_present):
#   LOCAL_ONLY=true  OR  PULL_ONLY=true  → docker image inspect  (2-state: 0/1 only)
#   else (push/CI path)                  → image_exists_in_registry fast-path (PRESENT if rc=0),
#                                          then docker manifest inspect with stderr capture:
#                                            explicit not-found signal → ABSENT (rc=1)
#                                            everything else non-zero → ERROR (rc=2, fail-closed)
#
# POLARITY: fail-closed (default ERROR).
# ABSENT requires a POSITIVE explicit not-found signal; everything else → ERROR.
# This prevents transient/ambiguous failures from silently dropping retained versions.
#
# The image_exists_in_registry fast-path is intentional:
#   1. Existing tests mock image_exists_in_registry as the PRESENT oracle; this preserves that contract.
#   2. Happy path (PRESENT) avoids a second probe.
#   3. Only on non-present results does the stderr-capturing probe run to classify the failure.
#
# NOT a replacement for _image_present for any other callers.
# image_exists_in_registry's boolean contract is unchanged.
_image_present_3state() {
    local image="$1"

    # Local-store path: docker image inspect is 2-state (present / not present).
    # A missing local image is always definitive-absent, not an error.
    if [[ "$LOCAL_ONLY" == "true" || "$PULL_ONLY" == "true" ]]; then
        if docker image inspect "$image" &>/dev/null; then
            return 0  # PRESENT
        fi
        return 1      # ABSENT (definitively — local store is authoritative)
    fi

    # Registry fast-path: if image_exists_in_registry confirms present, return PRESENT.
    # This preserves the established mock surface for existing tests (which mock
    # image_exists_in_registry as the presence oracle).
    if image_exists_in_registry "$image" 2>/dev/null; then
        return 0  # PRESENT
    fi

    # image_exists_in_registry returned non-zero (not confirmed present).
    # Run a stderr-capturing probe to distinguish ABSENT from transient ERROR.
    # rc=0 → PRESENT (image_exists_in_registry was a false negative, e.g. auth differences).
    # rc≠0 with an EXPLICIT not-found signal in stderr → ABSENT (rc=1).
    # rc≠0 with NO explicit not-found signal (including empty stderr, 429, denied,
    #   unauthorized, no such host, network errors, EOF, timeout, daemon errors) → ERROR (rc=2).
    #
    # POLARITY: fail-closed (default ERROR).
    # ABSENT requires a POSITIVE not-found signal; everything else is ERROR.
    # This prevents transient/ambiguous failures from silently dropping retained versions.
    local _probe_stderr
    local _probe_rc=0

    _probe_stderr=$(docker manifest inspect "$image" 2>&1 >/dev/null) || _probe_rc=$?
    if [[ "$_probe_rc" -eq 0 ]]; then
        return 0  # PRESENT
    fi

    # Explicit not-found allow-list: only these signals confirm definitive absence.
    # Matches the actual strings docker/skopeo emit for a genuinely-missing tag.
    if echo "$_probe_stderr" | grep -qiE \
        'manifest unknown|not found|name unknown|repository name not known|no such manifest|no such image|404'; then
        # docker returned a definitive not-found — check skopeo for a second opinion
        # only when available, to confirm and not flip to ERROR on a skopeo transient.
        if command -v skopeo &>/dev/null; then
            local _skopeo_stderr
            local _skopeo_rc=0
            _skopeo_stderr=$(skopeo inspect "docker://${image}" 2>&1 >/dev/null) || _skopeo_rc=$?
            if [[ "$_skopeo_rc" -eq 0 ]]; then
                return 0  # PRESENT (skopeo confirms presence despite docker not-found)
            fi
            # skopeo also returned non-zero; if skopeo's error is transient (not a
            # definitive not-found), escalate to ERROR to avoid discarding the version.
            if ! echo "$_skopeo_stderr" | grep -qiE \
                'manifest unknown|not found|name unknown|no such manifest|MANIFEST_UNKNOWN|404'; then
                return 2  # ERROR (docker said not-found but skopeo is ambiguous)
            fi
        fi
        return 1  # ABSENT (definitive not-found confirmed)
    fi

    # No explicit not-found signal → ambiguous/transient error (fail-closed).
    # Covers: toomanyrequests, denied, unauthorized, no such host, network unreachable,
    # EOF, context deadline exceeded, empty stderr, daemon errors, and anything else.
    return 2  # ERROR
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
    # exit 0). On the publish/CI path, propagate as a hard error (rc=2). On the
    # local recovery path (LOCAL_ONLY=true), degrade to the single ceiling version
    # so a transient upstream outage never blocks a manual rebuild.
    local version_set_json
    if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
        if [[ "$LOCAL_ONLY" == "true" ]]; then
            log_warning "$ext: version-set resolver failed — degrading to ceiling $version (LOCAL_ONLY)"
            version_set_json="[\"$version\"]"
        else
            log_error "$ext: version-set resolver failed in pre-filter check"
            return 2
        fi
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


# Remove stale per-version DURATION lineage files for a given (ext, pg_major).
# Must be called BEFORE build_tag_push_extensions writes new duration files so
# that only files from the current run survive.
#
# Scoped to ext-<ext>-pg<major>-<X.Y.Z>.json (semver-named per-version files).
# The versionset artifact (ext-<ext>-pg<major>-versionset.json) is NEVER deleted.
# Under DRY_RUN=true this function is a no-op.
#
# Args: ext major_ver
_cleanup_stale_duration_files() {
    local ext="$1" major_ver="$2"

    [[ "$DRY_RUN" == "true" ]] && return 0

    local _fp_lineage_dir="${ROOT_DIR}/.build-lineage"
    [[ -d "$_fp_lineage_dir" ]] || return 0

    local _fp_f
    for _fp_f in "${_fp_lineage_dir}/ext-${ext}-pg${major_ver}-"*.json; do
        [[ -f "$_fp_f" ]] || continue
        [[ "$_fp_f" == *"-versionset.json" ]] && continue
        rm -f "$_fp_f"
    done
}

# Emit (or refresh) versionset artifacts for resolver-backed extensions.
# This is the single source of truth for versionset artifacts — it runs before
# EVERY success exit in main() covering the all-up-to-date path, the normal
# build path, and the pull-only path.
#
# Scoping rule (DEFECT MM fix):
# - When $EXTENSION is set (scoped run) → emit ONLY for that extension (if it is
#   resolver-backed).  Do NOT resolve or touch any other extension.  A resolver
#   failure for the scoped extension stays fail-closed (you are building it);
#   an UNTARGETED extension is never resolved, so it cannot abort the run.
#   The consumer (generate_dockerfile) self-heals absent artifacts for untargeted
#   extensions by resolving + probing on demand.
# - When $EXTENSION is unset (full run) → iterate all resolver-backed extensions
#   from config (previous behavior).
#
# Only extensions with a resolver-backed multi-version set (set_size > 1) and an
# existing Dockerfile are emitted.
#
# Always (re)writes the artifact using a pure presence-based check (_image_present)
# so that FORCE=true rebuilds and pull-only local-build fallbacks are reflected
# correctly.  The file-existence guard is intentionally absent.
#
# Args: config_file major_ver container_dir [_ignored_single_ext]
#   The fourth argument is accepted for backward compatibility but ignored —
#   scoping is driven exclusively by the global $EXTENSION variable.
# Does nothing under DRY_RUN.
_emit_final_versionset_pass() {
    local config_file="$1" major_ver="$2" container_dir="$3"
    # $4 accepted for backward compatibility but unused.

    [[ "$DRY_RUN" == "true" ]] && return 0

    # Determine the extension list to iterate.
    # Scoped run: only the targeted extension; full run: all extensions from config.
    local ext_list
    if [[ -n "${EXTENSION:-}" ]]; then
        ext_list="$EXTENSION"
    else
        ext_list=$(list_extensions_by_priority "$config_file" "$major_ver")
    fi

    local ext
    local _final_pass_failed=false
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue
        # Skip extensions with no Dockerfile (already skipped by build logic)
        local dockerfile="$container_dir/extensions/build/${ext}.Dockerfile"
        [[ ! -f "$dockerfile" ]] && continue

        local ceiling version_set_json
        ceiling=$(ext_config "$ext" "version" "$config_file")

        # Use the cache — resolver was already called during the build/filter phase.
        # If not in cache yet (e.g. pull-only path or scoped run), resolve now.
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver"); then
            # Resolver failure in the final pass: distinguish publish vs recovery.
            # - Publish path (NOT LOCAL_ONLY and NOT PULL_ONLY): fail-closed —
            #   a required retention artifact cannot be produced; the run must
            #   exit non-zero so CI does not report success with a missing artifact.
            # - Recovery paths (LOCAL_ONLY=true or PULL_ONLY=true): degrade —
            #   a transient resolver outage must not block local recovery.
            if [[ "${LOCAL_ONLY:-false}" == "true" || "${PULL_ONLY:-false}" == "true" ]]; then
                log_warning "$ext: resolver unavailable in final pass — skipping versionset artifact (recovery path)"
            else
                log_error "$ext: resolver failed in final pass (publish path) — versionset artifact cannot be produced"
                _final_pass_failed=true
            fi
            continue
        fi

        local set_size
        set_size=$(echo "$version_set_json" | jq 'length')
        [[ "$set_size" -le 1 ]] && continue

        # Always (re)write — no file-existence guard. This ensures a stale artifact
        # from a prior run is refreshed even when no build occurs in the current run.
        # Propagate non-zero return: _emit_versionset_artifact returns non-zero when a
        # probe error (transient failure) prevents safe artifact emission (fail-closed).
        local _eva_rc=0
        _emit_versionset_artifact "$ext" "$config_file" "$major_ver" "$version_set_json" "$ceiling" || _eva_rc=$?
        if [[ "$_eva_rc" -ne 0 ]]; then
            _final_pass_failed=true
        fi
    done <<< "$ext_list"

    if [[ "$_final_pass_failed" == "true" ]]; then
        return 1
    fi
}

# Write (or refresh) the versionset artifact for a resolver-backed extension
# using a pure presence-based pass — no build occurs.
# Args: ext config_file major_ver version_set_json ceiling
# Does nothing under DRY_RUN or when set_size <= 1.
_emit_versionset_artifact() {
    local ext="$1" config_file="$2" major_ver="$3" version_set_json="$4" ceiling="$5"

    [[ "$DRY_RUN" == "true" ]] && return 0

    local set_size
    set_size=$(echo "$version_set_json" | jq 'length')
    [[ "$set_size" -le 1 ]] && return 0

    local available_versions=()
    local excluded_entries=()
    local ver

    # Load built-this-run set for this (ext, major_ver) to union with the probe.
    # Guards against GHCR/Docker Hub propagation lag: a version whose push succeeded
    # this run is counted available even if the registry probe returns absent.
    # Musl-failed versions are never recorded here (they never reach the
    # built-this-run write in build_tag_push_extensions).
    local _built_this_run_file="${_BUILT_THIS_RUN_DIR:-/dev/null}/${ext}-${major_ver}"
    local -A _built_this_run_set=()
    if [[ -f "$_built_this_run_file" ]]; then
        while IFS= read -r _btr_ver; do
            [[ -n "$_btr_ver" ]] && _built_this_run_set["$_btr_ver"]=1
        done < "$_built_this_run_file"
    fi

    local _probe_error=false
    while IFS= read -r ver; do
        local ver_image
        ver_image=$(ext_image_name "$ext" "$ver" "$major_ver")

        # Use 3-state probe to distinguish PRESENT / ABSENT / ERROR.
        # Versions in the built-this-run set are always PRESENT (propagation-lag guard).
        if [[ -n "${_built_this_run_set[$ver]:-}" ]]; then
            available_versions+=("$ver")
        else
            local _probe_rc=0
            _image_present_3state "$ver_image" || _probe_rc=$?
            case "$_probe_rc" in
                0)  # PRESENT
                    available_versions+=("$ver")
                    ;;
                1)  # ABSENT (definitive) — legitimate musl-failed / never-built
                    excluded_entries+=("{\"version\":\"${ver}\",\"reason\":\"not available\"}")
                    ;;
                *)  # ERROR (transient probe failure) — fail closed
                    log_error "$ext: registry probe for $ver (pg${major_ver}) returned an ambiguous error — cannot determine availability; versionset artifact suppressed (fail-closed)"
                    _probe_error=true
                    ;;
            esac
        fi
    done < <(echo "$version_set_json" | jq -r '.[]')

    # Fail closed: if any probe returned ERROR, do not write a potentially-incomplete artifact.
    # A transient network blip must never silently drop a previously-published retained version.
    if [[ "$_probe_error" == "true" ]]; then
        return 1
    fi

    # Gate: only write the artifact when it is USEFUL.
    # An artifact is useful iff available is non-empty AND contains the ceiling.
    # An empty available[] or a ceiling-absent artifact misleads the consumer:
    # it may reference ext-<ext>:pg<major>-<ceiling> which doesn't exist, causing
    # the downstream postgres build to fail. With no artifact, the consumer's
    # self-heal path runs (resolve + probe) and correctly fails closed.
    local _ceiling_in_available=false
    local _av
    for _av in "${available_versions[@]+"${available_versions[@]}"}"; do
        if [[ "$_av" == "$ceiling" ]]; then
            _ceiling_in_available=true
            break
        fi
    done

    if [[ ${#available_versions[@]} -eq 0 ]] || [[ "$_ceiling_in_available" == "false" ]]; then
        log_info "$ext: skipping versionset artifact — available is empty or ceiling ($ceiling) not present"
        return 0
    fi

    local _vs_lineage_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-versionset.json"
    mkdir -p "${ROOT_DIR}/.build-lineage"

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
    log_info "Version-set lineage (presence-based): $_vs_lineage_file"
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

    # Handle pull-only mode — returns 0 on success, propagates exit 1 from
    # build_tag_push_extensions on failure. The final versionset pass runs
    # after the return so every pull-only success path has artifacts too.
    if [[ "$PULL_ONLY" == "true" ]]; then
        handle_pull_only_mode "$config_file" "$major_ver" "$container_dir"
        local _fp_rc=0
        _emit_final_versionset_pass "$config_file" "$major_ver" "$container_dir" "${EXTENSION:-}" || _fp_rc=$?
        exit "$_fp_rc"
    fi

    # Build mode — determine which extensions to build.
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
        # Pre-clean stale per-version duration files before the final versionset pass.
        # On an all-cached run build_tag_push_extensions is never called, so the
        # cleanup that lives at the top of that function never runs — do it here instead.
        # This ensures sum_flavor_extension_durations sees 0 (no new builds),
        # not stale durations from a previous run.
        #
        # Scoping rule: when $EXTENSION is set (scoped run), only clean that
        # extension's duration files.  Cleaning other extensions' files on a
        # scoped run would destroy duration data written by an earlier scoped
        # invocation in the same job (before artifact upload) and cause
        # sum_flavor_extension_durations to under-report (DEFECT KK).
        if [[ -n "$EXTENSION" ]]; then
            _cleanup_stale_duration_files "$EXTENSION" "$major_ver"
        else
            local _pre_clean_ext
            while IFS= read -r _pre_clean_ext; do
                [[ -z "$_pre_clean_ext" ]] && continue
                _cleanup_stale_duration_files "$_pre_clean_ext" "$major_ver"
            done < <(list_extensions_by_priority "$config_file" "$major_ver")
        fi

        # Final pass: emit presence-based versionset artifacts for all in-scope
        # resolver-backed extensions (resolver results are already cached from
        # the _should_build_extension calls above).
        local _fp_rc=0
        _emit_final_versionset_pass "$config_file" "$major_ver" "$container_dir" "${EXTENSION:-}" || _fp_rc=$?
        exit "$_fp_rc"
    fi

    log_info "Extensions to build: ${extensions_to_build[*]}"

    # Determine push mode
    local do_push="true"
    [[ "$LOCAL_ONLY" == "true" ]] && do_push="false"

    # Mixed run: clean stale per-version duration files for all resolver-backed
    # extensions that are in-scope but NOT in extensions_to_build (all-cached).
    # build_tag_push_extensions runs its own cleanup for extensions it processes,
    # but cached extensions are never passed to it — their stale files would
    # survive and inflate sum_flavor_extension_durations (DEFECT QQ).
    # Scoping rule: only when $EXTENSION is unset (full run). A scoped run only
    # has one extension in scope; if it needs building it goes to build_tag_push;
    # if it's cached the all-cached branch above handles it.
    if [[ -z "${EXTENSION:-}" ]]; then
        # Build a set of extensions that WILL be cleaned by build_tag_push_extensions.
        local -A _btpe_set=()
        for _btpe_ext in "${extensions_to_build[@]}"; do
            _btpe_set["$_btpe_ext"]=1
        done
        local _mixed_clean_ext
        while IFS= read -r _mixed_clean_ext; do
            [[ -z "$_mixed_clean_ext" ]] && continue
            # Skip extensions that will be cleaned inside build_tag_push_extensions.
            [[ -n "${_btpe_set[$_mixed_clean_ext]:-}" ]] && continue
            _cleanup_stale_duration_files "$_mixed_clean_ext" "$major_ver"
        done < <(list_extensions_by_priority "$config_file" "$major_ver")
    fi

    build_tag_push_extensions "$config_file" "$major_ver" "$container_dir" "$do_push" "${extensions_to_build[@]}"

    # Final pass: emit presence-based versionset artifacts for ALL in-scope
    # resolver-backed extensions — including those that were skipped by
    # build_tag_push_extensions (already cached) and those just built.
    # This is the single source of truth for skipped extensions on mixed runs.
    # Resolver results are already cached from _should_build_extension calls above.
    local _fp_rc=0
    _emit_final_versionset_pass "$config_file" "$major_ver" "$container_dir" "${EXTENSION:-}" || _fp_rc=$?
    if [[ "$_fp_rc" -ne 0 ]]; then
        exit "$_fp_rc"
    fi
}

# Only run main when executed directly, not when sourced (e.g. by unit tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Install EXIT cleanup only when executing as a program. When sourced (e.g.
    # by unit tests) no trap is installed here so the caller's EXIT trap is
    # never clobbered. _RESOLVER_CACHE_DIR is already set at source time above.
    # shellcheck disable=SC2064
    trap "rm -rf \"${_RESOLVER_CACHE_DIR}\" \"${_BUILT_THIS_RUN_DIR}\"" EXIT
    main "$@"
fi
