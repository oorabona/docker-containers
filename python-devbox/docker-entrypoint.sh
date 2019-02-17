#!/usr/bin/env bash

# We are assuming that we are in WORKDIR
HOST_UID=$(stat -c %u .)
HOST_GID=$(stat -c %g .)

# And we change ansible UID/GID according to the host UID/GID
sudo usermod -u $HOST_UID app
sudo groupmod -g $HOST_GID app

exec "$@"
