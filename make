#!/usr/bin/env bash

export DOCKER_CLI_EXPERIMENTAL=enabled
export NPROC=$(nproc)
export DOCKERCOMPOSE="docker-compose"
export DOCKEROPTS="${DOCKEROPTS:-}"

# Helper functions
log_success() {
  echo -e "\033[32m>> $@\033[39m"
}

log_error() {
  >&2 echo -e "\033[31m>> $@\033[39m" && exit 1
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
  versions=$(./version.sh latest)
  if [ -e "$versions" ]; then
    log_error "Could not retrieve the latest version."
  else
    log_success "$versions"
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
  versions=$(./version.sh ${wantedVersion})
  if [ -e "$versions" ]; then
    log_error "Version checking returned false, please ensure version is correct: $2"
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
  * ) help ;;
esac
