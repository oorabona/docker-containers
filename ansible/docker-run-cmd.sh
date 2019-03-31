#!/usr/bin/env bash

# Show a nice intro message :)
ansible_env=$(echo $ANSIBLE_ENV|tr a-z A-Z)

boxes -d columns << eof
Launching oorabona/ansible Docker container in ${ansible_env} environment, welcome !
Ansible version is : $(ansible --version|head -1)
Running $(ansible --version|grep version)
eof

# Let's make some room after...
echo

path=$1; shift;
cd $path

# Run addon script before anything else (e.g: extra init steps)
if [[ -x "${ADDONSCRIPT}" ]]; then
  . "${ADDONSCRIPT}"
elif [[ ! -z "${ADDONSCRIPT}" ]]; then
  echo "Add-on script set to '${ADDONSCRIPT}' but not found/executable ! Aborting."
  exit 1
fi

action=$1

case "$action" in
  playbook|vault )
    shift
    ansible-${action} $@
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
