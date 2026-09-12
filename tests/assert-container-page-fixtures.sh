#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <rendered-fixture-site-directory>" >&2
  exit 2
fi

SITE_DIR=$1
EXTRACTOR="$(dirname "$0")/rendered-html.py"

fail() {
  echo "FAIL: ${PAGE}: $1" >&2
  exit 1
}

classify_grep_status() {
  local status=$1
  local claim=$2
  local expected=${3:-present}

  case ${expected} in
    present|absent) ;;
    *) fail "unknown grep expectation ${expected}" ;;
  esac

  case ${status} in
    0)
      [[ ${expected} == present ]] || fail "${claim}"
      ;;
    1)
      [[ ${expected} == absent ]] || fail "${claim}"
      ;;
    *) fail "could not evaluate ${claim}; grep exited ${status}" ;;
  esac
}

count_literal() {
  local needle=$1
  local file=$2
  local matches
  local grep_status

  set +e
  matches=$(grep -oF -- "${needle}" "${file}" | wc -l)
  grep_status=${PIPESTATUS[0]}
  set -e
  case ${grep_status} in
    0) printf '%s\n' "${matches}" ;;
    1) printf '0\n' ;;
    *) fail "could not count ${needle}; grep exited ${grep_status}" ;;
  esac
}

assert_page() {
  local container=$1
  local expected_tag=$2
  local evidence_state=$3
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local aria_selected
  aria_selected=$(count_literal 'aria-selected="true"' "${PAGE}")
  [[ ${aria_selected} -eq 1 ]] || fail "expected exactly one aria-selected=\"true\"; found ${aria_selected}"

  local selected_count
  selected_count=$(python3 "${EXTRACTOR}" count --class selected "${PAGE}") \
    || fail 'could not count elements with class token selected'
  [[ ${selected_count} -eq 1 ]] || fail "expected exactly one class token selected; found ${selected_count}"

  local security_scan_count
  security_scan_count=$(python3 "${EXTRACTOR}" count --id security-scan "${PAGE}") \
    || fail 'could not count elements with id="security-scan"'
  [[ ${security_scan_count} -eq 1 ]] || fail "expected exactly one element with id=\"security-scan\"; found ${security_scan_count}"

  if grep -zE -- "class=\"[^\"]*selected[^\"]*\"[^>]*data-tag=\"${expected_tag}\"" "${PAGE}" >/dev/null; then
    :
  else
    classify_grep_status $? "selected element does not name ${expected_tag}"
  fi

  local security_text
  security_text=$(python3 "${EXTRACTOR}" text --within security-scan "${PAGE}") \
    || fail 'could not extract security-scan text'
  local evidence_summary_pattern='finding\(s\) from the recorded scan|open Code Scanning alerts · fetched'
  if grep -Fq -- "${expected_tag}" <<<"${security_text}"; then
    :
  else
    classify_grep_status $? "security-scan heading does not name selected tag ${expected_tag}"
  fi

  case ${evidence_state} in
    evidenced)
      if grep -Eq -- "${evidence_summary_pattern}" <<<"${security_text}"; then
        :
      else
        classify_grep_status $? 'security-scan is missing the security-evidence summary wording'
      fi
      if grep -Fq -- 'No security evidence is recorded for image' <<<"${security_text}"; then
        classify_grep_status 0 'security-scan reports no security evidence for an evidenced selected variant' absent
      else
        classify_grep_status $? 'could not check security-scan for no-security-evidence wording' absent
      fi
      ;;
    absent)
      if grep -Fq -- "No security evidence is recorded for image ${expected_tag}." <<<"${security_text}"; then
        :
      else
        classify_grep_status $? "security-scan is missing the no-security-evidence wording for ${expected_tag}"
      fi
      if grep -Eq -- "${evidence_summary_pattern}" <<<"${security_text}"; then
        classify_grep_status 0 'security-scan reports a recorded scan for a selected variant without security evidence' absent
      else
        classify_grep_status $? 'could not check security-scan for security-evidence summary wording' absent
      fi
      ;;
    *)
      fail "unknown selected-variant evidence state ${evidence_state}"
      ;;
  esac
}

assert_page fixture-first-empty-later-evidence retained-evidence-alpine evidenced
assert_page fixture-no-security-evidence no-evidence-alpine absent
assert_page fixture-selected-security-evidence selected-evidence-alpine evidenced

echo 'PASS: container page fixture assertions'
