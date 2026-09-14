#!/usr/bin/env bash

set -euo pipefail

REQUIRED_SENTENCE='The build does not fail when findings are detected; it surfaces the total reported count for the operator to triage.'
REJECTED_VISIBLE_PHRASE='CVEs are detected'
REJECTED_SHORT_PHRASE='it surfaces the count for the operator to triage'

WITH_CONTAINERS=false
case $# in
  1)
    SITE_DIR=$1
    ;;
  2)
    if [[ $1 != --with-containers ]]; then
      echo "usage: $0 [--with-containers] <rendered-site-directory>" >&2
      exit 2
    fi
    WITH_CONTAINERS=true
    SITE_DIR=$2
    ;;
  *)
    echo "usage: $0 [--with-containers] <rendered-site-directory>" >&2
    echo "default: checks verify-page panels, supported top-level FAQPage JSON-LD roots, the Trivy anchor, and raw Liquid in index.html and verify-images/index.html; nested and context-aliased JSON-LD nodes are outside inspection. Extracted text excludes comments and script, style, template, and noscript contents, collapses whitespace, and concatenates document-order text nodes without element separators. It models neither CSS nor runtime JavaScript, so elements hidden by a stylesheet or by script are read." >&2
    echo "--with-containers: additionally checks postgres and sslh container-page variants-table and raw-Liquid claims" >&2
    exit 2
    ;;
esac

PAGE="${SITE_DIR}/verify-images/index.html"
EXTRACTOR="$(dirname "$0")/rendered-html.py"

fail() {
  echo "FAIL: ${PAGE}: $1" >&2
  exit 1
}

classify_absent_grep_status() {
  local status=$1
  local searched=$2
  local claim=$3

  case ${status} in
    0) fail "${claim}: ${searched}" ;;
    1) ;;
    *) fail "could not search ${searched} for ${claim}; grep exited ${status}" ;;
  esac
}

assert_token_absent() {
  local file=$1
  local pattern=$2
  local claim=$3
  local status

  if grep -E -- "${pattern}" "${file}" >/dev/null; then
    classify_absent_grep_status 0 "${file}" "${claim}"
  else
    status=$?
    classify_absent_grep_status "${status}" "${file}" "${claim}"
  fi
}

assert_text_absent() {
  local text=$1
  local pattern=$2
  local claim=$3
  local status

  if grep -Fq -- "${pattern}" <<<"${text}"; then
    classify_absent_grep_status 0 'extracted text' "${claim}"
  else
    status=$?
    classify_absent_grep_status "${status}" 'extracted text' "${claim}"
  fi
}

assert_text_present() {
  local text=$1
  local pattern=$2
  local claim=$3
  local status

  if grep -Fq -- "${pattern}" <<<"${text}"; then
    return
  else
    status=$?
  fi
  if [[ ${status} -eq 1 ]]; then
    fail "${claim}"
  fi
  fail "could not search extracted text for ${claim}; grep exited ${status}"
}

[[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'verify-images/index.html must be a non-empty regular file'

for panel in view-reference view-walkthrough; do
  panel_text=$(python3 "${EXTRACTOR}" text --within "${panel}" "${PAGE}") \
    || fail "could not extract text from ${panel}"
  assert_text_present "${panel_text}" "${REQUIRED_SENTENCE}" \
    "${panel} extracted text is missing the required verification sentence"
done

extracted_text=$(python3 "${EXTRACTOR}" text "${PAGE}") \
  || fail 'could not extract text from the whole page'

assert_text_absent "${extracted_text}" "${REJECTED_VISIBLE_PHRASE}" \
  "extracted text contains rejected wording: ${REJECTED_VISIBLE_PHRASE}"
assert_text_absent "${extracted_text}" "${REJECTED_SHORT_PHRASE}" \
  "extracted text contains rejected wording: ${REJECTED_SHORT_PHRASE}"

jsonld_scripts=$(python3 "${EXTRACTOR}" jsonld "${PAGE}") \
  || fail 'could not extract JSON-LD scripts'

set +e
faq_result=$(printf '%s' "${jsonld_scripts}" | python3 -c '
import json
import sys

sentence = sys.argv[1]

def reject_duplicate_member(pairs):
    value = {}
    for name, member in pairs:
        if name in value:
            raise ValueError(f"duplicate JSON member {name!r}")
        value[name] = member
    return value

try:
    scripts = json.load(sys.stdin)
except json.JSONDecodeError as error:
    print(f"JSON-LD script list parse error: {error}", file=sys.stderr)
    sys.exit(3)

faq_pages = []
for index, script in enumerate(scripts, start=1):
    try:
        value = json.loads(script, object_pairs_hook=reject_duplicate_member)
    except (json.JSONDecodeError, ValueError) as error:
        print(f"JSON-LD parse error in script {index}: {error}", file=sys.stderr)
        sys.exit(3)
    if not isinstance(value, dict):
        print(f"jsonld-root-shape:{index}")
        sys.exit(0)
    if "@graph" in value:
        print(f"jsonld-graph-shape:{index}")
        sys.exit(0)
    if not isinstance(value.get("@type"), str):
        print(f"jsonld-type-shape:{index}")
        sys.exit(0)
    if value["@type"] == "FAQPage":
        faq_pages.append(value)

if len(faq_pages) != 1:
    print(f"faq-page-count:{len(faq_pages)}")
    sys.exit(0)

faq_page = faq_pages[0]
if faq_page.get("@context") != "https://schema.org":
    print("faq-context")
    sys.exit(0)

entities = faq_page.get("mainEntity")
if not isinstance(entities, list):
    print("faq-main-entity")
    sys.exit(0)

question_name = "Why does the dashboard show Trivy scan results are advisory?"
questions = []
for entity in entities:
    if not isinstance(entity, dict):
        continue
    if "@type" in entity and not isinstance(entity["@type"], str):
        print("faq-question-type-shape")
        sys.exit(0)
    if "acceptedAnswer" in entity:
        entity_answer = entity["acceptedAnswer"]
        if not isinstance(entity_answer, dict):
            print("faq-accepted-answer-shape")
            sys.exit(0)
        if "@type" in entity_answer and not isinstance(entity_answer["@type"], str):
            print("faq-answer-type-shape")
            sys.exit(0)
        if "text" in entity_answer and not isinstance(entity_answer["text"], str):
            print("faq-answer-text-shape")
            sys.exit(0)
    if entity.get("@type") == "Question" and entity.get("name") == question_name:
        questions.append(entity)
if len(questions) != 1:
    print(f"faq-question-count:{len(questions)}")
    sys.exit(0)

answer = questions[0].get("acceptedAnswer")
if not isinstance(answer, dict):
    print("faq-accepted-answer-shape")
    sys.exit(0)
if not isinstance(answer.get("@type"), str):
    print("faq-answer-type-shape")
    sys.exit(0)
if answer["@type"] != "Answer":
    print("faq-answer-type")
    sys.exit(0)
if not isinstance(answer.get("text"), str):
    print("faq-answer-text-shape")
    sys.exit(0)
if sentence not in answer["text"]:
    print("faq-answer-text")
    sys.exit(0)

other_answer_count = sum(
    1
    for entity in entities
    if entity is not questions[0]
    and isinstance(entity, dict)
    and isinstance(entity.get("acceptedAnswer"), dict)
    and isinstance(entity["acceptedAnswer"].get("text"), str)
    and sentence in entity["acceptedAnswer"]["text"]
)
if other_answer_count:
    print(f"faq-other-answer-count:{other_answer_count}")
    sys.exit(0)

print("ok")
' "${REQUIRED_SENTENCE}")
jsonld_status=$?
set -e

if [[ ${jsonld_status} -eq 3 ]]; then
  fail 'JSON-LD parse error'
elif [[ ${jsonld_status} -ne 0 ]]; then
  fail 'could not inspect JSON-LD FAQ content'
fi

case ${faq_result} in
  ok) ;;
  faq-page-count:*) fail "expected exactly one supported top-level FAQPage root; found ${faq_result#*:}" ;;
  jsonld-root-shape:*) fail "JSON-LD script ${faq_result#*:} has a root shape this check does not inspect" ;;
  jsonld-graph-shape:*) fail "JSON-LD script ${faq_result#*:} has an @graph shape this check does not inspect" ;;
  jsonld-type-shape:*) fail "JSON-LD script ${faq_result#*:} has an @type shape this check does not inspect" ;;
  faq-context) fail 'the JSON-LD FAQPage object must have @context https://schema.org' ;;
  faq-main-entity) fail 'the JSON-LD FAQPage object must have a mainEntity list' ;;
  faq-question-type-shape) fail 'a mainEntity item has an @type shape this check does not inspect' ;;
  faq-question-count:*) fail "expected exactly one FAQ Question named 'Why does the dashboard show Trivy scan results are advisory?'; found ${faq_result#*:}" ;;
  faq-accepted-answer-shape) fail 'a FAQ acceptedAnswer has a shape this check does not inspect' ;;
  faq-answer-type-shape) fail 'a FAQ acceptedAnswer has an @type shape this check does not inspect' ;;
  faq-answer-type) fail 'the target FAQ Question acceptedAnswer must have @type Answer' ;;
  faq-answer-text-shape) fail 'a FAQ acceptedAnswer.text has a shape this check does not inspect' ;;
  faq-answer-text) fail 'the target FAQ Question acceptedAnswer.text is missing the required verification sentence' ;;
  faq-other-answer-count:*) fail "${faq_result#*:} other FAQ answer(s) contain the required verification sentence" ;;
  *) fail "could not inspect JSON-LD FAQ content: ${faq_result}" ;;
esac

trivy_count=$(python3 "${EXTRACTOR}" count --id trivy "${PAGE}") \
  || fail 'could not count elements with id="trivy"'
[[ ${trivy_count} -eq 1 ]] \
  || fail "verify-images/index.html must contain exactly one element with id=\"trivy\"; found ${trivy_count}"

# The blog tree is excluded because blog/the-healthcheck-that-wasnt-stripped/index.html
# legitimately quotes Liquid or Go template syntax as post content.
for rendered_page in "${SITE_DIR}/index.html" "${PAGE}"; do
  [[ -f ${rendered_page} ]] || fail "required rendered page is missing: ${rendered_page}"
  assert_token_absent "${rendered_page}" '\{\{|\{%' 'rendered page contains raw Liquid syntax'
done

# #1566 removed the dashboard registry controls. The extractor constructs the
# rendered HTML5 tree, so this measures the server-rendered control directly.
DASHBOARD_PAGE="${SITE_DIR}/index.html"
[[ -f "${DASHBOARD_PAGE}" ]] || fail 'required rendered dashboard page is missing: index.html'

# The card include is not reached by the container-page fixture: it needs a
# direct guard so confirmed GHCR evidence cannot be hidden by absent mirror
# metadata. Unconfirmed cards retain their explicit unavailable branch.
CARD_TEMPLATE="$(dirname "$0")/../docs/site/_includes/container-card.html"
expected_confirmed_card_condition='{% if include.current_version_confirmed == true and include.ghcr_image %}'
grep -Fqx "    ${expected_confirmed_card_condition}" "${CARD_TEMPLATE}" \
  || fail 'confirmed cards must render their GHCR pull command without Docker Hub metadata'
grep -Fqx '    {% elsif include.current_version_confirmed != true %}' "${CARD_TEMPLATE}" \
  || fail 'unconfirmed cards must retain their explicit unavailable branch'
grep -Fq '<p>Publication information is unavailable; no pull reference is shown.</p>' "${CARD_TEMPLATE}" \
  || fail 'unconfirmed cards must retain the unavailable publication message'

registry_button_count=$(python3 "${EXTRACTOR}" count --class registry-btn "${DASHBOARD_PAGE}") \
  || fail "could not count elements whose class list contains \"registry-btn\" in ${DASHBOARD_PAGE}"
[[ ${registry_button_count} -eq 0 ]] \
  || fail "${DASHBOARD_PAGE} must not contain elements whose class list contains \"registry-btn\"; found ${registry_button_count}"

dashboard_text=$(python3 "${EXTRACTOR}" text "${DASHBOARD_PAGE}") \
  || fail 'could not extract rendered dashboard text'
assert_text_present "${dashboard_text}" \
  'published to GHCR' \
  'rendered dashboard hero does not name GHCR as the publication registry'
assert_text_present "${dashboard_text}" \
  'Docker Hub mirrored on a best-effort basis.' \
  'rendered dashboard hero is missing the qualified Docker Hub mirror claim'
assert_text_absent "${dashboard_text}" \
  'published to GHCR and Docker Hub' \
  'rendered dashboard hero still makes an unqualified Docker Hub publication claim'

DASHBOARD_JS="${SITE_DIR}/assets/js/dashboard.js"
[[ -f ${DASHBOARD_JS} ]] || fail 'rendered dashboard.js is missing'
node - "${DASHBOARD_JS}" <<'NODE' || fail 'persisted Docker Hub preference did not resolve to a GHCR pull command'
const fs = require('fs');
const dashboardPath = process.argv[2];
const pullInput = {
  value: '',
  addEventListener: function () {},
  select: function () {}
};
const pullSection = {
  dataset: { ghcrBase: 'ghcr.io/oorabona/confirmed-image', defaultTag: 'confirmed-tag' }
};
const card = {
  dataset: { container: 'confirmed-image' },
  querySelector: function (selector) {
    return selector === '.pull-section' ? pullSection : null;
  },
  querySelectorAll: function () { return []; },
  classList: { contains: function () { return false; } }
};

global.localStorage = {
  getItem: function (key) { return key === 'preferredRegistry' ? 'dockerhub' : null; },
  setItem: function () {}
};
global.document = {
  addEventListener: function (event, listener) {
    if (event === 'DOMContentLoaded') listener();
  },
  getElementById: function (id) {
    return id === 'pull-confirmed-image' ? pullInput : null;
  },
  querySelector: function () { return null; },
  querySelectorAll: function (selector) {
    if (selector === '.registry-btn[data-registry]' || selector === '.registry-btn') return [];
    if (selector === '.container-card') return [card];
    if (selector === 'input[id^="pull-"]') return [pullInput];
    return [];
  }
};

eval(fs.readFileSync(dashboardPath, 'utf8'));
const expected = 'docker pull ghcr.io/oorabona/confirmed-image:confirmed-tag';
if (pullInput.value !== expected || pullInput.value.includes('undefined')) {
  throw new Error('expected ' + expected + ', got ' + pullInput.value);
}
console.log('PASS: persisted dockerhub preference resolved to GHCR');
NODE

echo 'PASS: dashboard registry controls are absent'

if [[ ${WITH_CONTAINERS} == true ]]; then
  # docs/site/_data/containers.yml is generated and gitignored, so the required
  # check's dataless build renders no cards. Keep this positive control with the
  # data-backed assertions rather than letting it fail on every pull request.
  postgres_pull_command=$(python3 "${EXTRACTOR}" attribute value --id pull-postgres "${DASHBOARD_PAGE}") \
    || fail "could not read the value of #pull-postgres in ${DASHBOARD_PAGE}"
  expected_postgres_pull_command_pattern='^docker pull ghcr\.io/oorabona/postgres:[^[:space:]]+$'
  [[ ${postgres_pull_command} =~ ${expected_postgres_pull_command_pattern} ]] \
    || fail "${DASHBOARD_PAGE} #pull-postgres must name ghcr.io/oorabona/postgres with a non-empty tag; found \"${postgres_pull_command}\""

  postgres_page="${SITE_DIR}/container/postgres/index.html"
  sslh_page="${SITE_DIR}/container/sslh/index.html"
  [[ -f ${postgres_page} ]] || fail 'container/postgres/index.html must exist with --with-containers'
  [[ -f ${sslh_page} ]] || fail 'container/sslh/index.html must exist with --with-containers'
  postgres_variants_count=$(python3 "${EXTRACTOR}" count --class variants-table "${postgres_page}") \
    || fail 'could not count elements whose class list contains "variants-table" in container/postgres/index.html'
  [[ ${postgres_variants_count} -ge 1 ]] \
    || fail 'container/postgres/index.html is missing an element whose class list contains "variants-table"'
  sslh_variants_count=$(python3 "${EXTRACTOR}" count --class variants-table "${sslh_page}") \
    || fail 'could not count elements whose class list contains "variants-table" in container/sslh/index.html'
  [[ ${sslh_variants_count} -eq 0 ]] \
    || fail "container/sslh/index.html must not contain an element whose class list contains \"variants-table\"; found ${sslh_variants_count}"
  for container_page in "${postgres_page}" "${sslh_page}"; do
    assert_token_absent "${container_page}" '\{\{|\{%' 'container page contains raw Liquid syntax'
  done
fi
