#!/usr/bin/env bash

# We are assuming that we are in WORKDIR
HOST_UID=$(stat -c %u .)
HOST_GID=$(stat -c %g .)

# And we change ansible UID/GID according to the host UID/GID (discard stderr)
sudo usermod -u $HOST_UID ansible 2>/dev/null
sudo groupmod -g $HOST_GID ansible 2>/dev/null

# Chown working directory (/home/ansible/playbook) to `ansible` user
sudo chown -R ansible. .

# Show a nice intro message :)
ansible_env=$(echo $ANSIBLE_ENV|tr a-z A-Z)

boxes -d columns << eof
Launching oorabona/ansible Docker container in ${ansible_env} environment, welcome !
Ansible version is : $(ansible --version|head -1)
Running $(ansible --version|grep version)
eof

# Let's make some room after...
echo

# Run addon script before anything else (e.g: extra init steps)
if [[ -x "${ADDONSCRIPT}" ]]; then
  . "${ADDONSCRIPT}"
elif [[ ! -z "${ADDONSCRIPT}" ]]; then
  echo "Add-on script set to '${ADDONSCRIPT}' but not found/executable ! Aborting."
  exit 1
fi

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

if [ ! -z ${WAIT_BEFORE_EXIT} ]
then
  read -p "Press <ENTER> key to finish."
fi
