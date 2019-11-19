#!/usr/bin/env bash
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

targets=$(find -name "docker-compose.yml" | cut -d'/' -f2 )

help() {
  log_help help "This help"
  log_help "build <target> [version]" "Build <target> container using [version]"
  log_help "push <target> [version] " "Push built <target> container [version] to repository"
  echo
  log_help "<target>" "Can be one of: $(echo $targets| tr '\n' ' ')"
  log_help "[version]" "Existing version, by default it is set to latest (auto discover)"
}

build() {
  if [ ! -d "$1" ]; then
    log_error "$1 is not a valid target !"
  fi
  local target=$1
  pushd ${target}
  versions=$(./version.sh ${2:-latest})
  if [ -e "$versions" ]; then
    log_error "Version checking returned false, please ensure version is correct: $2"
  fi
  for version in $versions; do
    export VERSION=$version
    log_success "Building ${target} ${VERSION}"
    docker-compose build
  done
  popd
}

push() {
  if [ ! -d "$1" ]; then
    log_error "$1 is not a valid target !"
  fi
  local target=$1
  pushd ${target}
  versions=$(./version.sh ${2:-latest})
  if [ -e "$versions" ]; then
    log_error "Version checking returned false, please ensure version is correct: $2"
  fi
  for version in $versions; do
    export VERSION=$version
    log_success "Pushing ${target} ${VERSION}"
    docker-compose push
  done
  popd
}

case "$1" in
  push ) push $2 $3 ;;
  build ) build $2 $3 ;;
  * ) help ;;
esac
