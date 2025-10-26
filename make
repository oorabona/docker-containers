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
  log_help list "List all available containers"
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

# List all available containers (one per line, for automation)
list_containers() {
  for target in $targets ; do
    echo "$target"
  done
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
  
  # For build and push operations, use buildx for multi-registry support
  if [[ "$op" == "build" || "$op" == "push" ]]; then
    # First, check if there's a custom executable script to set build args
    if [ -x "$op" ]; then
      . "$op"
    fi
    # Then proceed with buildx (whether or not custom script existed)
    do_buildx "$op"
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
  local container=$(basename "$PWD")
  
  if [[ "$op" == "build" ]]; then
    # Use focused build utility
    build_container "$container" "$VERSION" "$TAG"
  elif [[ "$op" == "push" ]]; then
    # Use focused push utility  
    push_container "$container" "$VERSION" "$TAG" "$WANTED"
  else
    log_error "Unknown operation: $op (use 'build' or 'push')"
    return 1
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
  
  # Use focused version utility
  versions=$(get_build_version "$target" "$wantedVersion")
  if [ $? -ne 0 ]; then
    popd
    return 1
  fi
  
  for version in $versions; do
    export WANTED=$wantedVersion VERSION=$version TAG=$version
    log_success "$op ${target} $WANTED (version: ${VERSION} tag: $TAG) | nproc: ${NPROC}"
    do_it $op
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

case "$1" in
  push|build ) make $1 $2 $3 ;;
  run ) run $2 $3 ;;
  version ) shift; version "$@" ;;
  check-updates ) check_updates $2 ;;
  list ) list_containers ;;
  * ) help ;;
esac
