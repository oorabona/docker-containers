#!/bin/bash -e
CONFIGFILE=${CONFIGFILE:-config.json}

# A function to display commands
print_run() { echo "\$ $@" >&2 ; eval "$@" ; }

# Generating final *.tf files when they are *.tf.j2
find -name "*.j2" -type f | {
  while read j2file
  do
    # Process *.tf.j2 to produce *.tf files
    print_run j2 "${j2file}" ${CONFIGFILE} > "./${j2file//.tf.j2/.tf}"
  done
}

# Run Terraform with supplied arguments
exec /bin/terraform "$@"
