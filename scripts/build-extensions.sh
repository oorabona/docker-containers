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

# _arch_suffix_tag <base_ref> <suffix>
# Appends -${suffix} to <base_ref> when <suffix> is non-empty; returns <base_ref> unchanged
# when <suffix> is empty. Used uniformly by per-version and bundle tagging so the CI
# per-arch leg and the local/unsuffixed leg use exactly the same logic.
#
# Examples:
#   _arch_suffix_tag "ghcr.io/owner/ext-ts:pg18-bundle"  "amd64"  => "ghcr.io/owner/ext-ts:pg18-bundle-amd64"
#   _arch_suffix_tag "ghcr.io/owner/ext-ts:pg18-bundle"  ""        => "ghcr.io/owner/ext-ts:pg18-bundle"
_arch_suffix_tag() {
    local base="$1" suffix="${2:-}"
    if [[ -n "$suffix" ]]; then
        printf '%s-%s' "$base" "$suffix"
    else
        printf '%s' "$base"
    fi
}

# _scoped_tag <base_ref>
# Appends ${PR_TAG_SUFFIX} to <base_ref> when PR_TAG_SUFFIX is non-empty;
# returns <base_ref> unchanged when PR_TAG_SUFFIX is empty (push/dispatch path).
#
# BD-1 supply-chain policy (operator-confirmed option 2): image tags AND the
# registry build-cache are both PR-scoped.  On a same-repo pull_request, the
# build-extensions leg publishes per-arch images and the stage-B merge publishes
# multi-arch manifests and the bundle — all carrying the -pr<N> suffix.
# The build-cache ref also carries the PR suffix (see BD-1 comment in
# build_ext_image) so an unmerged PR cannot influence master's canonical build
# via a shared cache entry.  Master recompiles the bumped version on merge;
# the prefilter skips already-canonical versions so only the newly bumped
# version recompiles — bounded, accepted waste.
# Forks are excluded at the job if: clause so only trusted same-repo PRs write
# to the GHCR namespace.
#
# Examples (PR_TAG_SUFFIX=-pr42):
#   _scoped_tag "ghcr.io/owner/ext-ts:pg18-2.27.1"  => "ghcr.io/owner/ext-ts:pg18-2.27.1-pr42"
#   _scoped_tag "ghcr.io/owner/ext-ts:pg18-bundle"   => "ghcr.io/owner/ext-ts:pg18-bundle-pr42"
# Examples (PR_TAG_SUFFIX empty — push/dispatch):
#   _scoped_tag "ghcr.io/owner/ext-ts:pg18-bundle"   => "ghcr.io/owner/ext-ts:pg18-bundle"
_scoped_tag() {
    local base="$1"
    if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
        printf '%s%s' "$base" "$PR_TAG_SUFFIX"
    else
        printf '%s' "$base"
    fi
}

# _resolve_existing_arch_ref <ext_name> <version> <pg_major> <arch>
# BF fix: on a PR (PR_TAG_SUFFIX non-empty), determine which ref to use for
# a given per-arch version tag via a canonical-first probe.
#
# Logic:
#   If PR_TAG_SUFFIX is empty (push/dispatch):
#     → return the canonical arch ref unchanged (no lookup needed).
#   If PR_TAG_SUFFIX is non-empty (PR context):
#     1. Probe the CANONICAL arch ref (no PR suffix):
#        <img>-<arch>  (e.g. :pg18-2.25.0-amd64)
#        If PRESENT → version is unchanged, reuse canonical; return canonical ref.
#     2. Probe the PR-scoped arch ref (with PR suffix):
#        <img>-<arch>${PR_TAG_SUFFIX}  (e.g. :pg18-2.27.1-amd64-pr42)
#        If PRESENT → version was built this PR; return PR-scoped ref.
#     3. Neither present → version needs building; return empty string.
#
# Supply-chain safety: reading canonical is read-only. PRs only WRITE PR-scoped refs.
# On push (empty suffix): canonical probe only (unchanged behavior).
#
# Returns: the ref string to use, or "" if neither canonical nor PR-scoped exists.
# Exit code: always 0 (callers check the returned string for emptiness).
_resolve_existing_arch_ref() {
    local ext_name="$1" version="$2" pg_major="$3" arch="${4:-}"
    local ver_image
    ver_image=$(ext_image_name "$ext_name" "$version" "$pg_major")
    local canonical_arch_ref
    canonical_arch_ref=$(_arch_suffix_tag "$ver_image" "$arch")

    if [[ -z "${PR_TAG_SUFFIX:-}" ]]; then
        # Push/dispatch: always return canonical (caller decides build-or-skip).
        printf '%s' "$canonical_arch_ref"
        return 0
    fi

    # PR context: check canonical first (read-only reuse for unchanged versions).
    if image_exists_in_registry "$canonical_arch_ref" 2>/dev/null; then
        printf '%s' "$canonical_arch_ref"
        return 0
    fi

    # Canonical absent: check PR-scoped (version built this PR).
    local pr_arch_ref
    pr_arch_ref=$(_scoped_tag "$canonical_arch_ref")
    if image_exists_in_registry "$pr_arch_ref" 2>/dev/null; then
        printf '%s' "$pr_arch_ref"
        return 0
    fi

    # Neither present → needs building.
    printf ''
    return 0
}

# Override build_ext_image from extension-utils.sh to inject --build-arg REMOTE_CR.
# This ensures the trusted CI registry root reaches extension builder stages.
# When BUILD_PLATFORM is set (CI per-arch leg), uses `docker buildx build --platform`
# to build for that single architecture; without BUILD_PLATFORM, falls back to
# plain `docker build` (host platform, local usage).
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

    if [[ -n "${BUILD_PLATFORM:-}" ]]; then
        # CI per-arch leg: build for the specific platform using buildx.
        # Build and push are intentionally SEPARATE steps so their failure modes
        # are distinguishable:
        #   - compile (--load) failure → rc=1 (musl incompatibility tolerated for
        #     non-ceiling versions by the caller).
        #   - push failure (infra/auth/network) → rc=2 (FATAL for ALL versions,
        #     ceiling AND non-ceiling, because it is not a compile incompatibility).
        #
        # BA-1: pushing extension images from same-repo PRs is a deliberate
        # accepted trade-off.  Extensions require native compilation (musl/glibc),
        # so rebuilding from scratch on the master merge leg would waste minutes of
        # compile time per version per arch.  A single-maintainer repo with
        # serialized auto-update PRs makes this safe: the trust boundary is the PR
        # author, and the push is scoped to extension sub-images only (not the
        # final consumer postgres image).  This diverges from the main-image
        # PR-skip policy intentionally.
        local _ver_image
        _ver_image=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")
        local _ver_tag
        # Per-arch tag carries both the arch suffix and the PR scope suffix (if any).
        # Format: <registry>/<owner>/ext-<name>:pg<major>-<ver>-<arch>${PR_TAG_SUFFIX}
        _ver_tag=$(_scoped_tag "$(_arch_suffix_tag "$_ver_image" "${ARCH_SUFFIX:-}")")

        # BC-2: cache ref must ALWAYS use a writable GHCR path, independent of
        # REMOTE_CR (which is the base-image source mirror, not the cache store).
        # When REMOTE_CR=docker.io (GHCR mirror absent fallback), the old derivation
        # produced docker.io/ext-...-buildcache — no owner namespace, not writable.
        # Fix: derive owner from REPO_OWNER (env, set by CI) or get_repo_owner()
        # and construct the cache ref as ghcr.io/<owner>/ext-<name>-buildcache:...
        #
        # BD-1 supply-chain policy (operator-confirmed): the cache ref is PR-scoped
        # by appending PR_TAG_SUFFIX so an unmerged PR cannot influence master's
        # canonical build via a shared cache entry.  On a same-repo PR the ref ends
        # in pg<N>-<arch>-pr<N>; on push/dispatch (master) PR_TAG_SUFFIX is empty
        # and the ref ends in pg<N>-<arch>.  There are no shared PR<->master refs.
        # Master recompiles the bumped version on merge; the prefilter skips
        # already-canonical versions so only the newly bumped version recompiles —
        # bounded, accepted waste relative to the supply-chain guarantee.
        local _cache_owner
        _cache_owner="${REPO_OWNER:-$(get_repo_owner)}"
        local _cache_ref
        _cache_ref="ghcr.io/${_cache_owner}/ext-${ext_name}-buildcache:pg${pg_major}-${ARCH_SUFFIX:-local}${PR_TAG_SUFFIX:-}"

        # Compute do_push for this build leg: true unless NO_PUSH or LOCAL_ONLY.
        local _do_push_ext=true
        [[ "${NO_PUSH:-false}" == "true" ]] && _do_push_ext=false
        [[ "${LOCAL_ONLY:-false}" == "true" ]] && _do_push_ext=false

        # Step 1: compile — always use --load (loads image into the local docker
        # store of the native runner).  rc=1 on failure (compile / musl error).
        # BD-1: the cache is PR-scoped (see comment above); --cache-from on a PR
        # reads ONLY that PR's own scoped cache across re-pushes.  On push/dispatch
        # (master) the ref has no suffix so master reads/writes only its own cache.
        # --cache-to writes when we have GHCR write access (_do_push_ext=true);
        # omitting --cache-to on LOCAL_ONLY/NO_PUSH paths avoids attempting writes
        # to a registry we cannot authenticate to in that context.
        # A cache-to write failure is non-fatal in buildx (the build itself
        # succeeds even if the cache upload fails), so no explicit error handling
        # is needed here.
        local _cache_flags=("--cache-from" "type=registry,ref=${_cache_ref}")
        if [[ "$_do_push_ext" == "true" ]]; then
            _cache_flags+=("--cache-to" "type=registry,ref=${_cache_ref},mode=max")
        fi

        if ! $DOCKER buildx build \
            --platform "${BUILD_PLATFORM}" \
            -f "$dockerfile" \
            -t "$_ver_tag" \
            --load \
            "${_cache_flags[@]}" \
            --build-arg REMOTE_CR="${REMOTE_CR}" \
            --build-arg MAJOR_VERSION="$pg_major" \
            --build-arg EXT_VERSION="$ext_version" \
            --build-arg EXT_REPO="$ext_repo" \
            "$context_dir"; then
            log_error "Docker buildx build (compile) failed for $ext_name $ext_version (pg${pg_major})"
            return 1  # compile failure
        fi

        if [[ "$_do_push_ext" == "false" ]]; then
            log_success "Built (local only): $_ver_tag (platform: ${BUILD_PLATFORM})"
            return 0
        fi

        # Step 2: push — separate from compile so push/auth/network failures are
        # distinct from musl compile incompatibilities.  rc=2 on failure (infra).
        if ! $DOCKER push "$_ver_tag"; then
            log_error "Docker push failed for $ext_name $ext_version (pg${pg_major}) — infra/auth/network error"
            return 2  # push failure (infra — FATAL for all versions, not just ceiling)
        fi

        log_success "Built+pushed: $_ver_tag (platform: ${BUILD_PLATFORM})"
        return 0
    fi

    # Local / host-platform build (ARCH_SUFFIX empty): original plain docker build.
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
FINALIZE_MULTIARCH=false

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
  --finalize-multiarch   Merge per-arch suffixed images into multi-arch manifests
                         and write the versionset artifact (stage B post-build step)
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
            --finalize-multiarch)
                FINALIZE_MULTIARCH=true
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
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver" "$config_file"); then
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

    # Retry loop for transient failures (network blips on FROM pull, apk add, git clone).
    # EXT_BUILD_RETRIES defaults to 3; set to a lower value in tests.
    # Persistent failures (real musl incompatibility, auth error) fail all attempts
    # and propagate the original rc so the caller can distinguish compile (rc=1)
    # from push (rc=2) failures. Retries reduce — but do not eliminate — the
    # transient-vs-incompatibility ambiguity: a version excluded after N persistent
    # failures is treated as a genuine build miss.
    local _max_attempts="${EXT_BUILD_RETRIES:-3}"
    local _attempt=0
    local _build_rc=0
    while [[ "$_attempt" -lt "$_max_attempts" ]]; do
        _attempt=$(( _attempt + 1 ))
        _build_rc=0
        build_ext_image "$ext_name" "$ext_version" "$repo" "$major_ver" "$dockerfile" "$context_dir" \
            || _build_rc=$?
        if [[ "$_build_rc" -eq 0 ]]; then
            return 0
        fi
        if [[ "$_attempt" -lt "$_max_attempts" ]]; then
            local _backoff=$(( _attempt * 3 ))
            log_warning "build_ext_image attempt $_attempt/$_max_attempts failed (rc=$_build_rc) for $ext_name $ext_version — retrying in ${_backoff}s"
            sleep "$_backoff"
        fi
    done
    log_error "build_ext_image failed after $_max_attempts attempt(s) (rc=$_build_rc) for $ext_name $ext_version — persistent failure"
    return "$_build_rc"
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
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver" "$config_file"); then
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

# Compute the confirmed_available set for (ext, major_ver) from version_set_json,
# push the bundle with that set, then write the versionset artifact from that SAME
# set. This is the single-assembly, atomic-ordering contract:
#   confirmed = { v in resolved : 3state(v)=PRESENT } UNION { v in built-this-run }
#   fail-closed: 3state ERROR, empty confirmed, or ceiling absent → fatal
#   bundle push THEN artifact write (never artifact without bundle)
#
# Args: ext config_file major_ver version_set_json ceiling do_push
#   do_push: "true" = push to registry; "false" = local-only build.
# Returns: 0 on success; 1 on any failure.
# Does nothing (returns 0) under DRY_RUN — callers handle DRY_RUN logging.
# When set_size <= 1: deletes any stale versionset artifact and returns 0
#   (no bundle needed for single-version; consumer self-heals to single-version path).
_bundle_and_write_artifact() {
    local ext="$1" config_file="$2" major_ver="$3" version_set_json="$4" ceiling="$5" do_push="$6"

    [[ "$DRY_RUN" == "true" ]] && return 0

    local set_size
    set_size=$(echo "$version_set_json" | jq 'length')
    if [[ "$set_size" -le 1 ]]; then
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 0
    fi

    # CI no-push guard: when do_push=false AND this is not a LOCAL_ONLY or PULL_ONLY
    # recovery path, we are in a fork PR / CI smoke context where the package registry
    # is read-only.  Neither a bundle push nor an artifact write is safe here — the
    # bundle was never pushed so any artifact would reference an unpushed (local-only)
    # bundle image, causing the downstream postgres build to fail.
    # Delete any stale artifact so the downstream consumer self-heals to per-version COPYs.
    # LOCAL_ONLY and PULL_ONLY callers pass do_push=false but still need a local bundle
    # and artifact for local consumption — they are NOT affected by this guard.
    if [[ "$do_push" != "true" ]] && \
       [[ "${LOCAL_ONLY:-false}" != "true" ]] && \
       [[ "${PULL_ONLY:-false}" != "true" ]]; then
        log_info "$ext: skipping bundle+artifact (CI no-push context — do_push=false)"
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 0
    fi

    # AV-2 double-bundle guard: record that this (ext, major_ver) bundle was assembled
    # on the BUILD PATH so _emit_final_versionset_pass can skip it (preventing the same
    # bundle from being assembled twice in a single run).
    # Sentinel file: ${_BUILT_THIS_RUN_DIR}/bundle-<ext>-<major_ver>
    # Written BEFORE the bundle assembly so the final pass never re-enters here for
    # the same key even if _bundle_and_write_artifact is called from the build path.
    local _bundle_sentinel="${_BUILT_THIS_RUN_DIR}/bundle-${ext}-${major_ver}"
    printf '1' > "$_bundle_sentinel"

    # Load built-this-run set so a version pushed this run is counted PRESENT
    # regardless of propagation lag (identical to _emit_versionset_artifact's guard).
    local _built_this_run_file="${_BUILT_THIS_RUN_DIR:-/dev/null}/${ext}-${major_ver}"
    local -A _btr_set=()
    if [[ -f "$_built_this_run_file" ]]; then
        while IFS= read -r _btr_ver; do
            [[ -n "$_btr_ver" ]] && _btr_set["$_btr_ver"]=1
        done < "$_built_this_run_file"
    fi

    # Single 3-state pass: compute confirmed_available from resolved set.
    local _confirmed_available=()
    local _excluded_entries=()
    local _probe_error=false
    local _cv
    while IFS= read -r _cv; do
        local _cv_image
        _cv_image=$(ext_image_name "$ext" "$_cv" "$major_ver")

        if [[ -n "${_btr_set[$_cv]:-}" ]]; then
            _confirmed_available+=("$_cv")
        else
            local _probe_rc=0
            _image_present_3state "$_cv_image" || _probe_rc=$?
            case "$_probe_rc" in
                0)
                    _confirmed_available+=("$_cv")
                    ;;
                1)
                    _excluded_entries+=("{\"version\":\"${_cv}\",\"reason\":\"not available\"}")
                    ;;
                *)
                    log_error "$ext: registry probe for $_cv (pg${major_ver}) returned ERROR — cannot determine availability; fail-closed"
                    _probe_error=true
                    ;;
            esac
        fi
    done < <(echo "$version_set_json" | jq -r '.[]')

    # Fail-closed: transient probe error → delete stale artifact, return non-zero.
    if [[ "$_probe_error" == "true" ]]; then
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 1
    fi

    # Gate: confirmed must be non-empty and must contain the ceiling.
    local _ceiling_in_confirmed=false
    local _ca
    for _ca in "${_confirmed_available[@]+"${_confirmed_available[@]}"}"; do
        if [[ "$_ca" == "$ceiling" ]]; then
            _ceiling_in_confirmed=true
            break
        fi
    done

    if [[ ${#_confirmed_available[@]} -eq 0 ]] || [[ "$_ceiling_in_confirmed" == "false" ]]; then
        log_info "$ext: confirmed_available is empty or ceiling ($ceiling) absent — deleting stale artifact, skipping bundle"
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 0
    fi

    # AO-1: if only one version is confirmed available (the ceiling only, non-ceiling
    # versions were musl-failed or absent), do NOT assemble a bundle — a 1-version
    # bundle is unused by the consumer (available_count <= 1 falls through to the
    # single-version path in generate_dockerfile).  A bundle push or digest-capture
    # failure on a 1-version bundle would fail CI for no benefit.
    # Delete any stale artifact so the consumer self-heals cleanly; return 0 (not fatal).
    if [[ ${#_confirmed_available[@]} -le 1 ]]; then
        log_info "$ext: only ${#_confirmed_available[@]} version(s) confirmed available — skipping bundle (consumer uses single-version path), deleting stale artifact"
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 0
    fi

    # Push the bundle from EXACTLY confirmed_available.
    local _ba_rc=0
    assemble_and_push_bundle "$ext" "$major_ver" "$do_push" "${_confirmed_available[@]}" || _ba_rc=$?
    if [[ "$_ba_rc" -ne 0 ]]; then
        log_error "$ext pg${major_ver}: bundle assembly/push failed — deleting stale artifact"
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 1
    fi

    # ARCH_SUFFIX defer: on a CI per-arch leg (ARCH_SUFFIX non-empty) the bundle was
    # pushed with a platform-suffixed tag (e.g. :pg18-bundle-amd64).  The multi-arch
    # manifest-merge step (stage B, NOT this change) will create the unsuffixed
    # :pg18-bundle index and write the final versionset artifact with the index digest.
    # Defer the artifact write here so stage B has a clean slate — no artifact from a
    # single-arch leg should pre-empt the multi-arch one.
    # We still delete any stale artifact so the consumer does not silently use old data.
    if [[ -n "${ARCH_SUFFIX:-}" ]]; then
        log_info "$ext pg${major_ver}: ARCH_SUFFIX=${ARCH_SUFFIX} — bundle pushed as suffixed ref; deferring versionset artifact to manifest-merge step"
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        unset _BUNDLE_DIGEST
        return 0
    fi

    # Bundle pushed successfully — NOW write the artifact from the SAME confirmed set.
    local _vs_lineage_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-versionset.json"
    mkdir -p "${ROOT_DIR}/.build-lineage"

    local _available_json _excluded_json _resolved_json
    _available_json=$(printf '%s\n' "${_confirmed_available[@]+"${_confirmed_available[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')
    _excluded_json="[$(IFS=,; echo "${_excluded_entries[*]+"${_excluded_entries[*]}"}")]"
    _resolved_json=$(echo "$version_set_json" | jq '.')

    # AM fix: include bundle_digest in the artifact when available (publish path).
    # _BUNDLE_DIGEST is set by assemble_and_push_bundle after a successful push.
    # On LOCAL_ONLY/no-push paths, _BUNDLE_DIGEST is unset or empty — omit the field.
    local _artifact_digest="${_BUNDLE_DIGEST:-}"
    unset _BUNDLE_DIGEST

    if [[ -n "$_artifact_digest" ]]; then
        jq -nc \
            --arg ext "$ext" \
            --arg pg_major "$major_ver" \
            --arg ceiling "$ceiling" \
            --argjson resolved "$_resolved_json" \
            --argjson available "$_available_json" \
            --argjson excluded "$_excluded_json" \
            --arg bundle_digest "$_artifact_digest" \
            '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:$resolved, available:$available, excluded:$excluded, bundle_digest:$bundle_digest}' \
            > "$_vs_lineage_file"
    else
        jq -nc \
            --arg ext "$ext" \
            --arg pg_major "$major_ver" \
            --arg ceiling "$ceiling" \
            --argjson resolved "$_resolved_json" \
            --argjson available "$_available_json" \
            --argjson excluded "$_excluded_json" \
            '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:$resolved, available:$available, excluded:$excluded}' \
            > "$_vs_lineage_file"
    fi
    log_info "Version-set lineage (atomic): $_vs_lineage_file"
    return 0
}

# Assemble (and optionally push) a bundle image for a resolver-backed extension.
#
# The bundle is a FROM-scratch image that COPYs each available per-version image's
# /output/extension/ and /output/lib/ layers under /<ver>/ so the consumer can do
# a single COPY --from=ext-<ext>:pg<major>-bundle to land all versions.
#
# This is intentionally cheap: no compilation occurs — only COPY layers from the
# per-version refs that already exist in the registry (or local store on LOCAL_ONLY).
# Idempotent: rebuilding with the same available set produces the same content.
#
# Called from TWO sites:
#   1. build_tag_push_extensions — after the per-version inner loop (build path).
#   2. main() — on the all-cached path where build_tag_push_extensions is not called
#      but the bundle must still be refreshed to match the current available set.
#
# Args: ext major_ver do_push avail_ver1 [avail_ver2 ...]
#   do_push: "true" → push to registry after build; "false" → build locally only.
#   avail_ver*: the versions to include in the bundle (must be non-empty).
#
# Returns: 0 on success, 1 on build or push failure (caller adds to failed[]).
# Does NOT call exit directly; callers propagate the failure.
# Under DRY_RUN=true, logs what would happen and returns 0 (callers handle DRY_RUN
# before calling this function on the real path — this guard is defense-in-depth).
assemble_and_push_bundle() {
    local ext="$1" major_ver="$2" do_push="$3"
    shift 3
    local avail_versions=("$@")

    if [[ "$DRY_RUN" == "true" ]]; then
        local _bundle_image_base_d
        _bundle_image_base_d=$(ext_image_name "$ext" "dummy" "$major_ver")
        local _bundle_base_tag_d="${_bundle_image_base_d%:*}:pg${major_ver}-bundle"
        local _bundle_ref_d
        _bundle_ref_d=$(_arch_suffix_tag "$_bundle_base_tag_d" "${ARCH_SUFFIX:-}")
        log_info "[DRY-RUN] Would build bundle $ext pg${major_ver}: $_bundle_ref_d (versions: ${avail_versions[*]})"
        [[ "$do_push" == "true" ]] && log_info "[DRY-RUN] Would push bundle $_bundle_ref_d"
        return 0
    fi

    local _bundle_image_base
    _bundle_image_base=$(ext_image_name "$ext" "dummy" "$major_ver")
    local _bundle_base_tag="${_bundle_image_base%:*}:pg${major_ver}-bundle"
    local _bundle_ref
    _bundle_ref=$(_arch_suffix_tag "$_bundle_base_tag" "${ARCH_SUFFIX:-}")

    local _bundle_df
    # CI per-arch leg (ARCH_SUFFIX set): the bundle is built by stage B
    # (finalize_multiarch_manifests) from the merged per-version multi-arch manifests,
    # not here. Skip the bundle build/push on a per-arch leg; only the local/single-arch
    # path (ARCH_SUFFIX empty) builds the bundle directly.
    if [[ -n "${ARCH_SUFFIX:-}" ]]; then
        log_info "$ext pg${major_ver}: per-arch leg — bundle deferred to stage-B finalize step"
        return 0
    fi

    _bundle_df=$(mktemp)

    {
        printf 'FROM scratch\n'
        local _bver
        for _bver in "${avail_versions[@]}"; do
            # Local/single-arch path (ARCH_SUFFIX empty): reference the plain un-suffixed
            # per-version image built on this host.
            local _per_ver_ref
            _per_ver_ref=$(ext_image_name "$ext" "$_bver" "$major_ver")
            printf 'COPY --from=%s /output/extension/ /%s/extension/\n' "$_per_ver_ref" "$_bver"
            printf 'COPY --from=%s /output/lib/ /%s/lib/\n' "$_per_ver_ref" "$_bver"
        done
    } > "$_bundle_df"

    log_info "Building bundle $ext pg${major_ver}: $_bundle_ref"

    local _bundle_ctx
    _bundle_ctx=$(mktemp -d)

    local _bundle_build_ok=true
    if ! $DOCKER build -t "$_bundle_ref" -f "$_bundle_df" "$_bundle_ctx"; then
        _bundle_build_ok=false
    fi

    rm -f "$_bundle_df"
    rm -rf "$_bundle_ctx"

    if [[ "$_bundle_build_ok" == "false" ]]; then
        log_error "$ext pg${major_ver} bundle build failed"
        return 1
    fi

    log_success "Bundle built: $_bundle_ref"

    local _pushed=false
    if [[ "$do_push" == "true" ]]; then
        if ! $DOCKER push "$_bundle_ref"; then
            log_error "$ext pg${major_ver} bundle push failed"
            return 1
        fi
        log_success "Bundle pushed: $_bundle_ref"
        _pushed=true
    fi

    if [[ "$_pushed" == "true" ]]; then
        # Capture the digest of the pushed bundle image. The consumer emits a
        # digest-pinned COPY --from=<ref>@<digest> for reproducibility.
        # Digest capture failure after a successful push is fatal: the caller cannot
        # construct an immutable reference without the digest.  Fail closed here;
        # the caller (_bundle_and_write_artifact) propagates the non-zero return.
        local _captured_digest
        _captured_digest=$(_capture_bundle_digest "$_bundle_ref") || true
        if ! is_valid_oci_digest "$_captured_digest"; then
            log_error "$ext pg${major_ver}: bundle pushed but digest capture failed or is malformed (got: '$(_sanitize_for_log "${_captured_digest}")') — cannot write immutable artifact ref; fail closed"
            return 2
        fi
        log_info "Bundle digest: $_captured_digest"

        # Export so _bundle_and_write_artifact can read it without a subshell.
        _BUNDLE_DIGEST="$_captured_digest"
        export _BUNDLE_DIGEST
    fi

    return 0
}

# _capture_bundle_digest <bundle_ref>
# Captures the content digest of a pushed bundle image using the raw-manifest
# hashing pattern (the same proven approach used by the build-container action).
# Returns the sha256:... digest string on stdout on success; returns empty string
# and a non-zero exit when the raw manifest cannot be retrieved.
# Separated from assemble_and_push_bundle so tests can override it independently
# without needing to replicate the full docker() mock for buildx.
#
# The --format '{{.Manifest.Digest}}' template field is intentionally NOT used:
# it is empty for some image types and version-dependent in CI, making it
# unreliable as the primary capture method.
_capture_bundle_digest() {
    local _ref="$1"
    local _raw_manifest
    _raw_manifest=$($DOCKER buildx imagetools inspect "$_ref" --raw 2>/dev/null) || true
    if [[ -n "$_raw_manifest" ]]; then
        printf 'sha256:%s' "$(printf '%s' "$_raw_manifest" | sha256sum | awk '{print $1}')"
    else
        return 1
    fi
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
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver" "$config_file"); then
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

        # Semver/ceiling injection guard: applies ONLY to resolver-backed extensions
        # (those with version_set.resolver in config.yaml). Their version sets come
        # from an external resolver whose output is untrusted — a malformed or
        # injected entry must never reach a docker tag or build-arg.
        #
        # Non-resolver single-version extensions have their version pinned directly
        # in config.yaml (operator-controlled, same trust level as the Dockerfile).
        # The injection concern does not apply to them, and their legitimate formats
        # (e.g. "1.14") must not be rejected.
        #
        # The primary validation happens in _resolve_cached (chokepoint) before the
        # result is cached. This gate is retained as defense-in-depth for the
        # LOCAL_ONLY degrade path (where _resolve_cached failed and version_set_json
        # was replaced with the operator-controlled ceiling) and any path that might
        # bypass the cache. validate_semver_set_json is the shared validator used by
        # both _resolve_cached and this gate — single implementation, no duplication.
        local _resolver_path
        _resolver_path=$(yq -r ".extensions.${ext}.version_set.resolver // \"\"" "$config_file" 2>/dev/null || true)

        if [[ -n "$_resolver_path" ]]; then
            if ! validate_semver_set_json "$version_set_json" "$ceiling"; then
                if [[ "$LOCAL_ONLY" == "true" ]]; then
                    log_warning "$ext: semver/ceiling validation failed — degrading to ceiling $ceiling (LOCAL_ONLY)"
                    version_set_json="[\"$ceiling\"]"
                    set_size=1
                else
                    log_error "$ext: semver/ceiling validation failed — skipping build (fail-closed)"
                    failed+=("$ext")
                    continue
                fi
            fi
        fi

        # Remove stale per-version duration lineage files from any previous run
        # so only this run's files survive for sum_flavor_extension_durations.
        # _cleanup_stale_duration_files is a no-op under DRY_RUN.
        _cleanup_stale_duration_files "$ext" "$major_ver"

        # Track versions that are available (built this loop OR pre-existing) for
        # the bundle assembly step below.  Populated inside the inner loop.
        local _available_for_bundle=()

        # Inner loop over each version oldest→newest.
        local version
        while IFS= read -r version; do
            local ver_image
            ver_image=$(ext_image_name "$ext" "$version" "$major_ver")

            # Skip already-available versions.
            # BF fix: on a PR (PR_TAG_SUFFIX non-empty), check the canonical arch tag
            # first (unchanged version — read-only reuse) before the PR-scoped tag.
            # On push (PR_TAG_SUFFIX empty): unchanged behavior via _image_needs_build.
            # LOCAL_ONLY path: unchanged behavior via _image_needs_build.
            local _check_image
            _check_image=$(_scoped_tag "$(_arch_suffix_tag "$ver_image" "${ARCH_SUFFIX:-}")")

            if [[ "$LOCAL_ONLY" == "true" ]]; then
                if ! _image_needs_build "$_check_image"; then
                    log_success "$ext $version already exists locally"
                    _available_for_bundle+=("$version")
                    continue
                fi
            elif [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                # PR context: check canonical arch tag first (unchanged version reuse).
                local _canonical_arch_ref
                _canonical_arch_ref=$(_arch_suffix_tag "$ver_image" "${ARCH_SUFFIX:-}")
                if [[ "$FORCE" != "true" ]] && image_exists_in_registry "$_canonical_arch_ref" 2>/dev/null; then
                    log_success "$ext $version already exists in registry (canonical)"
                    _available_for_bundle+=("$version")
                    continue
                fi
                # Canonical absent: check PR-scoped tag (built this PR).
                if [[ "$FORCE" != "true" ]] && image_exists_in_registry "$_check_image" 2>/dev/null; then
                    log_success "$ext $version already exists in registry (pr-scoped)"
                    _available_for_bundle+=("$version")
                    continue
                fi
            else
                # Push/dispatch (PR_TAG_SUFFIX empty): canonical probe only.
                if ! _image_needs_build "$_check_image"; then
                    log_success "$ext $version already exists in registry"
                    _available_for_bundle+=("$version")
                    continue
                fi
            fi

            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would build $ext $version for $CONTAINER v$major_ver"
                continue
            fi

            # Capture a fresh start time for this version so each lineage file
            # records only that version's own build time (#558).
            local _ver_start=$SECONDS

            # Attempt build for this version.
            # build_extension returns:
            #   0  — success (compile + push, or local build)
            #   1  — compile failure (musl incompatibility or Dockerfile error)
            #   2  — push failure (infra/auth/network; only on BUILD_PLATFORM path)
            local _build_rc=0
            build_extension "$ext" "$config_file" "$major_ver" "$container_dir" "$version" || _build_rc=$?

            if [[ "$_build_rc" -eq 2 ]]; then
                # Push failure (infra/auth/network) is FATAL for ALL versions —
                # ceiling AND non-ceiling.  It is not a compile incompatibility and
                # must never be silently excluded from the version set.
                log_error "$ext $version push failed (infra error) — fatal regardless of ceiling"
                failed+=("$ext@$version")
                continue
            fi

            if [[ "$_build_rc" -ne 0 ]]; then
                # Compile failure (rc=1 or any other non-zero, non-2 code):
                # ceiling is fatal; non-ceiling is tolerated (musl compat).
                if [[ "$version" == "$ceiling" ]]; then
                    log_error "$ext $version (ceiling) build failed"
                    failed+=("$ext@$version")
                else
                    log_warning "$ext $version build failed (non-ceiling, skipping)"
                fi
                continue
            fi

            # When BUILD_PLATFORM is set, build_ext_image (the override at the top of
            # this file) already performed buildx build --load + docker push for the
            # arch-suffixed tag.  The separate tag+push steps are for the local/plain
            # path only.
            if [[ -z "${BUILD_PLATFORM:-}" ]]; then
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
            fi

            log_success "$ext $version completed successfully"

            # Mark available for bundle assembly.
            _available_for_bundle+=("$version")

            # Record this version as built-this-run so _emit_versionset_artifact
            # can union it with the registry probe (guards against GHCR lag).
            if [[ "$DRY_RUN" != "true" ]]; then
                printf '%s\n' "$version" >> "${_BUILT_THIS_RUN_DIR}/${ext}-${major_ver}"
            fi

            # Write per-version lineage file with this version's own duration.
            # Dry runs must not mutate .build-lineage.
            #
            # AY-2: When ARCH_SUFFIX is non-empty (CI per-arch leg), write the
            # lineage file as arch-suffixed: ext-<ext>-pg<major>-<ver>-<arch>.json.
            # Both arch artifact directories are downloaded into the SAME .build-lineage/
            # during the finalize step; un-suffixed files from both legs would collide
            # (one arch overwrites the other). The AX-3 consolidation loop in
            # finalize_multiarch_manifests reads -amd64.json + -arm64.json, takes
            # MAX of duration_seconds, and writes the canonical un-suffixed file.
            # When ARCH_SUFFIX is empty (local/single-arch), keep the un-suffixed name.
            if [[ "$DRY_RUN" != "true" ]]; then
                local _ver_duration=$(( SECONDS - _ver_start ))
                local _ver_image
                _ver_image=$(ext_image_name "$ext" "$version" "$major_ver")
                local _ver_safe="${version//[^a-zA-Z0-9.-]/_}"
                local _ver_lineage_suffix=""
                [[ -n "${ARCH_SUFFIX:-}" ]] && _ver_lineage_suffix="-${ARCH_SUFFIX}"
                local _ver_lineage_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-${_ver_safe}${_ver_lineage_suffix}.json"
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

        # Bundle + artifact (atomic): for resolver-backed multi-version extensions,
        # _bundle_and_write_artifact computes confirmed_available ONCE (3-state probe
        # + built-this-run union), pushes the bundle from that set, then writes the
        # artifact from the SAME set. Artifact is written only after a successful push.
        #
        # Under DRY_RUN: log intent and continue (no mutation).
        # Fatal failure guard (AK-1): if ANY version for this ext failed in this run,
        # skip bundle+artifact — ceiling may be absent, confirmed set is incomplete.
        if [[ -n "$_resolver_path" ]] && [[ "$set_size" -gt 1 ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                local _bundle_image_base_dry
                _bundle_image_base_dry=$(ext_image_name "$ext" "dummy" "$major_ver")
                local _bundle_ref_dry="${_bundle_image_base_dry%:*}:pg${major_ver}-bundle"
                local _dry_all_versions
                _dry_all_versions=$(echo "$version_set_json" | jq -r '.[]' | tr '\n' ' ')
                log_info "[DRY-RUN] Would build bundle $ext pg${major_ver}: $_bundle_ref_dry (versions: ${_dry_all_versions})"
                log_info "[DRY-RUN] Would push bundle $_bundle_ref_dry"
                continue
            fi

            # AK-1: skip if any fatal failure for this extension.
            local _ext_fatal=false
            local _fe
            for _fe in "${failed[@]+"${failed[@]}"}"; do
                if [[ "$_fe" == "${ext}@"* ]]; then
                    _ext_fatal=true
                    break
                fi
            done

            if [[ "$_ext_fatal" == "true" ]]; then
                log_warning "$ext pg${major_ver}: skipping bundle+artifact — fatal failure in this run"
                _delete_stale_versionset_artifact "$ext" "$major_ver"
            else
                local _ba_rc=0
                _bundle_and_write_artifact "$ext" "$config_file" "$major_ver" "$version_set_json" "$ceiling" "$do_push" || _ba_rc=$?
                if [[ "$_ba_rc" -ne 0 ]]; then
                    failed+=("$ext@bundle")
                    continue
                fi
            fi
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
    local ext="$1" major="$2" config_file="${3:-}"
    local cache_file="${_RESOLVER_CACHE_DIR}/${ext}-${major}.json"

    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    local result
    result=$(resolve_version_set "$ext" "$major" "${config_file}") || return 1

    # Validate: must be a non-empty JSON array where every element is a string.
    # If the resolver exits 0 but emits malformed output or an empty array,
    # treat it as a resolver failure (fail-closed) and do NOT cache the bad value.
    if ! echo "$result" | jq -e 'type == "array" and length > 0 and (all(.[]; type == "string"))' > /dev/null 2>&1; then
        log_error "resolver for $ext returned invalid version set (not a non-empty string array): $(_sanitize_for_log "$result")"
        return 1
    fi

    # For RESOLVER-BACKED extensions only: apply strict whole-string semver +
    # ceiling validation at the chokepoint BEFORE caching.
    # This prevents the embedded-newline bypass where jq -r '.[]' would split a
    # single element "2.27.1\n9.9.9" into two apparent versions, each passing a
    # per-line semver check in every downstream consumer.
    #
    # Non-resolver single-version extensions (e.g. pg_ivm "1.14") return a
    # single-element array from a config-controlled value — they are NOT resolver-
    # backed and must NOT be subjected to this check (their format may not be 3-part
    # semver). Detection: check for a non-empty version_set.resolver in config_file.
    if [[ -n "${config_file:-}" ]]; then
        local _resolver_path_cached
        _resolver_path_cached=$(yq -r ".extensions.${ext}.version_set.resolver // \"\"" "${config_file}" 2>/dev/null || true)
        if [[ -n "$_resolver_path_cached" ]]; then
            # Read the ceiling for the clamp check.
            local _ceiling_cached
            _ceiling_cached=$(yq -r ".extensions.${ext}.version" "${config_file}" 2>/dev/null || true)
            if ! validate_semver_set_json "$result" "$_ceiling_cached"; then
                log_error "resolver for $ext returned set that fails whole-string semver/ceiling validation (injection guard): $(_sanitize_for_log "$result")"
                return 1
            fi
        fi
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

    # Explicit not-found allow-list: only REGISTRY-MANIFEST-SPECIFIC signals confirm
    # definitive absence. These are the exact strings docker/skopeo emit for a
    # genuinely-missing tag as returned by the registry manifest API.
    # Bare "not found", "no such image" (Docker local-store), and bare "404" are
    # intentionally excluded: they also appear in infra errors like
    # "docker: command not found" or "docker-credential-desktop: executable file
    # not found in PATH", which would mis-classify an infra failure as ABSENT and
    # silently drop retained versions from the artifact.
    if echo "$_probe_stderr" | grep -qiE \
        'manifest unknown|name unknown|repository name not known|no such manifest'; then
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
                'manifest unknown|name unknown|repository name not known|no such manifest|MANIFEST_UNKNOWN'; then
                return 2  # ERROR (docker said not-found but skopeo is ambiguous)
            fi
        fi
        return 1  # ABSENT (definitive not-found confirmed)
    fi

    # No explicit not-found signal → ambiguous/transient error (fail-closed).
    # Covers: toomanyrequests, denied, unauthorized, no such host, network unreachable,
    # EOF, context deadline exceeded, empty stderr, daemon errors, command not found,
    # missing cred helpers, and anything else non-specific to the registry manifest API.
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
    if ! version_set_json=$(_resolve_cached "$ext" "$major_ver" "$config_file"); then
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
        # When ARCH_SUFFIX is set (CI per-arch leg), probe the arch-suffixed ref.
        local _check_image_single
        _check_image_single=$(_scoped_tag "$(_arch_suffix_tag "$image" "${ARCH_SUFFIX:-}")")

        if [[ "$LOCAL_ONLY" == "true" ]]; then
            if [[ "$FORCE" != "true" ]] && docker image inspect "$_check_image_single" &>/dev/null; then
                log_success "$ext $version already exists locally"
                return 1
            fi
            return 0
        fi

        if [[ "$FORCE" == "true" ]]; then
            return 0
        fi

        if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
            # BF fix: PR context — check canonical arch tag first (unchanged version reuse).
            local _canonical_single
            _canonical_single=$(_arch_suffix_tag "$image" "${ARCH_SUFFIX:-}")
            if image_exists_in_registry "$_canonical_single" 2>/dev/null; then
                log_success "$ext $version already exists in registry"
                return 1
            fi
            # Canonical absent: check PR-scoped.
            if image_exists_in_registry "$_check_image_single" 2>/dev/null; then
                log_success "$ext $version already exists in registry"
                return 1
            fi
            return 0
        fi

        # Push/dispatch (PR_TAG_SUFFIX empty): canonical probe only.
        if image_exists_in_registry "$_check_image_single" 2>/dev/null; then
            log_success "$ext $version already exists in registry"
            return 1
        fi

        return 0
    fi

    # Multi-version path: return 0 if any version in the set needs building.
    # BF fix: on a PR (PR_TAG_SUFFIX non-empty), a version is "needs build" only when
    # NEITHER its canonical arch tag (unchanged, read-only) NOR its PR-scoped arch tag
    # (built this PR) exists in the registry. This prevents rebuilding all retained
    # versions on a fresh PR where only the new/changed version is missing.
    # On push (PR_TAG_SUFFIX empty): canonical probe only (unchanged behavior).
    local ver
    while IFS= read -r ver; do
        local ver_image_mv
        ver_image_mv=$(ext_image_name "$ext" "$ver" "$major_ver")
        local _check_ver_image_mv
        _check_ver_image_mv=$(_scoped_tag "$(_arch_suffix_tag "$ver_image_mv" "${ARCH_SUFFIX:-}")")

        if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
            # PR context: canonical-first check.
            local _canonical_mv
            _canonical_mv=$(_arch_suffix_tag "$ver_image_mv" "${ARCH_SUFFIX:-}")
            if ! image_exists_in_registry "$_canonical_mv" 2>/dev/null && \
               ! image_exists_in_registry "$_check_ver_image_mv" 2>/dev/null; then
                # Neither canonical nor PR-scoped present → needs build.
                return 0
            fi
        else
            # Push/dispatch: canonical probe only.
            if _image_needs_build "$_check_ver_image_mv"; then
                return 0
            fi
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
# Args: config_file major_ver container_dir [_ignored_single_ext] [do_push]
#   Arg 4 (_ignored_single_ext): accepted for backward compatibility but unused —
#     scoping is driven exclusively by the global $EXTENSION variable.
#   Arg 5 (do_push): "true" = push bundle to registry; "false" = no push.
#     When do_push="false" AND not LOCAL_ONLY AND not PULL_ONLY (CI PR smoke),
#     the bundle assembly and artifact write are SKIPPED entirely — the all-cached
#     CI PR path must exit cleanly without any GHCR write attempt.
#     When do_push="false" AND (LOCAL_ONLY OR PULL_ONLY): assemble locally, no push.
#     Defaults to re-deriving from LOCAL_ONLY/PULL_ONLY when arg 5 is absent
#     (backward compatibility with callers that do not pass do_push).
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
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver" "$config_file"); then
            # Resolver failure in the final pass: distinguish publish vs recovery.
            # - Publish path (NOT LOCAL_ONLY and NOT PULL_ONLY): fail-closed —
            #   a required retention artifact cannot be produced; the run must
            #   exit non-zero so CI does not report success with a missing artifact.
            # - Recovery paths (LOCAL_ONLY=true or PULL_ONLY=true): degrade —
            #   a transient resolver outage must not block the ceiling build, but
            #   NO version-set artifact is emitted. The downstream timeseries/full
            #   postgres build requires skopeo or a CI-produced artifact (documented
            #   in postgres/README.md). Any stale artifact is deleted so it cannot
            #   be silently consumed with out-of-date retention data.
            if [[ "${LOCAL_ONLY:-false}" == "true" || "${PULL_ONLY:-false}" == "true" ]]; then
                log_warning "$ext: resolver unavailable in final pass (recovery path) — no version-set artifact produced"
                log_warning "$ext: a local timeseries/full postgres build requires skopeo or a CI-produced version-set artifact"
                if [[ "$DRY_RUN" != "true" ]]; then
                    _delete_stale_versionset_artifact "$ext" "$major_ver"
                fi
            else
                log_error "$ext: resolver failed in final pass (publish path) — versionset artifact cannot be produced"
                _final_pass_failed=true
            fi
            continue
        fi

        local set_size
        set_size=$(echo "$version_set_json" | jq 'length')
        if [[ "$set_size" -le 1 ]]; then
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            continue
        fi

        # Determine the effective do_push for this final pass.
        # Use arg 5 when provided (threaded from main()); otherwise re-derive from
        # LOCAL_ONLY/PULL_ONLY for backward compatibility with direct callers.
        # Three-way contract:
        #   do_push=true                         → assemble + push bundle + write artifact.
        #   do_push=false + LOCAL_ONLY/PULL_ONLY → assemble locally, no push (recovery).
        #   do_push=false + not LOCAL_ONLY/PULL_ONLY → CI PR smoke: skip bundle entirely.
        local _do_push_fp
        if [[ -n "${5:-}" ]]; then
            _do_push_fp="$5"
        else
            _do_push_fp="true"
            [[ "${LOCAL_ONLY:-false}" == "true" || "${PULL_ONLY:-false}" == "true" ]] && _do_push_fp="false"
        fi

        # AV-2 single-bundle guard: if _bundle_and_write_artifact was already called for
        # this (ext, major_ver) on the BUILD PATH (in build_tag_push_extensions), a
        # sentinel file was written to ${_BUILT_THIS_RUN_DIR}/bundle-<ext>-<major_ver>.
        # Skip the final pass for this (ext, major_ver) to prevent assembling the bundle
        # a second time in the same run.  The all-cached path (no build) writes no
        # sentinel, so those always go through the final pass as before.
        local _bundle_sentinel_fp="${_BUILT_THIS_RUN_DIR}/bundle-${ext}-${major_ver}"
        if [[ -f "$_bundle_sentinel_fp" ]]; then
            log_info "$ext pg${major_ver}: bundle already assembled on build path — skipping final pass for this extension (AV-2 guard)"
            continue
        fi

        # Atomic: push bundle from confirmed_available, then write artifact from the
        # SAME set. _bundle_and_write_artifact handles the 3-state probe, fail-closed
        # gates, stale artifact deletion, ordering invariant, and the CI no-push guard.
        local _bwa_rc=0
        _bundle_and_write_artifact "$ext" "$config_file" "$major_ver" "$version_set_json" "$ceiling" "$_do_push_fp" || _bwa_rc=$?
        if [[ "$_bwa_rc" -ne 0 ]]; then
            _final_pass_failed=true
        fi
    done <<< "$ext_list"

    if [[ "$_final_pass_failed" == "true" ]]; then
        return 1
    fi
}

# Remove the versionset artifact for a specific (ext, major_ver) when a
# skip-without-write path is taken, so any pre-existing stale artifact does not
# mislead the consumer into using an out-of-date available[].
# Only removes ext-<ext>-pg<major>-versionset.json — never touches per-version
# duration lineage files or any other extension's artifacts.
# Must only be called from non-DRY_RUN paths (callers check DRY_RUN before use).
# Args: ext major_ver
_delete_stale_versionset_artifact() {
    local ext="$1" major_ver="$2"
    local _vs_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-versionset.json"
    rm -f "$_vs_file"
}

# Write (or refresh) the versionset artifact for a resolver-backed extension
# using a pure presence-based pass — no build occurs.
# Args: ext config_file major_ver version_set_json ceiling
# Does nothing under DRY_RUN.
# When set_size <= 1: deletes any stale versionset artifact and returns 0
#   (single-version extensions produce no artifact; consumer uses single-version path).
_emit_versionset_artifact() {
    local ext="$1" config_file="$2" major_ver="$3" version_set_json="$4" ceiling="$5"

    [[ "$DRY_RUN" == "true" ]] && return 0

    local set_size
    set_size=$(echo "$version_set_json" | jq 'length')
    if [[ "$set_size" -le 1 ]]; then
        _delete_stale_versionset_artifact "$ext" "$major_ver"
        return 0
    fi

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
    # Remove any stale artifact so the consumer's self-heal triggers instead of reading old data.
    if [[ "$_probe_error" == "true" ]]; then
        _delete_stale_versionset_artifact "$ext" "$major_ver"
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
        # Remove any stale artifact from a prior run so the consumer's self-heal triggers
        # instead of reading an out-of-date available[].
        _delete_stale_versionset_artifact "$ext" "$major_ver"
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

# finalize_multiarch_manifests <config_file> <major_ver> <container_dir>
#
# Stage B (multi-arch): invoked after BOTH arch build legs finish.
# For each extension in scope:
#
#   Non-resolver extensions (single configured version):
#     Creates the un-suffixed multi-arch manifest from stable suffixed tags
#     (-amd64 / -arm64). No bundle, no versionset artifact.
#
#   Resolver-backed extensions:
#     1. Re-resolves the version set (deterministic via resolver + retain_count).
#     2. AVAILABILITY = INTERSECTION: for each version, probe both
#        ext-<ext>:pg<major>-<ver>-amd64 AND ext-<ext>:pg<major>-<ver>-arm64.
#        A version present on BOTH arches → available; missing on either arch →
#        excluded (tolerated for non-ceiling) or FATAL (ceiling).
#     3. Creates per-version multi-arch manifests from the stable suffixed tags
#        for all AVAILABLE versions (including cached versions not rebuilt this
#        run — their suffixed tags persist in the registry from prior runs).
#     4. For set_size == 1 (single-version resolver result): still creates the
#        un-suffixed per-version manifest so the consumer's single-version path
#        finds it. No bundle needed.
#     5. For available count >= 2: builds the multi-arch bundle image via
#        buildx build --platform linux/amd64,linux/arm64 from the AVAILABLE
#        per-version multi-arch manifests (un-suffixed, just created).
#        Each platform's bundle layer gets that platform's .so from the
#        per-version manifest — no QEMU/compilation needed, file-copy only.
#     6. Captures the INDEX digest of the bundle manifest.
#     7. Writes the versionset artifact with bundle_digest = that index digest.
#
# Stable-tag merge rationale: digest-pinned merge (reverted AX-1/AY-1 approach)
# was dropped because it excluded cached versions (not rebuilt this run, so no
# digest map entry) from the merge, silently dropping retention. Stable suffixed
# tags (-amd64/-arm64) persist in the registry across runs and are always present
# for any version that was ever successfully pushed. A cross-run tag race (a
# concurrent run overwriting the same suffixed tag between push and merge) is an
# accepted low-probability risk for this single-maintainer repo: auto-update PRs
# are serialized by the concurrency group, so same-ref concurrent pushes do not
# occur in practice.
#
# Fail-closed: ceiling missing on either arch, imagetools create failure for
# ceiling, bundle build/push failure, or digest capture failure → fatal.
# Non-ceiling failures are tolerated (musl-compat contract from stage A).
#
# Called from main() when FINALIZE_MULTIARCH=true.
# Does nothing under DRY_RUN.
finalize_multiarch_manifests() {
    local config_file="$1" major_ver="$2" container_dir="$3"

    log_info "Stage B: merging per-arch manifests into multi-arch manifests (pg${major_ver})"

    local ext_list
    if [[ -n "${EXTENSION:-}" ]]; then
        ext_list="$EXTENSION"
    else
        ext_list=$(list_extensions_by_priority "$config_file" "$major_ver")
    fi

    local _failed=false
    local ext
    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue

        local dockerfile="$container_dir/extensions/build/${ext}.Dockerfile"
        [[ ! -f "$dockerfile" ]] && continue

        local ceiling
        ceiling=$(ext_config "$ext" "version" "$config_file")

        # Determine whether this extension has a resolver-backed multi-version set.
        local _resolver_path
        _resolver_path=$(yq -r ".extensions.${ext}.version_set.resolver // \"\"" "$config_file" 2>/dev/null || true)

        if [[ -z "$_resolver_path" ]]; then
            # BG-1: Non-resolver extension (single configured version).
            # On push/dispatch (PR_TAG_SUFFIX empty) → create canonical manifest from
            #   stable suffixed tags (-amd64/-arm64). Unchanged behavior.
            # On same-repo PR (PR_TAG_SUFFIX=-prN) → canonical-first reuse:
            #   probe the canonical multi-arch manifest (no suffix). If PRESENT,
            #   the extension is unchanged; reuse it read-only, no imagetools create.
            #   If ABSENT, the extension was built this PR; create the PR-scoped
            #   manifest from the PR-scoped arch tags (-amd64-prN / -arm64-prN).
            #   Supply-chain: PRs never overwrite canonical (read-only reuse).
            local _ver_image_base
            _ver_image_base=$(ext_image_name "$ext" "$ceiling" "$major_ver")

            if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                # Probe canonical multi-arch manifest (no suffix, no arch suffix).
                local _nr_canonical_rc=0
                _image_present_3state "$_ver_image_base" || _nr_canonical_rc=$?

                if [[ "$_nr_canonical_rc" -eq 2 ]]; then
                    log_error "$ext $ceiling pg${major_ver}: transient registry probe error on canonical non-resolver ref — fail closed"
                    _failed=true
                    continue
                fi

                if [[ "$_nr_canonical_rc" -eq 0 ]]; then
                    # Canonical manifest present: extension is unchanged, reuse read-only.
                    log_info "$ext $ceiling pg${major_ver}: canonical manifest present — reused (unchanged, non-resolver)"
                    continue
                fi
                # Canonical absent: extension was built this PR, fall through to create.
            fi

            local _nr_src_amd64 _nr_src_arm64
            _nr_src_amd64=$(_scoped_tag "$(_arch_suffix_tag "$_ver_image_base" "amd64")")
            _nr_src_arm64=$(_scoped_tag "$(_arch_suffix_tag "$_ver_image_base" "arm64")")
            local _nr_target
            _nr_target=$(_scoped_tag "$_ver_image_base")

            log_info "$ext $ceiling pg${major_ver}: imagetools create $_nr_target from $_nr_src_amd64 + $_nr_src_arm64 (non-resolver, stable suffixed tags)"
            local _nr_create_rc=0
            $DOCKER buildx imagetools create \
                -t "$_nr_target" \
                "$_nr_src_amd64" "$_nr_src_arm64" 2>&1 \
                || _nr_create_rc=$?
            if [[ "$_nr_create_rc" -ne 0 ]]; then
                log_error "$ext $ceiling pg${major_ver}: non-resolver imagetools create failed (rc=$_nr_create_rc) — fail-closed"
                _failed=true
            else
                log_success "Multi-arch manifest created: $_nr_target (non-resolver)"
            fi
            continue
        fi

        # Resolver-backed extension: resolve version set, validate, then merge.
        local version_set_json
        if ! version_set_json=$(_resolve_cached "$ext" "$major_ver" "$config_file"); then
            log_error "$ext: resolver failed in finalize-multiarch — cannot produce multi-arch manifests (fail-closed)"
            _failed=true
            continue
        fi

        # Validate: must be semver + ceiling present.
        if ! validate_semver_set_json "$version_set_json" "$ceiling"; then
            log_error "$ext: semver/ceiling validation failed in finalize-multiarch (fail-closed)"
            _failed=true
            continue
        fi

        local set_size
        set_size=$(echo "$version_set_json" | jq 'length')

        # AX-3: Consolidate per-arch duration files into canonical files (MAX policy).
        # This runs for ALL set sizes so single-version resolver results also get
        # consolidated duration files. The consolidation is idempotent — if no
        # arch-suffixed files exist, the loop is a no-op.
        local _dur_ver_pre
        while IFS= read -r _dur_ver_pre; do
            [[ -z "$_dur_ver_pre" ]] && continue
            local _ver_safe_pre="${_dur_ver_pre//[^a-zA-Z0-9.-]/_}"
            local _dur_pre_amd64="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-${_ver_safe_pre}-amd64.json"
            local _dur_pre_arm64="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-${_ver_safe_pre}-arm64.json"
            local _dur_pre_canonical="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-${_ver_safe_pre}.json"

            local _dp_amd64_sec=0 _dp_arm64_sec=0 _have_dur_pre=false _dur_pre_source=""
            if [[ -f "$_dur_pre_amd64" ]]; then
                local _dp; _dp=$(jq -r '.duration_seconds // 0' "$_dur_pre_amd64" 2>/dev/null || echo 0)
                [[ "$_dp" =~ ^[0-9]+$ ]] && _dp_amd64_sec="$_dp"
                _have_dur_pre=true
                _dur_pre_source="$_dur_pre_amd64"
            fi
            if [[ -f "$_dur_pre_arm64" ]]; then
                local _dp; _dp=$(jq -r '.duration_seconds // 0' "$_dur_pre_arm64" 2>/dev/null || echo 0)
                [[ "$_dp" =~ ^[0-9]+$ ]] && _dp_arm64_sec="$_dp"
                _have_dur_pre=true
                [[ -z "$_dur_pre_source" ]] && _dur_pre_source="$_dur_pre_arm64"
            fi

            if [[ "$_have_dur_pre" == "true" ]] && [[ -n "$_dur_pre_source" ]]; then
                local _max_dur_pre
                _max_dur_pre=$(( _dp_amd64_sec > _dp_arm64_sec ? _dp_amd64_sec : _dp_arm64_sec ))
                local _tmp_dur_pre
                _tmp_dur_pre=$(mktemp)
                jq --argjson dur "$_max_dur_pre" '. + {duration_seconds: $dur}' "$_dur_pre_source" \
                    > "$_tmp_dur_pre" && mv "$_tmp_dur_pre" "$_dur_pre_canonical" || rm -f "$_tmp_dur_pre"
                rm -f "$_dur_pre_amd64" "$_dur_pre_arm64"
                log_info "Duration consolidated (AX-3): $_dur_pre_canonical (amd64=${_dp_amd64_sec}s arm64=${_dp_arm64_sec}s max=${_max_dur_pre}s)"
            fi
        done < <(echo "$version_set_json" | jq -r '.[]')

        # Step 1: compute AVAILABLE set.
        # BF fix: canonical-first resolution for the PR path.
        #
        # On push (PR_TAG_SUFFIX empty): probe canonical arch tags as before.
        #
        # On PR (PR_TAG_SUFFIX non-empty):
        #   For each version, check if the canonical multi-arch manifest already
        #   exists (version unchanged — was pushed in a prior push run).
        #   - If canonical manifest EXISTS: reuse it (no imagetools create needed);
        #     add to _confirmed_available with source=canonical. PR never overwrites
        #     canonical (supply-chain safe: read-only).
        #   - If canonical manifest ABSENT: check PR-scoped arch tags (built this PR).
        #     If both present: create PR-scoped multi-arch manifest as before.
        #     If either absent: exclude non-ceiling; fatal for ceiling.
        #
        # Bundle Dockerfile COPYs use the resolved source ref per version:
        #   - unchanged versions → canonical multi-arch ref (e.g. :pg18-2.23.0)
        #   - changed/new version → PR-scoped multi-arch ref (e.g. :pg18-2.27.1-pr42)
        local _confirmed_available=()
        local _confirmed_sources=()   # parallel array: ref to use in bundle COPY per available version
        local _excluded_entries=()
        local _ext_failed=false
        local ver
        while IFS= read -r ver; do
            local ver_image_base
            ver_image_base=$(ext_image_name "$ext" "$ver" "$major_ver")

            # BF: on a PR, check canonical multi-arch manifest first (unchanged version reuse).
            if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                # Probe the canonical multi-arch ref (no suffix).
                local _canonical_ver_ref="$ver_image_base"
                local _canonical_rc=0
                _image_present_3state "$_canonical_ver_ref" || _canonical_rc=$?

                if [[ "$_canonical_rc" -eq 2 ]]; then
                    # Transient probe error on canonical → fail closed.
                    log_error "$ext $ver pg${major_ver}: transient registry probe error on canonical ref — fail closed"
                    _ext_failed=true
                    break
                fi

                if [[ "$_canonical_rc" -eq 0 ]]; then
                    # Canonical multi-arch manifest exists → unchanged version, reuse read-only.
                    log_info "$ext $ver pg${major_ver}: canonical manifest present — reused (unchanged)"
                    _confirmed_available+=("$ver")
                    _confirmed_sources+=("$_canonical_ver_ref")
                    continue
                fi
                # Canonical absent: fall through to PR-scoped arch tag probe below.
            fi

            local _ver_tag_amd64 _ver_tag_arm64
            if [[ -n "${PR_TAG_SUFFIX:-}" ]]; then
                # PR context: probe the PR-scoped arch tags (built this PR).
                _ver_tag_amd64=$(_scoped_tag "$(_arch_suffix_tag "$ver_image_base" "amd64")")
                _ver_tag_arm64=$(_scoped_tag "$(_arch_suffix_tag "$ver_image_base" "arm64")")
            else
                # Push/dispatch: probe canonical arch tags as before.
                _ver_tag_amd64=$(_arch_suffix_tag "$ver_image_base" "amd64")
                _ver_tag_arm64=$(_arch_suffix_tag "$ver_image_base" "arm64")
            fi

            # Use the 3-state probe to distinguish a definitive ABSENT (legitimate
            # per-arch build miss → excluded for non-ceiling) from a transient ERROR
            # (auth/429/network → fail-closed, do not silently shrink the version set).
            local _amd64_rc=0 _arm64_rc=0
            _image_present_3state "$_ver_tag_amd64" || _amd64_rc=$?
            _image_present_3state "$_ver_tag_arm64" || _arm64_rc=$?

            # Transient probe error (rc=2) on either arch → fail closed immediately.
            # Do not exclude the version; we do not know if it is genuinely absent.
            if [[ "$_amd64_rc" -eq 2 ]] || [[ "$_arm64_rc" -eq 2 ]]; then
                log_error "$ext $ver pg${major_ver}: transient registry probe error (amd64_rc=$_amd64_rc arm64_rc=$_arm64_rc) — fail closed"
                _ext_failed=true
                break
            fi

            # Definitive absence (rc=1) on either arch.
            if [[ "$_amd64_rc" -eq 1 ]] || [[ "$_arm64_rc" -eq 1 ]]; then
                if [[ "$ver" == "$ceiling" ]]; then
                    log_error "$ext $ver pg${major_ver} (ceiling): suffixed tag missing on arch(es) — amd64_rc=$_amd64_rc arm64_rc=$_arm64_rc — fatal"
                    _ext_failed=true
                    break
                else
                    log_warning "$ext $ver pg${major_ver}: suffixed tag missing on arch(es) — amd64_rc=$_amd64_rc arm64_rc=$_arm64_rc — excluded"
                    _excluded_entries+=("{\"version\":\"${ver}\",\"reason\":\"suffixed tag missing on one or more arches\"}")
                    continue
                fi
            fi

            # Both arch suffixed tags confirmed PRESENT (rc=0): create the scoped
            # multi-arch manifest target from the scoped source tags.
            # On push (empty suffix): canonical un-suffixed target.
            # On PR: PR-scoped target (e.g. :pg18-2.27.1-pr42).
            # Supply-chain: PRs write only PR-scoped targets; canonical unchanged.
            local ver_multiarch
            ver_multiarch=$(_scoped_tag "$ver_image_base")
            local _src_amd64 _src_arm64
            _src_amd64="$_ver_tag_amd64"
            _src_arm64="$_ver_tag_arm64"

            log_info "$ext $ver pg${major_ver}: imagetools create $ver_multiarch from $_src_amd64 + $_src_arm64"
            local _create_rc=0
            $DOCKER buildx imagetools create \
                -t "$ver_multiarch" \
                "$_src_amd64" "$_src_arm64" 2>&1 \
                || _create_rc=$?
            if [[ "$_create_rc" -ne 0 ]]; then
                # Both sources were confirmed present by the probe; a create failure
                # is a registry/infra error, NOT a missing-source exclusion.
                # Fatal for ceiling AND non-ceiling (infra error, not build miss).
                log_error "$ext $ver pg${major_ver}: imagetools create failed (rc=$_create_rc) — sources confirmed present, infra error — fatal"
                _ext_failed=true
                break
            fi

            _confirmed_available+=("$ver")
            # BF: track the scoped ref so bundle COPY uses the right target per version.
            _confirmed_sources+=("$ver_multiarch")
        done < <(echo "$version_set_json" | jq -r '.[]')

        # Ceiling merge failed → fatal for this extension.
        if [[ "$_ext_failed" == "true" ]]; then
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            _failed=true
            continue
        fi

        # Ceiling must be in confirmed_available.
        local _ceiling_ok=false
        local _ca
        for _ca in "${_confirmed_available[@]+"${_confirmed_available[@]}"}"; do
            if [[ "$_ca" == "$ceiling" ]]; then
                _ceiling_ok=true
                break
            fi
        done
        if [[ "$_ceiling_ok" == "false" ]] || [[ ${#_confirmed_available[@]} -eq 0 ]]; then
            log_info "$ext pg${major_ver}: confirmed_available is empty or ceiling ($ceiling) absent after per-version merges — skipping bundle+artifact"
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            continue
        fi

        # For set_size == 1 (single-version resolver): the per-version multi-arch manifest
        # was already created above (ceiling). No bundle needed; consumer uses single-version
        # path. Delete any stale versionset artifact. (AZ-4 fix: manifest IS created above.)
        if [[ "$set_size" -le 1 ]]; then
            log_info "$ext pg${major_ver}: single-version resolver result — per-version manifest created, no bundle needed"
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            continue
        fi

        # Only one version confirmed available — no bundle (consumer uses single-version path).
        if [[ ${#_confirmed_available[@]} -le 1 ]]; then
            log_info "$ext pg${major_ver}: only ${#_confirmed_available[@]} version(s) available — skipping bundle (consumer uses single-version path)"
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            continue
        fi

        # Step 2: build the multi-arch bundle from the AVAILABLE per-version multi-arch
        # manifests (scoped, just created above). Each platform's bundle layer gets
        # that platform's .so via the per-version manifest's platform selection.
        # This is file-copy only (no compilation), so buildx multi-platform on the amd64
        # merge runner works without QEMU. The bundle contains EXACTLY the available set.
        local _bundle_image_base
        _bundle_image_base=$(ext_image_name "$ext" "dummy" "$major_ver")
        local _bundle_base_tag_canonical="${_bundle_image_base%:*}:pg${major_ver}-bundle"
        # Apply PR_TAG_SUFFIX to the bundle tag so PR runs publish a scoped bundle ref
        # and never overwrite the canonical :pg<major>-bundle tag.
        local _bundle_base_tag
        _bundle_base_tag=$(_scoped_tag "$_bundle_base_tag_canonical")

        local _bundle_df
        _bundle_df=$(mktemp)
        {
            printf 'FROM scratch\n'
            local _bv_idx=0 _bv
            for _bv in "${_confirmed_available[@]}"; do
                local _bv_ref
                # BF: use the resolved source ref for each version from _confirmed_sources.
                # - unchanged versions: canonical multi-arch ref (e.g. :pg18-2.23.0)
                # - new/changed version: PR-scoped multi-arch ref (e.g. :pg18-2.27.1-pr42)
                # On push (PR_TAG_SUFFIX empty): all refs are canonical (no change).
                if [[ "${#_confirmed_sources[@]}" -gt "$_bv_idx" ]]; then
                    _bv_ref="${_confirmed_sources[$_bv_idx]}"
                else
                    # Fallback (should not happen): use scoped ref.
                    _bv_ref=$(_scoped_tag "$(ext_image_name "$ext" "$_bv" "$major_ver")")
                fi
                _bv_idx=$(( _bv_idx + 1 ))
                printf 'COPY --from=%s /output/extension/ /%s/extension/\n' "$_bv_ref" "$_bv"
                printf 'COPY --from=%s /output/lib/ /%s/lib/\n' "$_bv_ref" "$_bv"
            done
        } > "$_bundle_df"

        local _bundle_ctx
        _bundle_ctx=$(mktemp -d)

        log_info "$ext pg${major_ver}: buildx build --platform linux/amd64,linux/arm64 -t $_bundle_base_tag (bundle from available: ${_confirmed_available[*]})"
        local _bundle_build_rc=0
        $DOCKER buildx build \
            --platform linux/amd64,linux/arm64 \
            -t "$_bundle_base_tag" \
            -f "$_bundle_df" \
            --push \
            "$_bundle_ctx" 2>&1 \
            || _bundle_build_rc=$?
        if [[ "$_bundle_build_rc" -ne 0 ]]; then
            log_error "$ext pg${major_ver}: bundle buildx build failed (rc=$_bundle_build_rc) — fail-closed"
            rm -f "$_bundle_df"
            rm -rf "$_bundle_ctx"
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            _failed=true
            continue
        fi
        rm -f "$_bundle_df"
        rm -rf "$_bundle_ctx"
        log_success "Bundle multi-arch image built+pushed: $_bundle_base_tag"

        # Step 3: capture INDEX digest of the bundle manifest.
        local _index_digest
        _index_digest=$(_capture_bundle_digest "$_bundle_base_tag") || true
        if ! is_valid_oci_digest "$_index_digest"; then
            log_error "$ext pg${major_ver}: bundle index digest capture failed or malformed (got: '$(_sanitize_for_log "${_index_digest}")') — fail-closed"
            _delete_stale_versionset_artifact "$ext" "$major_ver"
            _failed=true
            continue
        fi
        log_info "$ext pg${major_ver}: bundle index digest: $_index_digest"

        # Step 4: write versionset artifact with bundle_digest = index digest.
        local _vs_lineage_file="${ROOT_DIR}/.build-lineage/ext-${ext}-pg${major_ver}-versionset.json"
        mkdir -p "${ROOT_DIR}/.build-lineage"

        local _available_json _excluded_json _resolved_json
        _available_json=$(printf '%s\n' "${_confirmed_available[@]+"${_confirmed_available[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))')
        _excluded_json="[$(IFS=,; echo "${_excluded_entries[*]+"${_excluded_entries[*]}"}")]"
        _resolved_json=$(echo "$version_set_json" | jq '.')

        jq -nc \
            --arg ext "$ext" \
            --arg pg_major "$major_ver" \
            --arg ceiling "$ceiling" \
            --argjson resolved "$_resolved_json" \
            --argjson available "$_available_json" \
            --argjson excluded "$_excluded_json" \
            --arg bundle_digest "$_index_digest" \
            '{ext:$ext, pg_major:$pg_major, ceiling:$ceiling, resolved:$resolved, available:$available, excluded:$excluded, bundle_digest:$bundle_digest}' \
            > "$_vs_lineage_file"
        log_success "Versionset artifact written: $_vs_lineage_file"

    done <<< "$ext_list"

    if [[ "$_failed" == "true" ]]; then
        return 1
    fi
    return 0
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

    # Handle finalize-multiarch mode (stage B: merge per-arch manifests, write artifact).
    # This is run AFTER both arch build legs have finished; does NOT build images.
    if [[ "$FINALIZE_MULTIARCH" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would merge per-arch manifests into multi-arch manifests for pg${major_ver}"
            exit 0
        fi
        local _fm_rc=0
        finalize_multiarch_manifests "$config_file" "$major_ver" "$container_dir" || _fm_rc=$?
        exit "$_fm_rc"
    fi

    # Check registry auth (unless local-only or dry-run)
    if [[ "$LOCAL_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        check_registry_auth || log_warning "Continuing without registry auth check"
    fi

    # Determine push mode once for all paths in main().
    # LOCAL_ONLY=true → local-only build, no push (recovery path).
    # PULL_ONLY=true  → pull-only build, no push (final pass writes local artifact).
    # NO_PUSH=true    → explicit no-push context (e.g. CI fork PR with read-only
    #                   package permissions); bundle and artifact are skipped.
    # do_push=false + not LOCAL_ONLY/PULL_ONLY → CI PR smoke: skip bundle + artifact.
    local do_push="true"
    [[ "$LOCAL_ONLY" == "true" ]] && do_push="false"
    [[ "$PULL_ONLY" == "true" ]] && do_push="false"
    [[ "${NO_PUSH:-false}" == "true" ]] && do_push="false"

    # Handle pull-only mode — returns 0 on success, propagates exit 1 from
    # build_tag_push_extensions on failure. The final versionset pass runs
    # after the return so every pull-only success path has artifacts too.
    if [[ "$PULL_ONLY" == "true" ]]; then
        handle_pull_only_mode "$config_file" "$major_ver" "$container_dir"
        local _fp_rc=0
        _emit_final_versionset_pass "$config_file" "$major_ver" "$container_dir" "${EXTENSION:-}" "$do_push" || _fp_rc=$?
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

        # Atomic pass: for each in-scope resolver-backed extension, compute
        # confirmed_available once, push the bundle from that set, then write the
        # artifact from the SAME set. Bundle and artifact are always in sync.
        # This covers both the "all-cached" and "all-DRY_RUN" sub-paths.
        # Pass do_push so the final pass honors the same push decision as the
        # rest of main() — prevents the all-cached path from pushing on CI PR smoke.
        local _fp_rc=0
        _emit_final_versionset_pass "$config_file" "$major_ver" "$container_dir" "${EXTENSION:-}" "$do_push" || _fp_rc=$?

        exit "$_fp_rc"
    fi

    log_info "Extensions to build: ${extensions_to_build[*]}"

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
    # Pass do_push so the final pass honors the same push decision as build_tag_push.
    local _fp_rc=0
    _emit_final_versionset_pass "$config_file" "$major_ver" "$container_dir" "${EXTENSION:-}" "$do_push" || _fp_rc=$?
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
