#!/usr/bin/env bash

export DOCKER_CLI_EXPERIMENTAL=enabled
export NPROC=$(nproc)
export DOCKERCOMPOSE="docker compose"
export DOCKEROPTS="${DOCKEROPTS:-}"

# Helper functions
log_success() {
  echo -e "\033[32m>> $@\033[39m"
}

log_error() {
  >&2 echo -e "\033[31m>> $@\033[39m" && exit 1
}

log_warning() {
  echo -e "\033[33m>> $@\033[39m"
}

log_help() {
  printf "\033[36m%-25s\033[0m %s\n" "$1" "$2"
}

[ -r "$CONFIG_MK" ] && source "$CONFIG_MK"
[ -r "$DEPLOY_MK" ] && source "$DEPLOY_MK"

targets=$(find -name "Dockerfile" | cut -d'/' -f2 )

help() {
  echo Commands:
  log_help help "This help"
  log_help "build <target> [version]" "Build <target> container using [version]"
  log_help "push <target> [version]" "Push built <target> container [version] to repository"
  log_help "run <target> [version]" "Run built <target> container [version]"
  log_help "version <target>" "Get latest version of <target>"
  log_help "check-updates [target]" "Check for upstream updates (JSON output for automation)"
  echo
  echo Where:
  log_help "[version]" "Existing version, by default it is set to latest (auto discover)"
  echo
  echo List of possible targets:
  log_help "$(echo $targets| tr ' ' '\n')"
}

version() {
  if [ ! -d "$1" ]; then
    log_error "$1 is not a valid target !"
  fi
  local target=$1
  pushd ${target}
  versions=$(./version.sh latest 2>/dev/null)
  exit_code=$?
  if [ $exit_code -ne 0 ] || [ -z "$versions" ]; then
    log_error "Could not retrieve the latest version."
  else
    log_success "$versions"
  fi
  
  # Also check current version
  current_version=$(./version.sh current 2>/dev/null)
  current_exit_code=$?
  if [ $current_exit_code -eq 0 ] && [ -n "$current_version" ] && [ "$current_version" != "no-published-version" ]; then
    log_success "Current published version: $current_version"
  elif [ "$current_version" = "no-published-version" ]; then
    log_warning "No published version found (container not yet released)"
  else
    log_warning "Could not retrieve current published version"
  fi
  popd
}

run() {
  if [ ! -d "$1" ]; then
    log_error "$1 is not a valid target !"
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

make() {
  local op=$1 ; shift
  if [ ! -d "$1" ]; then
    log_error "$1 is not a valid target !"
  fi
  local target=$1
  local wantedVersion=${2:-latest}
  pushd ${target}
  versions=$(./version.sh ${wantedVersion} 2>/dev/null)
  exit_code=$?
  
  # Handle special cases
  if [ "$versions" = "no-published-version" ]; then
    log_warning "No published version found for $target, this will be an initial release"
    # For no-published-version, we'll use the latest upstream version
    versions=$(./version.sh latest 2>/dev/null)
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
    if [ ! -d "$target" ]; then
      log_error "$target is not a valid target!"
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
    
    # Get current and latest versions (clean up output)
    current_version=$(./version.sh current 2>/dev/null | head -1 | tr -d '\n' || echo "no-published-version")
    latest_version=$(./version.sh latest 2>/dev/null | head -1 | tr -d '\n' || echo "")
    
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

# Main entrypoint
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
  version ) version $2 ;;
  check-updates ) check_updates $2 ;;
  * ) help ;;
esac
