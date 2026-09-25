#!/bin/bash -e
CONFIGFILE=${CONFIGFILE:-config.json}

# Render *.tf.j2 templates to *.tf (using $CONFIGFILE) before running OpenTofu.
# jinja2 is invoked directly with quoted arguments — never eval — and filenames
# are read NUL-delimited, so a crafted *.j2 filename or CONFIGFILE value in a
# mounted working directory cannot inject shell commands.
templates_file=$(mktemp "${TMPDIR:-/tmp}/tofu-tf-templates.XXXXXX") || exit 1
trap 'rm -f "$templates_file"' EXIT
if ! find . -name "*.tf.j2" -type f -print0 > "$templates_file"; then
    rm -f "$templates_file"
    echo "Could not enumerate all OpenTofu templates; rendering none" >&2
    exit 1
fi

while IFS= read -r -d '' j2file; do
    outfile="${j2file%.tf.j2}.tf"
    echo "\$ jinja2 ${j2file} ${CONFIGFILE} > ${outfile}" >&2
    tmp=$(mktemp "${outfile}.XXXXXX") || {
        echo "Could not create temporary file for OpenTofu template ${j2file}" >&2
        exit 1
    }
    if ! jinja2 "${j2file}" "${CONFIGFILE}" > "$tmp"; then
        rm -f -- "$tmp"
        echo "Could not render OpenTofu template ${j2file}" >&2
        exit 1
    fi
    if ! mv -f -- "$tmp" "$outfile"; then
        rm -f -- "$tmp"
        echo "Could not replace OpenTofu output for template ${j2file}" >&2
        exit 1
    fi
done < "$templates_file"
rm -f "$templates_file"
trap - EXIT

# Run OpenTofu with supplied arguments
exec /usr/local/bin/tofu "$@"
