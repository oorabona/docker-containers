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
  matches=$(grep -oF -- "${needle}" "${file}")
  grep_status=$?
  set -e
  case ${grep_status} in
    0) printf '%s\n' "$(printf '%s\n' "${matches}" | wc -l)" ;;
    1) printf '0\n' ;;
    *) fail "could not count ${needle}; grep exited ${grep_status}" ;;
  esac
}

assert_page() {
  local container=$1
  local expected_tag=$2
  local evidence_state=$3
  local expected_as_of=$4
  local expected_critical=$5
  local expected_high=$6
  local expected_medium=$7
  local expected_low=$8
  local expected_info=$9
  local expected_attestation=${10}
  local sibling_tag=${11}
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local aria_selected
  aria_selected=$(python3 "${EXTRACTOR}" attribute aria-selected --class selected "${PAGE}") \
    || fail 'could not read aria-selected from the element with class token selected'
  [[ ${aria_selected} == true ]] || fail "selected element must have aria-selected=true; found ${aria_selected}"

  local aria_selected_count
  aria_selected_count=$(count_literal 'aria-selected="true"' "${PAGE}")
  [[ ${aria_selected_count} -eq 1 ]] || fail "expected exactly one aria-selected=\"true\"; found ${aria_selected_count}"

  local selected_tag
  selected_tag=$(python3 "${EXTRACTOR}" attribute data-tag --class selected "${PAGE}") \
    || fail 'could not read data-tag from the element with class token selected'
  [[ ${selected_tag} == "${expected_tag}" ]] || fail "selected element does not name ${expected_tag}; found ${selected_tag}"

  local security_text
  security_text=$(python3 "${EXTRACTOR}" text --within security-scan "${PAGE}") \
    || fail 'could not extract security-scan text'
  local trust_text
  trust_text=$(python3 "${EXTRACTOR}" text --within trust-posture "${PAGE}") \
    || fail 'could not extract trust-posture text'
  case ${expected_attestation} in
    attested|pending) ;;
    *) fail "unknown selected-variant attestation state ${expected_attestation}" ;;
  esac
  if grep -Fq -- "SBOM ${expected_attestation^^}" <<<"${trust_text}"; then
    :
  else
    classify_grep_status $? "trust strip does not show selected variant SBOM ${expected_attestation^^}"
  fi
  if grep -Fq -- "${expected_tag}" <<<"${security_text}"; then
    :
  else
    classify_grep_status $? "security-scan heading does not name selected tag ${expected_tag}"
  fi

  case ${evidence_state} in
    evidenced)
      for sentinel in \
        "${expected_as_of}" \
        "${expected_critical}Critical" \
        "${expected_high}High" \
        "${expected_medium}Medium" \
        "${expected_low}Low" \
        "${expected_info}Info"; do
        if grep -Fq -- "${sentinel}" <<<"${security_text}"; then
          :
        else
          classify_grep_status $? "security-scan is missing selected variant sentinel ${sentinel}"
        fi
      done
      ;;
    absent)
      if grep -Fq -- "No security evidence is recorded for image ${expected_tag}." <<<"${security_text}"; then
        :
      else
        classify_grep_status $? "security-scan is missing the no-security-evidence wording for ${expected_tag}"
      fi
      ;;
    not-recorded)
      if grep -Fq -- "No security evidence is recorded for image ${expected_tag}." <<<"${security_text}"; then
        :
      else
        classify_grep_status $? "security-scan is missing the no-security-evidence wording for ${expected_tag}"
      fi
      if grep -Fq -- 'data-scan-count=' "${PAGE}"; then
        classify_grep_status 0 'security-scan renders a severity count for an unrecognized evidence source' absent
      else
        classify_grep_status $? 'could not check security-scan for a severity count' absent
      fi
      ;;
    *)
      fail "unknown selected-variant evidence state ${evidence_state}"
      ;;
  esac

  if [[ -n ${sibling_tag} ]]; then
    if grep -Fq -- "${sibling_tag}" <<<"${security_text}"; then
      classify_grep_status 0 "security-scan names sibling tag ${sibling_tag}" absent
    else
      classify_grep_status $? "could not check security-scan for sibling tag ${sibling_tag}" absent
    fi
  fi
}

assert_selected_image_consumers() {
  local container=$1
  local expected_tag=$2
  local stale_tag=$3
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local action_bar_tag
  action_bar_tag=$(python3 "${EXTRACTOR}" attribute data-default-tag --id variant-action-bar "${PAGE}") \
    || fail 'could not read data-default-tag from variant-action-bar'
  [[ ${action_bar_tag} == "${expected_tag}" ]] \
    || fail "variant-action-bar default tag does not name ${expected_tag}; found ${action_bar_tag}"

  local noscript_markup
  noscript_markup=$(awk '/<noscript>/{inside=1} inside{print} /<\/noscript>/{exit}' "${PAGE}")
  [[ -n ${noscript_markup} ]] || fail 'could not extract variant-action-bar noscript markup'

  local selected_pull="docker pull ghcr.io/fixture-owner/${container}:${expected_tag}"
  if grep -Fq -- "${selected_pull}" <<<"${noscript_markup}"; then
    :
  else
    classify_grep_status $? "noscript pull command does not name selected tag ${expected_tag}"
  fi

  local selected_verify="cosign verify ghcr.io/fixture-owner/${container}:${expected_tag}"
  if grep -Fq -- "${selected_verify}" <<<"${noscript_markup}"; then
    :
  else
    classify_grep_status $? "noscript verify command does not name selected tag ${expected_tag}"
  fi

  if grep -Fq -- "${stale_tag}" <<<"${noscript_markup}"; then
    classify_grep_status 0 "noscript commands name stale tag ${stale_tag}" absent
  else
    classify_grep_status $? "could not check noscript commands for stale tag ${stale_tag}" absent
  fi

  local provenance_sections
  local grep_status
  set +e
  provenance_sections=$(grep -oE -- '<section class="provenance"[^>]*>' "${PAGE}")
  grep_status=$?
  set -e
  classify_grep_status "${grep_status}" 'could not find provenance sections'

  local visible_provenance_count=0
  local visible_provenance_tag=''
  local provenance_section
  while IFS= read -r provenance_section; do
    if [[ ${provenance_section} != *'style="display:none"'* ]]; then
      visible_provenance_count=$((visible_provenance_count + 1))
      case ${provenance_section} in
        *"data-variant-tag=\"${expected_tag}\""*) visible_provenance_tag=${expected_tag} ;;
        *) visible_provenance_tag=other ;;
      esac
    fi
  done <<<"${provenance_sections}"
  [[ ${visible_provenance_count} -eq 1 ]] \
    || fail "expected exactly one visible provenance section; found ${visible_provenance_count}"
  [[ ${visible_provenance_tag} == "${expected_tag}" ]] \
    || fail "visible provenance section does not name ${expected_tag}"
}

assert_page fixture-first-empty-later-evidence retained-evidence-alpine evidenced 2026-09-12 0 1 0 0 0 pending retained-evidence-sibling
assert_selected_image_consumers fixture-first-empty-later-evidence retained-evidence-alpine current-without-variant
assert_page fixture-no-security-evidence no-evidence-alpine absent '' '' '' '' '' '' pending ''
assert_page fixture-selected-security-evidence selected-evidence-alpine evidenced 2026-09-12 0 0 0 0 0 pending selected-evidence-sibling
assert_page fixture-contract-invalid-security-evidence bogus-source-alpine not-recorded '' '' '' '' '' '' attested ''

echo 'PASS: container page fixture assertions'
