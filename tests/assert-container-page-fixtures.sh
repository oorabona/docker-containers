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
  local expected_version=$4
  local expected_flavor=$5
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local action_bar_tag
  action_bar_tag=$(python3 "${EXTRACTOR}" attribute data-default-tag --id variant-action-bar "${PAGE}") \
    || fail 'could not read data-default-tag from variant-action-bar'
  [[ ${action_bar_tag} == "${expected_tag}" ]] \
    || fail "variant-action-bar default tag does not name ${expected_tag}; found ${action_bar_tag}"

  local action_bar_version
  action_bar_version=$(python3 "${EXTRACTOR}" attribute data-default-version --id variant-action-bar "${PAGE}") \
    || fail 'could not read data-default-version from variant-action-bar'
  [[ ${action_bar_version} == "${expected_version}" ]] \
    || fail "variant-action-bar default version does not name ${expected_version}; found ${action_bar_version}"

  local action_bar_flavor
  action_bar_flavor=$(python3 "${EXTRACTOR}" attribute data-default-flavor --id variant-action-bar "${PAGE}") \
    || fail 'could not read data-default-flavor from variant-action-bar'
  [[ ${action_bar_flavor} == "${expected_flavor}" ]] \
    || fail "variant-action-bar default flavor does not name ${expected_flavor}; found ${action_bar_flavor}"

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
  local provenance_section
  while IFS= read -r provenance_section; do
    if [[ ${provenance_section} != *'style="display:none"'* ]]; then
      visible_provenance_count=$((visible_provenance_count + 1))
      case ${provenance_section} in
        *"data-variant-tag=\"${expected_tag}\""*) ;;
        *) fail "visible provenance section does not name ${expected_tag}" ;;
      esac
    fi
  done <<<"${provenance_sections}"
  [[ ${visible_provenance_count} -eq 1 ]] \
    || fail "expected exactly one visible provenance section; found ${visible_provenance_count}"
}

assert_variant_action_bar_options() {
  local container=$1
  local empty_version=$2
  local populated_version=$3
  local expected_flavors=$4
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local versions
  versions=$(python3 "${EXTRACTOR}" attribute data-versions --id variant-action-bar "${PAGE}") \
    || fail 'could not read data-versions from variant-action-bar'
  [[ ${versions} == *"\"tag\":\"${empty_version}\""* ]] \
    || fail "version list omits empty version ${empty_version}"
  [[ ${versions} == *"\"tag\":\"${populated_version}\""* ]] \
    || fail "version list omits populated version ${populated_version}"

  local flavors
  flavors=$(python3 "${EXTRACTOR}" attribute data-flavors --id variant-action-bar "${PAGE}") \
    || fail 'could not read data-flavors from variant-action-bar'
  local flavor
  IFS=',' read -r -a expected_flavor_list <<< "${expected_flavors}"
  for flavor in "${expected_flavor_list[@]}"; do
    [[ ${flavors} == *"\"name\":\"${flavor}\""* ]] \
      || fail "flavor list omits ${flavor} from a later version"
  done
}

assert_summary_metric() {
  local container=$1
  local title=$2
  local expected_metric=$3
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local summary_markup
  summary_markup=$(awk -v title="${title}" '
    index($0, "<span class=\"disclosure__title\">" title "</span>") { in_summary = 1 }
    in_summary { print }
    in_summary && /<\/summary>/ { exit }
  ' "${PAGE}")
  [[ -n ${summary_markup} ]] || fail "could not extract ${title} summary"

  local metric_hook=''
  case ${title} in
    'Package summary') metric_hook='sbom-summary-metric' ;;
    'Recent changes') metric_hook='changelog-summary-metric' ;;
    'Build history') metric_hook='history-summary-metric' ;;
  esac

  if [[ -n ${expected_metric} ]]; then
    local metric_element
    if [[ -n ${metric_hook} ]]; then
      metric_element="<span class=\"disclosure__metric\" id=\"${metric_hook}\">${expected_metric}</span>"
    else
      metric_element="<span class=\"disclosure__metric\">${expected_metric}</span>"
    fi
    if grep -Fq -- "${metric_element}" <<<"${summary_markup}"; then
      :
    else
      classify_grep_status $? "${title} summary is missing metric ${metric_element}"
    fi
  else
    [[ -n ${metric_hook} ]] || fail "${title} has no metric hook for an absent-data assertion"
    local hidden_metric_element="<span class=\"disclosure__metric\" id=\"${metric_hook}\" hidden></span>"
    if grep -Fq -- "${hidden_metric_element}" <<<"${summary_markup}"; then
      :
    else
      classify_grep_status $? "${title} summary is missing hidden metric hook ${hidden_metric_element}"
    fi
    if grep -Fq -- "<span class=\"disclosure__metric\" id=\"${metric_hook}\">" <<<"${summary_markup}"; then
      classify_grep_status 0 "${title} summary renders a visible metric without source data" absent
    fi
  fi
}

assert_absent_metric_element() {
  local container=$1
  local metric=$2
  local claim=$3
  PAGE="${SITE_DIR}/container/${container}/index.html"
  [[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'container fixture page must be a non-empty regular file'

  local metric_element="<span class=\"disclosure__metric\">${metric}</span>"
  if grep -Fq -- "${metric_element}" "${PAGE}"; then
    classify_grep_status 0 "${claim}" absent
  else
    classify_grep_status $? "could not check ${claim}" absent
  fi
}

assert_page fixture-first-empty-later-evidence retained-evidence-alpine evidenced 2026-09-12 0 1 0 0 0 pending retained-evidence-sibling
assert_selected_image_consumers fixture-first-empty-later-evidence retained-evidence-alpine current-without-variant retained-evidence alpine
assert_variant_action_bar_options fixture-first-empty-later-evidence current-without-variant retained-evidence alpine,sibling
assert_page fixture-no-security-evidence no-evidence-alpine absent '' '' '' '' '' '' pending ''
assert_page fixture-selected-security-evidence selected-evidence-alpine evidenced 2026-09-12 0 0 0 0 0 pending selected-evidence-sibling
assert_page fixture-contract-invalid-security-evidence bogus-source-alpine not-recorded '' '' '' '' '' '' attested ''
assert_summary_metric fixture-detail-summary-metrics 'Build lineage' '1b56ba6ead9d'
assert_summary_metric fixture-detail-summary-metrics 'Package summary' '55 packages'
assert_summary_metric fixture-detail-summary-metrics 'Recent changes' '+2 −1 ~3'
assert_summary_metric fixture-detail-summary-metrics 'Build history' '2 builds'
assert_summary_metric fixture-detail-summary-no-changes 'Package summary' '1 package'
assert_summary_metric fixture-detail-summary-no-changes 'Recent changes' ''
assert_summary_metric fixture-detail-summary-no-changes 'Build history' '1 build'
assert_summary_metric fixture-no-security-evidence 'Package summary' ''
assert_summary_metric fixture-no-security-evidence 'Recent changes' ''
assert_summary_metric fixture-no-security-evidence 'Build history' ''
assert_absent_metric_element fixture-no-security-evidence 'sha256:' 'missing-data fixture renders a sha256:-only build lineage metric'
assert_absent_metric_element fixture-no-security-evidence 'n/a — runtime parsed' 'missing-data fixture renders the package runtime placeholder'
assert_absent_metric_element fixture-no-security-evidence 'n/a — runtime fetched' 'missing-data fixture renders the build-history runtime placeholder'

DASHBOARD_PAGE="${SITE_DIR}/index.html"
PAGE=${DASHBOARD_PAGE}
[[ -f "${DASHBOARD_PAGE}" && -s "${DASHBOARD_PAGE}" ]] || fail 'container fixture dashboard must be a non-empty regular file'

dashboard_card_count=$(python3 "${EXTRACTOR}" count --class container-card "${DASHBOARD_PAGE}") \
  || fail 'could not count dashboard container cards'
[[ ${dashboard_card_count} -eq 1 ]] \
  || fail "expected exactly one dashboard container card; found ${dashboard_card_count}"

dashboard_trivy_state=$(python3 "${EXTRACTOR}" attribute data-severity --class trust-badge--trivy "${DASHBOARD_PAGE}") \
  || fail 'could not read dashboard Trivy badge state'
[[ ${dashboard_trivy_state} == not-recorded ]] \
  || fail "dashboard Trivy badge is not marked not-recorded; found ${dashboard_trivy_state}"

dashboard_trivy_label=$(python3 "${EXTRACTOR}" attribute aria-label --class trust-badge--trivy "${DASHBOARD_PAGE}") \
  || fail 'could not read dashboard Trivy badge wording'
[[ ${dashboard_trivy_label} == 'Security evidence is not recorded for this image' ]] \
  || fail "dashboard Trivy badge does not say security evidence is not recorded; found ${dashboard_trivy_label}"

dashboard_text=$(python3 "${EXTRACTOR}" text "${DASHBOARD_PAGE}") \
  || fail 'could not extract dashboard text'
if grep -Eq '🛡[[:space:]]*[0-9]' <<<"${dashboard_text}"; then
  classify_grep_status 0 'dashboard Trivy badge renders a severity count for an unrecognized evidence source' absent
else
  classify_grep_status $? 'could not check dashboard Trivy badge for a severity count' absent
fi

PAGE="${SITE_DIR}/container/fixture-contract-invalid-security-evidence/index.html"
selected_provenance_tag=$(python3 "${EXTRACTOR}" attribute data-variant-tag --class provenance "${PAGE}") \
  || fail 'could not read selected invalid-source provenance tag'
[[ ${selected_provenance_tag} == bogus-source-alpine ]] \
  || fail "selected invalid-source provenance does not name bogus-source-alpine; found ${selected_provenance_tag}"

selected_provenance_text=$(python3 "${EXTRACTOR}" text "${PAGE}") \
  || fail 'could not extract selected invalid-source provenance text'

set +e
selected_trivy_terms=$(grep -oF -- 'Trivy evidence' <<<"${selected_provenance_text}")
grep_status=$?
set -e
classify_grep_status "${grep_status}" 'could not find Trivy evidence in selected invalid-source provenance section'
selected_trivy_term_count=$(printf '%s\n' "${selected_trivy_terms}" | wc -l)
[[ ${selected_trivy_term_count} -eq 1 ]] \
  || fail "expected exactly one Trivy evidence term in selected invalid-source provenance section; found ${selected_trivy_term_count}"
if grep -Eq 'Trivy evidence[[:space:]]*evidence not recorded' <<<"${selected_provenance_text}"; then
  :
else
  classify_grep_status $? 'selected invalid-source provenance term has no explicit not-recorded value'
fi

echo 'PASS: container page fixture assertions'
