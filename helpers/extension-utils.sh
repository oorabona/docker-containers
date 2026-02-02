#!/bin/bash
# Shared utilities for extension building and management
# Used by scripts/build-extensions.sh
# Works both locally and in GitHub Actions
#
# New approach: Build and push extension images to registry
# Main Dockerfile uses COPY --from=ghcr.io/... to get extensions

set -euo pipefail

# Colors and log functions (skip if already defined by logging.sh)
if ! declare -p RED &>/dev/null; then
    if [[ -t 1 ]] && [[ -z "${CI:-}" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' NC=''
    fi
fi
declare -F log_info &>/dev/null || log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
declare -F log_ok &>/dev/null   || log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
declare -F log_warn &>/dev/null || log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
declare -F log_error &>/dev/null || log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Get repository owner from git remote or environment
get_repo_owner() {
    if [[ -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
        echo "$GITHUB_REPOSITORY_OWNER"
    elif [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        echo "${GITHUB_REPOSITORY%%/*}"
    else
        git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]([^/]+)/.*#\1#'
    fi
}

# Get registry URL (default to ghcr.io)
get_registry() {
    echo "${EXTENSION_REGISTRY:-ghcr.io}"
}

# Generate extension image name
# Format: ghcr.io/<owner>/ext-<name>:pg<version>-<ext_version>
ext_image_name() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"
    local registry="${4:-$(get_registry)}"
    local owner="${5:-$(get_repo_owner)}"

    echo "${registry}/${owner}/ext-${ext_name}:pg${pg_major}-${ext_version}"
}

# Generate local image name (for building)
ext_local_image_name() {
    local ext_name="$1"
    local pg_major="$2"

    echo "localhost/ext-builder-${ext_name}:pg${pg_major}"
}

# Check if gh CLI is available and authenticated
check_gh_auth() {
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) not found. Install with: brew install gh"
        return 1
    fi

    if ! gh auth status &>/dev/null; then
        log_error "GitHub CLI not authenticated. Run: gh auth login"
        return 1
    fi

    return 0
}

# Check if docker/podman is logged into registry
check_registry_auth() {
    local registry="${1:-$(get_registry)}"

    # In CI, authentication is handled by workflow
    if [[ -n "${CI:-}" ]]; then
        return 0
    fi

    # Check if we can access the registry
    if docker login --get-login "$registry" &>/dev/null; then
        return 0
    fi

    log_warn "Not logged into $registry. Run: docker login $registry"
    return 1
}

# Check if an image exists in the registry
image_exists_in_registry() {
    local image="$1"

    # Use docker manifest inspect (works with both Docker and Podman)
    if docker manifest inspect "$image" &>/dev/null; then
        return 0
    fi

    # Fallback: try skopeo if available
    if command -v skopeo &>/dev/null; then
        if skopeo inspect "docker://${image}" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Parse extension config using yq
ext_config() {
    local ext_name="$1"
    local key="$2"
    local config_file="$3"

    if ! command -v yq &>/dev/null; then
        log_error "yq not found"
        return 1
    fi

    yq -r ".extensions.${ext_name}.${key} // \"\"" "$config_file"
}

# List extensions from config, sorted by priority
# Excludes disabled extensions (disabled: true)
# If pg_version is provided, also excludes extensions with max_pg_version < pg_version
list_extensions_by_priority() {
    local config_file="$1"
    local pg_version="${2:-}"

    if [[ -n "$pg_version" ]]; then
        pgver="$pg_version" yq -r '
            [.extensions | to_entries[]
             | select(.value.disabled == true | not)
             | select((.value.max_pg_version // 999) >= env(pgver))]
            | sort_by(.value.priority // 99)
            | .[].key
        ' "$config_file"
    else
        yq -r '.extensions | to_entries | map(select(.value.disabled == true | not)) | sort_by(.value.priority // 99) | .[].key' "$config_file"
    fi
}

# Get PostgreSQL major version from full version string
pg_major_version() {
    local full_version="$1"
    echo "$full_version" | cut -d. -f1
}

# Build extension image
build_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local ext_repo="$3"
    local pg_major="$4"
    local dockerfile="$5"
    local context_dir="$6"

    local local_tag
    local_tag=$(ext_local_image_name "$ext_name" "$pg_major")

    log_info "Building $ext_name $ext_version for PostgreSQL $pg_major"

    docker build \
        -f "$dockerfile" \
        -t "$local_tag" \
        --build-arg MAJOR_VERSION="$pg_major" \
        --build-arg EXT_VERSION="$ext_version" \
        --build-arg EXT_REPO="$ext_repo" \
        "$context_dir"

    log_ok "Built: $local_tag"
}

# Tag extension image with registry name (for COPY --from= to find it)
tag_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"

    local local_tag
    local_tag=$(ext_local_image_name "$ext_name" "$pg_major")

    local remote_tag
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")

    log_info "Tagging $local_tag -> $remote_tag"
    if ! docker tag "$local_tag" "$remote_tag"; then
        log_error "Failed to tag $local_tag -> $remote_tag"
        return 1
    fi

    log_ok "Tagged: $remote_tag"
}

# Push extension image to registry (assumes already tagged)
push_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"

    local remote_tag
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")

    log_info "Pushing $remote_tag"
    if ! docker push "$remote_tag"; then
        log_error "Failed to push $remote_tag"
        return 1
    fi

    log_ok "Pushed: $remote_tag"
}

# ============================================================================
# Flavor-aware Dockerfile generation
# Instead of building N bundle images, we template the main Dockerfile
# to only include FROM/COPY for extensions relevant to each flavor+PG version
# ============================================================================

# Get list of extensions for a flavor, filtered by PG version compatibility
# Excludes disabled extensions and those exceeding max_pg_version
get_flavor_extensions() {
    local config_file="$1"
    local flavor="$2"
    local pg_major="$3"

    pgver="$pg_major" flav="$flavor" yq -r '
        . as $root |
        .flavors[env(flav)] // [] | .[] | . as $ext |
        select(
            ($root.extensions[$ext].disabled == true | not) and
            (($root.extensions[$ext].max_pg_version // 999) >= env(pgver))
        )
    ' "$config_file"
}

# Generate a Dockerfile from a template by injecting extension FROM/COPY blocks
# Template must contain markers:
#   # @@EXTENSION_STAGES@@   → replaced by FROM ext-* AS ext-* lines
#   # @@EXTENSION_COPIES@@   → replaced by COPY --from=ext-* lines
#
# Usage: generate_dockerfile <config_file> <template> <flavor> <pg_major> [registry] [owner]
generate_dockerfile() {
    local config_file="$1"
    local template="$2"
    local flavor="$3"
    local pg_major="$4"
    local registry="${5:-$(get_registry)}"
    local owner="${6:-$(get_repo_owner)}"

    # Get filtered extension list for this flavor + PG version
    local extensions
    extensions=$(get_flavor_extensions "$config_file" "$flavor" "$pg_major")

    # Build the FROM stages block
    local stages_block=""
    local copies_block=""

    if [[ -n "$extensions" ]]; then
        while IFS= read -r ext_name; do
            [[ -z "$ext_name" ]] && continue

            local ext_version
            ext_version=$(ext_config "$ext_name" "version" "$config_file")
            local image="${registry}/${owner}/ext-${ext_name}:pg${pg_major}-${ext_version}"

            stages_block+="FROM ${image} AS ext-${ext_name}"$'\n'
            copies_block+="COPY --from=ext-${ext_name} /output/extension/ /tmp/ext/${ext_name}/extension/"$'\n'
            copies_block+="COPY --from=ext-${ext_name} /output/lib/ /tmp/ext/${ext_name}/lib/"$'\n'
        done <<< "$extensions"
    fi

    # Replace markers in template line by line
    while IFS= read -r line; do
        case "$line" in
            *'@@EXTENSION_STAGES@@'*)
                [[ -n "$stages_block" ]] && printf '%s' "$stages_block"
                ;;
            *'@@EXTENSION_COPIES@@'*)
                [[ -n "$copies_block" ]] && printf '%s' "$copies_block"
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done < "$template"
}

# Pull extension image from registry
pull_ext_image() {
    local ext_name="$1"
    local ext_version="$2"
    local pg_major="$3"

    local remote_tag
    remote_tag=$(ext_image_name "$ext_name" "$ext_version" "$pg_major")

    log_info "Pulling $remote_tag"
    docker pull "$remote_tag"

    log_ok "Pulled: $remote_tag"
}

