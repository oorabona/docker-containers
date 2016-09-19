#!/bin/bash

set -e

# Add logstash as command if needed
if [ "${1:0:1}" = '-' ]; then
	set -- logstash "$@"
fi

# Run as user "logstash" if the command is "logstash"
if [ "$1" = 'logstash' ]; then
	set -- gosu logstash "$@"
fi

# If we are going to run "logstash", check environment variable "CONFD_SUBDIRS"
# and load logstash configuration files in a one directory-per-configuration scheme.
if [ "$2" = 'logstash' ]; then
  if [ "$CONFD_SUBDIRS" = '*' ]; then
    echo "Starting logstash with all conf.d/* subdirs"
  else
    echo "Starting logstash with these confs: $CONFD_SUBDIRS"
  fi
  for conf in ${CONFD_SUBDIRS}; do
    if [ -d "${conf}" ]; then
      echo "Running... $@ -f $conf/"
      LS_CONF_DIR=$LS_CONF_DIR/$conf $@ -f $conf/ &
    else
      echo "Skipped $conf as directory does not exists." 1>&2
    fi
  done
  # Wait for all background processes launched to finish before exiting.
  # Maintains this script as PID 1 and makes Docker happy about this :)
  wait
  echo "All processes exited!"
else
  exec "$@"
fi
