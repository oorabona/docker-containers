#!/bin/bash -e
CONFIGFILE=${CONFIGFILE:-config.json}

# Render *.tf.j2 templates to *.tf (using $CONFIGFILE) before running Terraform.
# jinja2 is invoked directly with quoted arguments — never eval — and filenames
# are read NUL-delimited, so a crafted *.j2 filename or CONFIGFILE value in a
# mounted working directory cannot inject shell commands.
while IFS= read -r -d '' j2file; do
  outfile="${j2file%.tf.j2}.tf"
  echo "\$ jinja2 ${j2file} ${CONFIGFILE} > ${outfile}" >&2
  jinja2 "${j2file}" "${CONFIGFILE}" > "${outfile}"
done < <(find . -name "*.tf.j2" -type f -print0)

# Run Terraform with supplied arguments
exec /bin/terraform "$@"
