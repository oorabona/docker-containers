#!/usr/bin/env bash

export DOCKER_CLI_EXPERIMENTAL=enabled
export NPROC=$(nproc)
export DOCKERCOMPOSE="docker compose"
export DOCKEROPTS="${DOCKEROPTS:-}"

# Source shared logging utilities
source "$(dirname "$0")/helpers/logging.sh"

# Source focused utility scripts
source "$(dirname "$0")/scripts/check-version.sh"
source "$(dirname "$0")/scripts/build-container.sh"
source "$(dirname "$0")/scripts/push-container.sh"

# Source optional config files if they exist
[ -r "${CONFIG_MK:-}" ] && source "$CONFIG_MK"
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
  log_help "push <target> [version]" "Push to all registries (GHCR primary, Docker Hub secondary)"
  log_help "push ghcr <target> [version]" "Push to GHCR only (GitHub Container Registry)"
  log_help "push dockerhub <target> [version]" "Push to Docker Hub only"
  log_help "run <target> [version]" "Run built <target> container [version]"
  log_help "version [target]" "Show latest upstream version for a container"
  log_help "check-updates [target]" "Check for upstream updates (JSON output for automation)"
  log_help "sizes [target]" "Show image sizes (all or specific container)"
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

# Get manifest sizes from Docker Hub API (public, no auth needed)
get_dockerhub_sizes() {
  local username="$1"
  local image="$2"
  local tag="$3"

  local api_url="https://hub.docker.com/v2/repositories/${username}/${image}/tags/${tag}"
  local response
  response=$(curl -s --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null) || return 1

  # Check if we got an error response
  if echo "$response" | jq -e '.errinfo' >/dev/null 2>&1; then
    return 1
  fi

  # Extract architecture and size from images array
  echo "$response" | jq -r '.images[]? | "\(.architecture):\(.size)"' 2>/dev/null
}

# Get manifest sizes for GHCR using gh auth token
get_ghcr_sizes() {
  local image="$1"

  # Extract owner, repo and tag from image string (ghcr.io/owner/repo:tag)
  local owner repo tag
  owner=$(echo "$image" | cut -d'/' -f2)
  repo=$(echo "$image" | cut -d'/' -f3 | cut -d':' -f1)
  tag=$(echo "$image" | cut -d':' -f2)

  # Get gh token and exchange for GHCR registry token
  local gh_token
  gh_token=$(gh auth token 2>/dev/null) || return 1

  local registry_token
  registry_token=$(curl -s --connect-timeout 5 --max-time 10 \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${owner}/${repo}:pull" \
    -u "${owner}:${gh_token}" 2>/dev/null | jq -r '.token' 2>/dev/null)

  [[ -z "$registry_token" || "$registry_token" == "null" ]] && return 1

  # Get manifest list
  local manifest
  manifest=$(curl -s --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $registry_token" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/${owner}/${repo}/manifests/${tag}" 2>/dev/null)

  [[ -z "$manifest" ]] && return 1

  # Check for errors
  if echo "$manifest" | jq -e '.errors' >/dev/null 2>&1; then
    return 1
  fi

  # For each platform, fetch manifest and sum layer sizes
  if echo "$manifest" | jq -e '.manifests' >/dev/null 2>&1; then
    local manifests_data
    manifests_data=$(echo "$manifest" | jq -r '.manifests[] | "\(.platform.architecture):\(.digest)"' 2>/dev/null)

    while IFS=':' read -r arch digest_prefix digest_hash; do
      [[ -z "$arch" ]] && continue
      local full_digest="${digest_prefix}:${digest_hash}"
      local platform_manifest
      platform_manifest=$(curl -s --connect-timeout 5 --max-time 10 \
        -H "Authorization: Bearer $registry_token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://ghcr.io/v2/${owner}/${repo}/manifests/${full_digest}" 2>/dev/null)

      local total_size
      total_size=$(echo "$platform_manifest" | jq '[.config.size // 0] + [.layers[].size // 0] | add' 2>/dev/null)
      echo "${arch}:${total_size:-0}"
    done <<< "$manifests_data"
  else
    # Single manifest
    local total_size
    total_size=$(echo "$manifest" | jq '[.config.size // 0] + [.layers[].size // 0] | add' 2>/dev/null)
    echo "amd64:${total_size:-0}"
  fi
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
        sizes=$(get_dockerhub_sizes "$github_username" "$container" "$latest_tag" 2>/dev/null)
      else
        sizes=$(get_ghcr_sizes "$registry/$github_username/$container:$latest_tag" 2>/dev/null)
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
      . "$op"
    fi
    # Then proceed with buildx (whether or not custom script existed)
    do_buildx "$op" "$registry"
    return $?
  fi
  
  # For other operations, check for custom scripts or use docker-compose
  if [ -x "$op" ]; then
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
  local container=$(basename "$PWD")

  if [[ "$op" == "build" ]]; then
    # Check if container has variants (multi-image support)
    if container_has_variants "$container"; then
      log_info "Container $container has variants - building all variants..."
      build_container_variants "$container" "$VERSION"
    else
      # Use focused build utility for single-image containers
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

  if ! validate_target "$1"; then
    log_error "$1 is not a valid target (no Dockerfile found)!"
    exit 1
  fi
  local target=$1
  local wantedVersion=${2:-latest}
  local wantedTag=${3:-""}  # Optional: explicit tag (for variants, differs from version)
  pushd ${target}

  # Use focused version utility
  versions=$(get_build_version "$target" "$wantedVersion")
  if [ $? -ne 0 ]; then
    popd
    return 1
  fi

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
    local pattern
    if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
      current_version=$(../helpers/latest-docker-tag "oorabona/$container" "$pattern" 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
    else
      # Fallback: try common version pattern  
      current_version=$(../helpers/latest-docker-tag "oorabona/$container" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
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
  build ) make "$1" "${2:-}" "${3:-}" ;;
  push )
    # Handle: push <target>, push ghcr <target>, push dockerhub <target>
    if [[ "${2:-}" == "ghcr" || "${2:-}" == "dockerhub" ]]; then
      make "$1" "${2:-}" "${3:-}" "${4:-}"
    else
      make "$1" "${2:-}" "${3:-}"
    fi
    ;;
  run ) run "${2:-}" "${3:-}" ;;
  version ) shift; version "$@" ;;
  check-updates ) check_updates "${2:-}" ;;
  list ) list_containers ;;
  sizes ) show_sizes "${2:-}" ;;
  * ) help ;;
esac
