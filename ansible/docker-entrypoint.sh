#!/usr/bin/env bash

if [[ "$UID" != 0 ]]; then
  sudo -E $0 $(whoami) $(realpath .) $*
else
  user=$1; shift;
  gid=$(getent passwd $user|cut -d: -f4)
  group=$(getent group $gid|cut -d: -f1)
  path=$1; shift;

  # We are assuming that we have mount /home/ansible/playbook
  HOST_UID=$(stat -c %u $path)
  HOST_GID=$(stat -c %g $path)

  # We need to change UID/GID of created user in container.
  # And then chown user's home directory accordingly.
  # This should be enough when HOST_UID == UID but if that is not the case,
  # we will be casted out of sudo because when we are launched,
  # we already have a UID/GID associated with the process.
  # So we need to spawn a new shell with the correct UID/GID.

  usermod -u $HOST_UID $user 2>/dev/null
  groupmod -g $HOST_GID $group 2>/dev/null
  chown -R $user.$group $(getent passwd $user|cut -d: -f6)
  su - $user -c "/docker-run-cmd.sh $path $*"
fi
