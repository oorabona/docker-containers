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
    echo "default: checks verify-page panels, FAQ JSON-LD, the Trivy anchor, and raw Liquid in index.html and verify-images/index.html; extracted text excludes comments and script, style, template, and noscript contents, collapses whitespace, and concatenates document-order text nodes without element separators. It models neither CSS nor runtime JavaScript, so elements hidden by a stylesheet or by script are read." >&2
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

assert_token_absent() {
  local file=$1
  local pattern=$2
  local claim=$3
  local status

  if grep -E -- "${pattern}" "${file}" >/dev/null; then
    fail "${claim}: ${file}"
  else
    status=$?
    if [[ ${status} -ne 1 ]]; then
      fail "could not search ${file} for ${claim}; grep exited ${status}"
    fi
  fi
}

[[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'verify-images/index.html must be a non-empty regular file'

for panel in view-reference view-walkthrough; do
  panel_text=$(python3 "${EXTRACTOR}" text --within "${panel}" "${PAGE}") \
    || fail "could not extract text from ${panel}"
  grep -Fq -- "${REQUIRED_SENTENCE}" <<<"${panel_text}" \
    || fail "${panel} extracted text is missing the required verification sentence"
done

extracted_text=$(python3 "${EXTRACTOR}" text "${PAGE}") \
  || fail 'could not extract text from the whole page'

grep -Fq -- "${REJECTED_VISIBLE_PHRASE}" <<<"${extracted_text}" \
  && fail "extracted text contains rejected wording: ${REJECTED_VISIBLE_PHRASE}"
grep -Fq -- "${REJECTED_SHORT_PHRASE}" <<<"${extracted_text}" \
  && fail "extracted text contains rejected wording: ${REJECTED_SHORT_PHRASE}"

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
    if isinstance(value, dict) and value.get("@type") == "FAQPage":
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
questions = [
    entity for entity in entities
    if isinstance(entity, dict)
    and entity.get("@type") == "Question"
    and entity.get("name") == question_name
]
if len(questions) != 1:
    print(f"faq-question-count:{len(questions)}")
    sys.exit(0)

answer = questions[0].get("acceptedAnswer")
if not isinstance(answer, dict) or answer.get("@type") != "Answer":
    print("faq-answer-type")
    sys.exit(0)
if not isinstance(answer.get("text"), str) or sentence not in answer["text"]:
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
  faq-page-count:*) fail "expected exactly one application/ld+json FAQPage object; found ${faq_result#*:}" ;;
  faq-context) fail 'the JSON-LD FAQPage object must have @context https://schema.org' ;;
  faq-main-entity) fail 'the JSON-LD FAQPage object must have a mainEntity list' ;;
  faq-question-count:*) fail "expected exactly one FAQ Question named 'Why does the dashboard show Trivy scan results are advisory?'; found ${faq_result#*:}" ;;
  faq-answer-type) fail 'the target FAQ Question acceptedAnswer must have @type Answer' ;;
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

if [[ ${WITH_CONTAINERS} == true ]]; then
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
