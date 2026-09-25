#!/bin/bash -e
CONFIGFILE=${CONFIGFILE:-config.json}

# Render *.tf.j2 templates to *.tf (using $CONFIGFILE) before running the CLI.
# jinja2 is invoked directly with quoted arguments — never eval — and filenames
# are read NUL-delimited, so a crafted *.j2 filename or CONFIGFILE value in a
# mounted working directory cannot inject shell commands.
templates_file=$(mktemp "${TMPDIR:-/tmp}/tf-templates.XXXXXX") || exit 1
tmp=''
cleanup() {
    rm -f -- "$templates_file"
    if [ -n "$tmp" ]; then
        rm -f -- "$tmp"
    fi
}
trap cleanup EXIT
trap 'exit 1' TERM INT HUP
if ! find . -name "*.tf.j2" -type f -print0 > "$templates_file"; then
    echo "Could not enumerate all OpenTofu templates; rendering none" >&2
    exit 1
fi

while IFS= read -r -d '' j2file; do
    outfile="${j2file%.tf.j2}.tf"
    echo "\$ jinja2 ${j2file} ${CONFIGFILE} > ${outfile}" >&2
    if [ -d "$outfile" ]; then
        echo "Could not replace OpenTofu output for template ${j2file}" >&2
        exit 1
    fi
    tmp=$(mktemp "$(dirname -- "$outfile")/.tf-render.XXXXXX") || {
        echo "Could not create temporary file for OpenTofu template ${j2file}" >&2
        exit 1
    }
    if ! jinja2 "${j2file}" "${CONFIGFILE}" > "$tmp"; then
        echo "Could not render OpenTofu template ${j2file}" >&2
        exit 1
    fi
    if [ -f "$outfile" ] && [ ! -L "$outfile" ]; then
        mode=$(stat -c %a -- "$outfile") || {
            echo "Could not determine mode for OpenTofu output of template ${j2file}" >&2
            exit 1
        }
    else
        umask_value=$(umask)
        mode=$(printf '%03o' "$((0666 & ~8#$umask_value))")
    fi
    if ! chmod "$mode" "$tmp"; then
        echo "Could not set mode for OpenTofu output of template ${j2file}" >&2
        exit 1
    fi
    if ! mv -fT -- "$tmp" "$outfile"; then
        echo "Could not replace OpenTofu output for template ${j2file}" >&2
        exit 1
    fi
    tmp=''
done < "$templates_file"
rm -f "$templates_file"
trap - EXIT

# Run OpenTofu with supplied arguments
exec /usr/local/bin/tofu "$@"
