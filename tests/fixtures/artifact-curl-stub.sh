#!/usr/bin/env bash
# curl stand-in for the artifact-availability tests.
#
# Honours `-w '%{http_code}'` by printing the status of the *final* response.
# Rules come from $CURL_RULES, one per line:  <url-substring> <HEAD-code> <GET-code>
# (first match wins; unmatched URLs answer 200/200). A code of "timeout" exits 28
# with 000, like curl hitting --max-time. Every call is appended to $CURL_LOG as
# "<HEAD|GET> <url>" so tests can assert what was probed and how.
url="${*: -1}"
mode=GET
for a in "$@"; do
    case "$a" in
        --head) mode=HEAD ;;
        -[A-Za-z]*I*) mode=HEAD ;;
    esac
done
[[ -z "${CURL_LOG:-}" ]] || printf '%s %s\n' "$mode" "$url" >> "$CURL_LOG"

head_code=200 get_code=200
while read -r pat h g _; do
    [[ -n "${pat:-}" && "$url" == *"$pat"* ]] || continue
    head_code="$h" get_code="${g:-$h}"
    break
done <<< "${CURL_RULES:-}"

code="$get_code"
[[ "$mode" == HEAD ]] && code="$head_code"
if [[ "$code" == timeout ]]; then
    printf '000'
    exit 28
fi
printf '%s' "$code"
exit 0
