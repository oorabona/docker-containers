#!/usr/bin/env bash

export DOCKER_CLI_EXPERIMENTAL=enabled
export NPROC=$(nproc)
export DOCKERCOMPOSE="docker compose"
export DOCKEROPTS="${DOCKEROPTS:-}"

# Helper functions
log_success() {
  >&2 echo -e "\033[32m>> $@\033[39m"
}

log_error() {
  >&2 echo -e "\033[31m>> $@\033[39m" && exit 1
}

log_warning() {
  >&2 echo -e "\033[33m>> $@\033[39m"
}

log_help() {
  printf "\033[36m%-25s\033[0m %s\n" "$1" "$2"
}

[ -r "$CONFIG_MK" ] && source "$CONFIG_MK"
[ -r "$DEPLOY_MK" ] && source "$DEPLOY_MK"

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
  log_help "build <target> [version]" "Build <target> container using [version] (latest|current|specific version)"
  log_help "push <target> [version]" "Push built <target> container [version] to repository"
  log_help "run <target> [version]" "Run built <target> container [version]"
  log_help "version [target]" "Show latest upstream version for a container"
  log_help "check-updates [target]" "Check for upstream updates (JSON output for automation)"
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

version() {
  local target="$1"
  
  if [[ -z "$target" ]]; then
    echo "Usage: version <target>" >&2
    exit 1
  fi
  
  if ! validate_target "$target"; then
    log_error "$target is not a valid target (no Dockerfile found)!"
    exit 1
  fi
  
  if [ ! -f "$target/version.sh" ]; then
    log_error "No version.sh script found in $target directory!"
    exit 1
  fi
  
  # Get the latest upstream version (version.sh now single-purpose)
  pushd "${target}" > /dev/null 2>&1
  local latest_version
  latest_version=$(./version.sh 2>/dev/null)
  local exit_code=$?
  
  # Validate the version output
  if [ $exit_code -eq 0 ] && [ -n "$latest_version" ] && [ "$latest_version" != "unknown" ] && [ "$latest_version" != "no-published-version" ]; then
    echo "$latest_version"
  else
    log_error "Failed to get latest upstream version for $target"
    popd > /dev/null 2>&1
    echo "unknown"
    exit 1
  fi
  
  # Check current published version using container-specific pattern
  local current_version
  local pattern
  if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
    current_version=$(../helpers/latest-docker-tag "oorabona/$target" "$pattern" 2>/dev/null)
  else
    # Fallback: try common version pattern
    current_version=$(../helpers/latest-docker-tag "oorabona/$target" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 2>/dev/null)
  fi
  
  if [ -n "$current_version" ]; then
    log_success "Current published version: $current_version"
  else
    log_warning "No published version found (container not yet released)"
  fi
  
  popd > /dev/null 2>&1
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
  
  # For build and push operations, use buildx for multi-registry support
  if [[ "$op" == "build" || "$op" == "push" ]]; then
    do_buildx "$op"
    return $?
  fi
  
  # For other operations, use docker-compose as before
  if [ -r "docker-compose.yml" ]
  then
    $DOCKERCOMPOSE $op $DOCKEROPTS
  elif [ -r "compose.yml" ]
  then
    $DOCKERCOMPOSE -f compose.yml $op $DOCKEROPTS
  elif [ -x "$op" ]
  then
    . "$op"
  else
    log_error "No ${op} script found in $PWD, aborting."
  fi
}

# Check if multi-platform builds are supported (QEMU emulation)
check_multiplatform_support() {
  # Cache the result to avoid repeated checks
  if [[ -n "${MULTIPLATFORM_SUPPORTED:-}" ]]; then
    return $([ "$MULTIPLATFORM_SUPPORTED" = "true" ] && echo 0 || echo 1)
  fi
  
  # Method 1: Check for QEMU ARM64 emulation via binfmt_misc
  if [[ -f "/proc/sys/fs/binfmt_misc/qemu-aarch64" ]] || 
     [[ -f "/proc/sys/fs/binfmt_misc/qemu-arm64" ]]; then
    MULTIPLATFORM_SUPPORTED="true"
    return 0
  fi
  
  # Method 2: Check docker buildx supported platforms  
  if command -v docker >/dev/null 2>&1; then
    local platforms
    if platforms=$(docker buildx inspect --bootstrap 2>/dev/null | grep -i "platforms:" 2>/dev/null); then
      if echo "$platforms" | grep -q "linux/arm64"; then
        MULTIPLATFORM_SUPPORTED="true"
        return 0
      fi
    fi
  fi
  
  # No multi-platform support found
  MULTIPLATFORM_SUPPORTED="false"
  return 1
}

do_buildx() {
  local op=$1
  local container=$(basename "$PWD")
  local github_username="${GITHUB_REPOSITORY_OWNER:-oorabona}"
  
  # Image names for multi-registry push
  local dockerhub_image="docker.io/$github_username/$container"
  local ghcr_image="ghcr.io/$github_username/$container"
  
  # Determine platform support proactively
  local platforms
  if check_multiplatform_support; then
    platforms="linux/amd64,linux/arm64"
    log_success "Building $container:$TAG using buildx (multi-platform: AMD64 + ARM64)"
  else
    platforms="linux/amd64"
    log_success "Building $container:$TAG using buildx (AMD64 only - no QEMU emulation detected)"
  fi
  
  local build_args=""
  
  # Add common build arguments if they're set
  [[ -n "$VERSION" ]] && build_args="$build_args --build-arg VERSION=$VERSION"
  [[ -n "$NPROC" ]] && build_args="$build_args --build-arg NPROC=$NPROC"
  
  if [[ "$op" == "build" ]]; then
    # Single build attempt with determined platform support
    docker buildx build \
      --platform "$platforms" \
      $build_args \
      -t "$dockerhub_image:$TAG" \
      -t "$ghcr_image:$TAG" \
      . || {
      log_error "Build failed for $container:$TAG"
      return 1
    }
    
  elif [[ "$op" == "push" ]]; then
    # Single build and push attempt with determined platform support
    docker buildx build \
      --platform "$platforms" \
      --push \
      $build_args \
      -t "$dockerhub_image:$TAG" \
      -t "$ghcr_image:$TAG" \
      . || {
      log_error "Build and push failed for $container:$TAG"
      return 1
    }
    
    log_success "✅ Successfully pushed to:"
    log_success "  🐳 Docker Hub: $dockerhub_image:$TAG"
    log_success "  📦 GHCR: $ghcr_image:$TAG"
  fi
}

make() {
  local op=$1 ; shift
  if ! validate_target "$1"; then
    log_error "$1 is not a valid target (no Dockerfile found)!"
    exit 1
  fi
  local target=$1
  local wantedVersion=${2:-latest}
  pushd ${target}
  
  # Handle version detection logic properly
  if [ "$wantedVersion" = "latest" ]; then
    # Get latest upstream version
    versions=$(./version.sh 2>/dev/null)
    exit_code=$?
  elif [ "$wantedVersion" = "current" ]; then
    # Get current published version using container-specific pattern
    local pattern
    if pattern=$(./version.sh --registry-pattern 2>/dev/null); then
      versions=$(../helpers/latest-docker-tag "oorabona/$target" "$pattern" 2>/dev/null || echo "unknown")
    else
      # Fallback: try common version pattern
      versions=$(../helpers/latest-docker-tag "oorabona/$target" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 2>/dev/null || echo "unknown")
    fi
    exit_code=$?
  else
    # Use the specific version provided directly
    versions="$wantedVersion"
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
      popd
      return 1
    fi
  elif [ $exit_code -ne 0 ] || [ -z "$versions" ]; then
    log_error "Version checking returned false, please ensure version is correct: $wantedVersion"
    popd
    return 1
  fi
  
  for version in $versions; do
    export WANTED=$wantedVersion VERSION=$version TAG=$version
    log_success "$op ${target} $WANTED (version: ${VERSION} tag: $TAG) | nproc: ${NPROC}"
    do_it $op
  done
  if [ "$wantedVersion" == "latest" ]
  then
    export TAG=latest
    do_it $op
  fi
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

case "$1" in
  push|build ) make $1 $2 $3 ;;
  run ) run $2 $3 ;;
  version ) shift; version "$@" ;;
  check-updates ) check_updates $2 ;;
  * ) help ;;
esac
