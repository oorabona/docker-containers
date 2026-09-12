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
    echo "default: checks verify-page panels, FAQ JSON-LD, the Trivy anchor, and raw Liquid in index.html and verify-images/index.html" >&2
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

[[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'verify-images/index.html must be a non-empty regular file'

for panel in view-reference view-walkthrough; do
  panel_text=$(python3 "${EXTRACTOR}" text --within "${panel}" "${PAGE}") \
    || fail "could not extract reader-visible text from ${panel}"
  grep -Fq -- "${REQUIRED_SENTENCE}" <<<"${panel_text}" \
    || fail "${panel} reader-visible text is missing the required verification sentence"
done

visible_text=$(python3 "${EXTRACTOR}" text "${PAGE}") \
  || fail 'could not extract reader-visible text from the whole page'

grep -Fq -- "${REJECTED_VISIBLE_PHRASE}" <<<"${visible_text}" \
  && fail "reader-visible text contains rejected wording: ${REJECTED_VISIBLE_PHRASE}"
grep -Fq -- "${REJECTED_SHORT_PHRASE}" <<<"${visible_text}" \
  && fail "reader-visible text contains rejected wording: ${REJECTED_SHORT_PHRASE}"

jsonld_scripts=$(python3 "${EXTRACTOR}" jsonld "${PAGE}") \
  || fail 'could not extract JSON-LD scripts'

set +e
faq_result=$(printf '%s' "${jsonld_scripts}" | python3 -c '
import json
import sys

sentence = sys.argv[1]
try:
    scripts = json.load(sys.stdin)
except json.JSONDecodeError as error:
    print(f"JSON-LD script list parse error: {error}", file=sys.stderr)
    sys.exit(3)

faq_pages = []
for index, script in enumerate(scripts, start=1):
    try:
        value = json.loads(script)
    except json.JSONDecodeError as error:
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

grep -Fq -- 'id="trivy"' "${PAGE}" \
  || fail 'verify-images/index.html is missing id="trivy"'

# The blog tree is excluded because blog/the-healthcheck-that-wasnt-stripped/index.html
# legitimately quotes Liquid or Go template syntax as post content.
for rendered_page in "${SITE_DIR}/index.html" "${PAGE}"; do
  [[ -f ${rendered_page} ]] || fail "required rendered page is missing: ${rendered_page}"
  if grep -qE '\{\{|\{%' "${rendered_page}"; then
    fail "rendered page contains raw Liquid syntax: ${rendered_page}"
  fi
done

if [[ ${WITH_CONTAINERS} == true ]]; then
  postgres_page="${SITE_DIR}/container/postgres/index.html"
  sslh_page="${SITE_DIR}/container/sslh/index.html"
  [[ -f ${postgres_page} ]] || fail 'container/postgres/index.html must exist with --with-containers'
  [[ -f ${sslh_page} ]] || fail 'container/sslh/index.html must exist with --with-containers'
  grep -Fq -- 'class="variants-table"' "${postgres_page}" \
    || fail 'container/postgres/index.html is missing class="variants-table"'
  if grep -Fq -- 'class="variants-table"' "${sslh_page}"; then
    fail 'container/sslh/index.html must not contain class="variants-table"'
  fi
  for container_page in "${postgres_page}" "${sslh_page}"; do
    if grep -qE '\{\{|\{%' "${container_page}"; then
      fail "container page contains raw Liquid syntax: ${container_page}"
    fi
  done
fi
