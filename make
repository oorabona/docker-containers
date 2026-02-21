#!/usr/bin/env bash

export DOCKER_CLI_EXPERIMENTAL=enabled
NPROC=$(nproc)
export NPROC
export DOCKERCOMPOSE="docker compose"
export DOCKEROPTS="${DOCKEROPTS:-}"

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"
source "$(dirname "$0")/helpers/registry-utils.sh"

# Source focused utility scripts
source "$(dirname "$0")/scripts/check-version.sh"
source "$(dirname "$0")/scripts/build-container.sh"
source "$(dirname "$0")/scripts/push-container.sh"

# Source optional config files if they exist
# shellcheck disable=SC1090
[ -r "${CONFIG_MK:-}" ] && source "$CONFIG_MK"
# shellcheck disable=SC1090
[ -r "${DEPLOY_MK:-}" ] && source "$DEPLOY_MK"

targets=$(find -maxdepth 2 -name "Dockerfile" | cut -d'/' -f2 | sort -u)

# Validate if a target is valid (has a Dockerfile)
validate_target() {
  local target="$1"
  if [[ -z "$target" ]]; then
    return 1
  fi
  
  if [[ ! -d "$target" ]]; then
    return 1
  fi
  
  if [[ ! -f "$target/Dockerfile" ]]; then
    return 1
  fi
  
  return 0
}

help() {
  echo Commands:
  log_help help "This help"
  log_help list "List all available containers"
  log_help "build <target> [version]" "Build <target> container using [version] (latest|current|specific version)"
  log_help "build-extensions <target> [version] [--local-only]" "Build (and push) extensions for <target>"
  log_help "push <target> [version]" "Push to all registries (GHCR primary, Docker Hub secondary)"
  log_help "push ghcr <target> [version]" "Push to GHCR only (GitHub Container Registry)"
  log_help "push dockerhub <target> [version]" "Push to Docker Hub only"
  log_help "run <target> [version]" "Run built <target> container [version]"
  log_help "version [target]" "Show latest upstream version for a container"
  log_help "check-updates [target]" "Check for upstream updates (JSON output for automation)"
  log_help "check-dep-updates [target]" "Check 3rd party dependency versions for updates"
  log_help "sizes [target]" "Show image sizes (all or specific container)"
  log_help "lineage [target]" "Show build lineage JSON (all or specific container)"
  log_help "list-builds <target> [version]" "List all builds for a container (CI-ready JSON)"
  echo
  echo Where:
  log_help "[version]" "Version to use - defaults to 'latest' (auto-discover from upstream)"
  log_help "  latest" "Upstream version (fetched from source project/registry)"
  log_help "  current" "Published version (what we currently have built/tagged)"
  log_help "  <specific>" "Explicit version string (e.g., '1.2.3', '2024-01-15')"
  echo
  echo List of possible targets:
  log_help "$(echo $targets| tr ' ' '\n')"
}

# List all available containers (one per line, for automation)
list_containers() {
  for target in $targets ; do
    echo "$target"
  done
}

# Format bytes to human readable
format_size() {
  local bytes=$1
  if [[ -z "$bytes" || "$bytes" == "null" || "$bytes" -eq 0 ]]; then
    echo "-"
    return
  fi
  if [[ $bytes -ge 1073741824 ]]; then
    printf "%.1fGB" "$(echo "scale=1; $bytes/1073741824" | bc)"
  elif [[ $bytes -ge 1048576 ]]; then
    printf "%.1fMB" "$(echo "scale=1; $bytes/1048576" | bc)"
  elif [[ $bytes -ge 1024 ]]; then
    printf "%.1fKB" "$(echo "scale=1; $bytes/1024" | bc)"
  else
    printf "%dB" "$bytes"
  fi
}

# Thin wrappers over helpers/registry-utils.sh for backward compatibility
# with show_sizes() calling convention

# Get manifest sizes from Docker Hub API
# Usage: get_dockerhub_sizes "username" "repo" "tag"
get_dockerhub_sizes() {
  dockerhub_get_tag_sizes "$@"
}

# Get manifest sizes for GHCR
# Usage: get_ghcr_sizes "ghcr.io/owner/repo:tag"
get_ghcr_sizes() {
  local image="$1"
  # Parse full image string into owner/repo and tag
  local image_path tag
  image_path=$(echo "$image" | sed 's|ghcr.io/||' | cut -d':' -f1)
  tag=$(echo "$image" | cut -d':' -f2)
  ghcr_get_manifest_sizes "$image_path" "$tag"
}

# Check 3rd party dependency versions
check_dep_updates() {
  local target=${1:-""}
  local args=("--summary")

  if [ -n "$target" ]; then
    args+=("$target")
  else
    args+=("--all")
  fi

  "$(dirname "$0")/scripts/check-dependency-versions.sh" "${args[@]}"
}

# Show image sizes for containers
show_sizes() {
  local target="$1"
  local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
  local registries=("ghcr.io" "docker.io")

  echo ""
  echo "Container Image Sizes by Registry and Architecture"
  echo "==================================================="
  echo ""

  # Determine which containers to show
  local containers_to_show
  if [[ -n "$target" ]]; then
    if ! validate_target "$target"; then
      log_error "$target is not a valid target!"
      return 1
    fi
    containers_to_show="$target"
  else
    containers_to_show="$targets"
  fi

  for container in $containers_to_show; do
    echo "📦 $container"
    echo "   ├── Local:"

    # Show local images (collect in variable to avoid subshell)
    local local_images
    local_images=$(docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" 2>/dev/null \
      | grep -E "(ghcr.io|docker.io|localhost)/$github_username/$container:" || true)

    if [[ -n "$local_images" ]]; then
      while IFS=$'\t' read -r image size; do
        echo "   │   └── $image → $size"
      done <<< "$local_images"
    else
      echo "   │   └── (not built locally)"
    fi

    # Show registry sizes
    echo "   └── Registries:"

    # Get latest tag from version.sh if available, fallback to "latest"
    local latest_tag
    if [[ -f "$container/version.sh" ]]; then
      latest_tag=$("$container/version.sh" 2>/dev/null | head -1)
    fi
    [[ -z "$latest_tag" ]] && latest_tag="latest"

    local reg_count=${#registries[@]}
    local reg_idx=0
    for registry in "${registries[@]}"; do
      reg_idx=$((reg_idx + 1))
      local display_registry
      [[ "$registry" == "ghcr.io" ]] && display_registry="GHCR" || display_registry="Docker Hub"

      local tree_prefix="├──"
      local sub_prefix="│  "
      [[ $reg_idx -eq $reg_count ]] && tree_prefix="└──" && sub_prefix="   "

      # Get manifest sizes using appropriate method per registry
      local sizes=""
      if [[ "$registry" == "docker.io" ]]; then
        sizes=$(get_dockerhub_sizes "$github_username" "$container" "$latest_tag" 2>/dev/null) || true
      else
        sizes=$(get_ghcr_sizes "$registry/$github_username/$container:$latest_tag" 2>/dev/null) || true
      fi

      if [[ -n "$sizes" && "$sizes" != *"null"* ]]; then
        echo "       $tree_prefix $display_registry ($latest_tag):"
        local line_count
        line_count=$(echo "$sizes" | grep -c . || echo "0")
        local line_idx=0
        while IFS=':' read -r arch size_bytes; do
          [[ -z "$arch" || "$arch" == "null" ]] && continue
          line_idx=$((line_idx + 1))
          local size_human
          size_human=$(format_size "$size_bytes")
          local item_prefix="├──"
          [[ $line_idx -ge $line_count ]] && item_prefix="└──"
          echo "       $sub_prefix  $item_prefix $arch: $size_human"
        done <<< "$sizes"
      else
        echo "       $tree_prefix $display_registry ($latest_tag): ✗"
      fi
    done
    echo ""
  done

  echo "Legend: Local = uncompressed | Registry = compressed | ✗ = not published"
}

version() {
  local target="$1"
  
  if [[ -z "$target" ]]; then
    echo "Usage: version <target>" >&2
    exit 1
  fi
  
  # Use focused version checking utility
  check_container_version "$target"
}

run() {
  if ! validate_target "$1"; then
    log_error "$1 is not a valid target (no Dockerfile found)!"
    exit 1
  fi
  local target=$1
  local wantedVersion=${2:-latest}
  pushd ${target}
  log_success "Running ${target} ${wantedVersion}"
  TAG=${wantedVersion} $DOCKERCOMPOSE run $DOCKEROPTS --rm ${target}
  popd
}

do_it() {
  local op=$1
  local registry=${2:-""}

  # For build and push operations, use buildx for multi-registry support
  if [[ "$op" == "build" || "$op" == "push" ]]; then
    # First, check if there's a custom executable script to set build args
    if [ -x "$op" ]; then
      # shellcheck disable=SC1090
      . "$op"
    fi
    # Then proceed with buildx (whether or not custom script existed)
    do_buildx "$op" "$registry"
    return $?
  fi

  # For other operations, check for custom scripts or use docker-compose
  if [ -x "$op" ]; then
    # shellcheck disable=SC1090
    . "$op"
    return $?
  elif [ -r "docker-compose.yml" ]; then
    $DOCKERCOMPOSE $op $DOCKEROPTS
  elif [ -r "compose.yml" ]; then
    $DOCKERCOMPOSE -f compose.yml $op $DOCKEROPTS
  else
    log_error "No ${op} script found in $PWD, aborting."
  fi
}

do_buildx() {
  local op=$1
  local registry=${2:-""}
  local container
  container=$(basename "$PWD")

  if [[ "$op" == "build" ]]; then
    if [[ -n "${FLAVOR:-}" ]]; then
      # Single-flavor build (CI mode or explicit --flavor)
      log_info "Building $container with flavor: $FLAVOR"
      build_container "$container" "$VERSION" "$TAG" "$FLAVOR" "${DOCKERFILE:-Dockerfile}"
    elif container_has_variants "$container"; then
      # Full variant expansion (local build)
      # VERSION may be a full version (e.g., "18.1-alpine") but variants.yaml
      # uses major version tags (e.g., "18"). Resolve before calling.
      local major_ver
      major_ver=$(resolve_major_version "$PWD" "$VERSION")
      log_info "Container $container has variants - building all variants for version $major_ver..."
      build_container_variants "$container" "$major_ver"
    else
      # Simple container (no variants)
      build_container "$container" "$VERSION" "$TAG"
    fi
  elif [[ "$op" == "push" ]]; then
    # Use focused push utilities with registry selection
    case "$registry" in
      ghcr)
        push_ghcr "$container" "$VERSION" "$TAG" "$WANTED"
        ;;
      dockerhub)
        push_dockerhub "$container" "$VERSION" "$TAG" "$WANTED"
        ;;
      *)
        # Default: push to all registries (GHCR primary, Docker Hub secondary)
        push_container "$container" "$VERSION" "$TAG" "$WANTED"
        ;;
    esac
  else
    log_error "Unknown operation: $op (use 'build' or 'push')"
    return 1
  fi
}

make() {
  local op=$1 ; shift
  local registry=""

  # Check if first arg is a registry name (ghcr or dockerhub)
  if [[ "$1" == "ghcr" || "$1" == "dockerhub" ]]; then
    registry=$1
    shift
  fi

  # Parse named args (--flavor, --dockerfile) from remaining args
  local positional_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flavor)
        [[ -z "${2:-}" || "${2:-}" == --* ]] && { log_error "--flavor requires a value"; return 1; }
        export FLAVOR="$2"
        shift 2
        ;;
      --dockerfile)
        [[ -z "${2:-}" || "${2:-}" == --* ]] && { log_error "--dockerfile requires a value"; return 1; }
        export DOCKERFILE="$2"
        shift 2
        ;;
      *)
        positional_args+=("$1")
        shift
        ;;
    esac
  done
  if [[ ${#positional_args[@]} -gt 0 ]]; then
    set -- "${positional_args[@]}"
  else
    set --
  fi

  if ! validate_target "$1"; then
    log_error "$1 is not a valid target (no Dockerfile found)!"
    exit 1
  fi
  local target=$1
  local wantedVersion=${2:-latest}
  local wantedTag=${3:-""}  # Optional: explicit tag (for variants, differs from version)

  # Use focused version utility (before pushd, since get_build_version does its own pushd)
  local versions
  versions=$(get_build_version "$target" "$wantedVersion")
  if [ $? -ne 0 ]; then
    return 1
  fi

  pushd ${target}

  for version in $versions; do
    # Use explicit tag if provided, otherwise derive from version
    local effective_tag="${wantedTag:-$version}"
    export WANTED=$wantedVersion VERSION=$version TAG=$effective_tag
    if [[ -n "$registry" ]]; then
      log_success "$op $registry ${target} $WANTED (version: ${VERSION} tag: $TAG) | nproc: ${NPROC}"
    else
      log_success "$op ${target} $WANTED (version: ${VERSION} tag: $TAG) | nproc: ${NPROC}"
    fi
    do_it $op "$registry"
  done
  popd
}

check_updates() {
  local target=${1:-""}
  local output_json="[]"
  
  # Determine targets to check
  local check_targets
  if [ -n "$target" ]; then
    if ! validate_target "$target"; then
      log_error "$target is not a valid target (no Dockerfile found)!"
      exit 1
    fi
    check_targets="$target"
  else
    check_targets="$targets"
  fi
  
  # Check each target
  for container in $check_targets; do
    if [ ! -f "$container/version.sh" ]; then
      continue # Skip containers without version.sh
    fi
    
    pushd "$container" > /dev/null
    
    # Get current and latest versions using container-specific patterns
    # Query GHCR (primary registry) to avoid stale Docker Hub data causing duplicate PRs
    local pattern
    if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
      current_version=$(../helpers/latest-docker-tag "ghcr.io/oorabona/$container" "$pattern" 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
    else
      # Fallback: try common version pattern
      current_version=$(../helpers/latest-docker-tag "ghcr.io/oorabona/$container" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
    fi
    latest_version=$(./version.sh 2>/dev/null | head -1 | tr -d '\n' || echo "")
    
    # Determine update status
    local update_available="false"
    local status="up_to_date"
    
    if [ "$current_version" = "no-published-version" ]; then
      if [ -n "$latest_version" ]; then
        update_available="true"
        status="new-container"
      fi
    elif [ "$current_version" != "$latest_version" ] && [ -n "$latest_version" ]; then
      update_available="true"
      status="update-available"
    fi
    
    # Build JSON object for this container
    container_json=$(jq -n \
      --arg container "$container" \
      --arg current "$current_version" \
      --arg latest "$latest_version" \
      --argjson update_available "$update_available" \
      --arg status "$status" \
      '{
        container: $container,
        current_version: $current,
        latest_version: $latest,
        update_available: $update_available,
        status: $status
      }')
    
    # Add to output array
    output_json=$(echo "$output_json" | jq ". + [$container_json]")
    
    popd > /dev/null
  done
  
  # Output the JSON array
  echo "$output_json"
}

# Build extensions for a container (wrapper for scripts/build-extensions.sh)
# Usage: build_extensions <target> [version] [--local-only]
build_extensions() {
  local target="$1"
  local version="${2:-}"
  local local_only=""

  # Check for --local-only flag in any position
  for arg in "$@"; do
    if [[ "$arg" == "--local-only" ]]; then
      local_only="--local-only"
    fi
  done

  # Validate target
  if ! validate_target "$target"; then
    log_error "$target is not a valid target (no Dockerfile found)!"
    return 1
  fi

  # Check if container has extensions config
  if [[ ! -f "$target/extensions/config.yaml" ]]; then
    log_warning "$target has no extensions configuration (extensions/config.yaml)"
    return 0
  fi

  # Build version args
  local version_args=""
  if [[ -n "$version" && "$version" != "--local-only" ]]; then
    version_args="--major-version $version"
  fi

  # Call the extensions build script
  log_info "Building extensions for $target ${version:+(version: $version)} ${local_only:+(local only)}"
  ./scripts/build-extensions.sh "$target" $version_args $local_only
}

# List all builds for a container (CI-ready JSON output)
# Usage: list_builds <target> [version]
list_builds() {
    local target="$1"
    local wanted_version="${2:-latest}"

    if ! validate_target "$target"; then
        log_error "$target is not a valid target!" >&2
        return 1
    fi

    local version
    version=$(get_build_version "$target" "$wanted_version")
    if [[ $? -ne 0 || -z "$version" ]]; then
        log_error "Failed to resolve version for $target" >&2
        return 1
    fi

    list_container_builds "$target" "$version"
}

show_lineage() {
  local target="${1:-}"
  local lineage_dir=".build-lineage"

  if [[ ! -d "$lineage_dir" ]]; then
    log_warning "No build lineage data found. Run './make build' first."
    return 0
  fi

  if [[ -n "$target" ]]; then
    # Show lineage for specific container
    local files
    files=$(find "$lineage_dir" -name "${target}*.json" 2>/dev/null)
    if [[ -z "$files" ]]; then
      log_warning "No lineage data for '$target'"
      return 0
    fi
    for f in $files; do
      jq '.' "$f"
    done
  else
    # Show summary of all containers
    echo "Build Lineage Summary"
    echo "====================="
    for f in "$lineage_dir"/*.json; do
      [[ -f "$f" ]] || continue
      jq -r '"  \(.container):\(.tag) | \(.platform) | \(.built_at) | digest:\(.build_digest)"' "$f"
    done
  fi
}

# If docker(-)compose is not found, just exit immediately
if [ ! -x "$(command -v docker-compose)" ]; then
  docker compose 2>/dev/null 1>&2
  if [ $? -ne 0 ]; then
    log_error "docker(-)compose is not installed, aborting."
  fi
  log_success "Found 'docker compose', continuing."
  DOCKERCOMPOSE="docker compose"
else
  log_success "Found 'docker-compose', continuing."
fi

case "${1:-}" in
  build ) make "$@" ;;
  build-extensions ) shift; build_extensions "$@" ;;
  push ) make "$@" ;;
  run ) run "${2:-}" "${3:-}" ;;
  version ) shift; version "$@" ;;
  check-updates ) check_updates "${2:-}" ;;
  check-dep-updates ) check_dep_updates "${2:-}" ;;
  list ) list_containers ;;
  sizes ) show_sizes "${2:-}" ;;
  lineage ) show_lineage "${2:-}" ;;
  list-builds ) shift; list_builds "$@" ;;
  * ) help ;;
esac
