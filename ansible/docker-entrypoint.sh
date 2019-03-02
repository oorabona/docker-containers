#!/usr/bin/env bash

# We are assuming that we are in WORKDIR
HOST_UID=$(stat -c %u .)
HOST_GID=$(stat -c %g .)

# And we change ansible UID/GID according to the host UID/GID
sudo usermod -u $HOST_UID ansible
sudo groupmod -g $HOST_GID ansible

# Chown working directory (/home/ansible/playbook) to `ansible` user
sudo chown -R ansible. .

case "$1" in
  playbook|vault )
    shift
    ansible-${1} $@
    ;;
  run-script )
    shift
    . "$@"
    ;;
  * )
    exec "$@"
esac

if [ ! -z ${DEBUG} ]
then
  read -p "DEBUG environment variable set to ${DEBUG} ... Press <ENTER> key to finish."
fi
