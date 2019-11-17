#!/usr/bin/env bash

run_and_watch_for() {
  if [ -r "$1" ]
  then
    eval ${@:2}
  fi
  watch_for $@ &
}

watch_for() {
  while inotifywait -e modify $1; do
    echo "Triggering after modify event of $1"
    eval ${@:2}
  done
}

# Show a nice intro message :)
boxes -d columns << eof
Launching oorabona/ansible Docker container environment, welcome !
Ansible version is : $(ansible --version|head -1)
Running $(ansible --version|grep version)

eof

# Processing watch on specific files
# Adding extra libs from pip
run_and_watch_for requirements.txt "pip3 install --user -r requirements.txt"

# Adding extra libs from ansible-galaxy
run_and_watch_for requirements.yml "ansible-galaxy install -r requirements.yml"

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
    source ~/.bashrc
    ansible-${action} $@
    ;;
  run-script )
    shift
    . "$@"
    ;;
  * )
    exec "$@"
esac

if [ ! -z "${WAIT_BEFORE_EXIT}" ]
then
  read -p "Press <ENTER> key to finish."
fi
