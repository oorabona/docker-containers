#!/usr/bin/env bash

set -euo pipefail

REQUIRED_SENTENCE='The build does not fail when findings are detected; it surfaces the total reported count for the operator to triage.'
REJECTED_VISIBLE_PHRASE='CVEs are detected'
REJECTED_SHORT_PHRASE='it surfaces the count for the operator to triage'

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <rendered-site-directory>" >&2
  exit 2
fi

SITE_DIR=$1
PAGE="${SITE_DIR}/verify-images/index.html"
EXTRACTOR="$(dirname "$0")/rendered-html.py"

fail() {
  echo "FAIL: ${PAGE}: $1" >&2
  exit 1
}

[[ -f "${PAGE}" && -s "${PAGE}" ]] || fail 'verify-images/index.html must be a non-empty regular file'

visible_text=$(python3 "${EXTRACTOR}" text "${PAGE}") \
  || fail 'could not extract reader-visible text'

grep -Fq -- "${REQUIRED_SENTENCE}" <<<"${visible_text}" \
  || fail 'reader-visible text is missing the required verification sentence'
grep -Fq -- "${REJECTED_VISIBLE_PHRASE}" <<<"${visible_text}" \
  && fail "reader-visible text contains rejected wording: ${REJECTED_VISIBLE_PHRASE}"
grep -Fq -- "${REJECTED_SHORT_PHRASE}" <<<"${visible_text}" \
  && fail "reader-visible text contains rejected wording: ${REJECTED_SHORT_PHRASE}"

jsonld_scripts=$(python3 "${EXTRACTOR}" jsonld "${PAGE}") \
  || fail 'could not extract JSON-LD scripts'

set +e
counts=$(printf '%s' "${jsonld_scripts}" | python3 -c '
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

matching_answers = 0
if len(faq_pages) == 1:
    main_entities = faq_pages[0].get("mainEntity", [])
    if isinstance(main_entities, list):
        for entity in main_entities:
            if not isinstance(entity, dict):
                continue
            answer = entity.get("acceptedAnswer")
            if isinstance(answer, dict) and isinstance(answer.get("text"), str):
                if sentence in answer["text"]:
                    matching_answers += 1

print(len(faq_pages), matching_answers)
' "${REQUIRED_SENTENCE}")
jsonld_status=$?
set -e

if [[ ${jsonld_status} -eq 3 ]]; then
  fail 'JSON-LD parse error'
elif [[ ${jsonld_status} -ne 0 ]]; then
  fail 'could not inspect JSON-LD FAQ content'
fi

read -r faq_count matching_answer_count <<<"${counts}"
[[ ${faq_count} -eq 1 ]] \
  || fail "expected exactly one JSON-LD FAQPage object; found ${faq_count}"
[[ ${matching_answer_count} -eq 1 ]] \
  || fail "expected exactly one FAQ acceptedAnswer.text containing the required sentence; found ${matching_answer_count}"
