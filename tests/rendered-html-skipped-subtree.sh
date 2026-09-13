#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="${SCRIPT_DIR}/rendered-html.py"
FIXTURES_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${FIXTURES_DIR}"
}
trap cleanup EXIT

write_fixture() {
  local name=$1
  local markup=$2
  printf '%s\n' "${markup}" > "${FIXTURES_DIR}/${name}"
}

assert_output() {
  local name=$1
  local expected=$2
  shift 2
  local output

  if ! output=$(python3 "${EXTRACTOR}" "$@" 2>&1); then
    echo "FAIL: ${name} unexpectedly failed: ${output}" >&2
    exit 1
  fi
  if [[ ${output} != "${expected}" ]]; then
    echo "FAIL: ${name} output was ${output@Q}; expected ${expected@Q}" >&2
    exit 1
  fi
  echo "PASS: ${name} (output: ${output})"
}

assert_failure_status() {
  local name=$1
  local expected_status=$2
  shift 2
  local output
  local status

  if output=$(python3 "${EXTRACTOR}" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  if (( status == 0 )); then
    echo "FAIL: ${name} unexpectedly succeeded: ${output}" >&2
    exit 1
  fi
  if (( status != expected_status )); then
    echo "FAIL: ${name} exited ${status}; expected ${expected_status}: ${output}" >&2
    exit 1
  fi
  echo "PASS: ${name} (status: ${status}; failure: ${output})"
}

write_fixture control.html '<div id="y" class="selected" data-tag="outside">control</div>'
assert_output 'control attribute' 'outside' attribute data-tag --class selected "${FIXTURES_DIR}/control.html"

write_fixture template-text-control.html '<template>TEXT</template>'
assert_output 'template text control is hidden' '' text "${FIXTURES_DIR}/template-text-control.html"

write_fixture visible-text-control.html '<div id="view-reference">TEXT</div>'
assert_output 'plain text control is visible within its id' 'TEXT' text --within view-reference "${FIXTURES_DIR}/visible-text-control.html"

write_fixture comment-tail.html '<p><!--x-->SENTENCE</p>'
assert_output 'comment body is excluded and tail is retained' 'SENTENCE' text "${FIXTURES_DIR}/comment-tail.html"

write_fixture comment-within.html '<div id="view-reference"><!--SENTENCE--></div>'
assert_output 'comment body is excluded within its id' '' text --within view-reference "${FIXTURES_DIR}/comment-within.html"

write_fixture comment-only.html '<p><!--SENTENCE--></p>'
assert_output 'comment body is excluded from text' '' text "${FIXTURES_DIR}/comment-only.html"

write_fixture comment-script-control.html '<script>SENTENCE</script>'
assert_output 'script body control is hidden' '' text "${FIXTURES_DIR}/comment-script-control.html"

write_fixture comment-visible-control.html '<div id="view-reference">SENTENCE</div>'
assert_output 'plain text control remains visible within its id' 'SENTENCE' text --within view-reference "${FIXTURES_DIR}/comment-visible-control.html"

write_fixture attr-hidden-duplicate.html '<div class="selected" data-tag="outside"></div><template><span class="a" class="b"></span></template>'
assert_output 'attribute ignores duplicate class in template' 'outside' attribute data-tag --class selected "${FIXTURES_DIR}/attr-hidden-duplicate.html"

write_fixture attr-target-duplicate.html '<div class="selected" data-tag="one" data-tag="two"></div>'
assert_output 'attribute uses browser-retained first duplicate attribute' 'one' attribute data-tag --class selected "${FIXTURES_DIR}/attr-target-duplicate.html"

write_fixture attr-selector-duplicate.html '<div class="selected" class="selected" data-tag="outside"></div>'
assert_output 'attribute uses browser-retained first duplicate selector attribute' 'outside' attribute data-tag --class selected "${FIXTURES_DIR}/attr-selector-duplicate.html"

write_fixture count-hidden-duplicate.html '<div class="x"></div><template><span class="x" class="x"></span></template>'
assert_output 'count ignores duplicate class in template' '1' count --class x "${FIXTURES_DIR}/count-hidden-duplicate.html"

write_fixture class-substring.html '<div class="selected-long"></div>'
assert_output 'class selector does not match a longer class token' '0' count --class selected "${FIXTURES_DIR}/class-substring.html"

write_fixture count-noscript-id.html '<body><noscript><div id="x"></div></noscript></body>'
assert_output 'count ignores id in noscript' '0' count --id x "${FIXTURES_DIR}/count-noscript-id.html"

write_fixture text-within-hidden-duplicate.html '<div id="y">outside</div><template><div id="y">hidden</div></template>'
assert_output 'text --within ignores duplicate id in template' 'outside' text --within y "${FIXTURES_DIR}/text-within-hidden-duplicate.html"

write_fixture text-hidden-duplicate.html '<div>outside</div><template><span id="x" id="x">hidden</span></template>'
assert_output 'plain text ignores duplicate id in template' 'outside' text "${FIXTURES_DIR}/text-hidden-duplicate.html"

write_fixture same-name-start-in-template.html '<div id="y">inside<template><div id="y">hidden</template>after</div>outside'
assert_output 'text --within follows template error recovery' 'inside' text --within y "${FIXTURES_DIR}/same-name-start-in-template.html"

write_fixture same-name-close-in-template.html '<div id="y">inside<template></div>hidden</template>after</div>outside'
assert_output 'text --within follows template close error recovery' 'inside' text --within y "${FIXTURES_DIR}/same-name-close-in-template.html"

write_fixture crossing-close.html '<template><noscript></template></noscript>'
assert_output 'crossing skipped close resolves: text' '' text "${FIXTURES_DIR}/crossing-close.html"
assert_failure_status 'crossing skipped close resolves: text --within' 3 text --within y "${FIXTURES_DIR}/crossing-close.html"
assert_output 'crossing skipped close resolves: count' '0' count --class x "${FIXTURES_DIR}/crossing-close.html"
assert_failure_status 'crossing skipped close resolves: attribute' 3 attribute data-tag --class x "${FIXTURES_DIR}/crossing-close.html"

write_fixture unterminated-template.html '<template><div class="x">hidden</div>'
assert_output 'unterminated template resolves: text' '' text "${FIXTURES_DIR}/unterminated-template.html"
assert_failure_status 'unterminated template resolves: text --within' 3 text --within y "${FIXTURES_DIR}/unterminated-template.html"
assert_output 'unterminated template resolves: count' '0' count --class x "${FIXTURES_DIR}/unterminated-template.html"
assert_failure_status 'unterminated template resolves: attribute' 3 attribute data-tag --class x "${FIXTURES_DIR}/unterminated-template.html"

for tag in template script style noscript; do
  fixture="${FIXTURES_DIR}/self-closing-${tag}.html"
  markup="<${tag}/><a id=\"hidden\" class=\"hidden\" data-tag=\"hidden\">hidden</a></${tag}>"
  if [[ ${tag} == noscript ]]; then
    markup="<body>${markup}</body>"
  fi
  write_fixture "self-closing-${tag}.html" "${markup}"
  assert_output "self-closing ${tag} hides id" '0' count --id hidden "${fixture}"
  assert_output "self-closing ${tag} hides class" '0' count --class hidden "${fixture}"
  assert_failure_status "self-closing ${tag} hides attribute" 3 attribute data-tag --id hidden "${fixture}"
  assert_failure_status "self-closing ${tag} hides text --within" 3 text --within hidden "${fixture}"
done

write_fixture no-within-match.html '<div id="other">outside</div>'
assert_failure_status 'text --within missing id has no-match status' 3 text --within target "${FIXTURES_DIR}/no-within-match.html"

write_fixture multiple-within-matches.html '<div id="target">first</div><div id="target">second</div>'
assert_failure_status 'text --within duplicate id has no-match status' 3 text --within target "${FIXTURES_DIR}/multiple-within-matches.html"

write_fixture no-attribute-match.html '<div class="other" data-tag="outside"></div>'
assert_failure_status 'attribute missing selector has no-match status' 3 attribute data-tag --class selected "${FIXTURES_DIR}/no-attribute-match.html"

write_fixture multiple-attribute-matches.html '<div class="selected" data-tag="first"></div><div class="selected" data-tag="second"></div>'
assert_failure_status 'attribute duplicate selector has no-match status' 3 attribute data-tag --class selected "${FIXTURES_DIR}/multiple-attribute-matches.html"

write_fixture missing-attribute.html '<div class="selected"></div>'
assert_failure_status 'attribute missing requested name has no-match status' 3 attribute data-tag --class selected "${FIXTURES_DIR}/missing-attribute.html"

mkdir "${FIXTURES_DIR}/unreadable"
for command in \
  'text' \
  'text --within target' \
  'jsonld' \
  'count --class selected' \
  'attribute data-tag --class selected'; do
  read -r -a args <<< "${command}"
  assert_failure_status "unreadable file fails: ${command}" 1 "${args[@]}" "${FIXTURES_DIR}/unreadable"
done

assert_failure_status 'invalid invocation has usage status' 2 text --within "${FIXTURES_DIR}/control.html"

write_fixture self-closing-div.html '<div id="target">before<div/>middle</div>outside</div>'
assert_output 'self-closing div remains open in HTML' 'beforemiddleoutside' text --within target "${FIXTURES_DIR}/self-closing-div.html"

write_fixture self-closing-svg.html '<svg id="target">before<svg/>middle</svg><p>outside</p>'
assert_output 'self-closing svg closes in foreign content' 'beforemiddle' text --within target "${FIXTURES_DIR}/self-closing-svg.html"

write_fixture self-closing-math.html '<math id="target">before<math/>middle</math><p>outside</p>'
assert_output 'self-closing math closes in foreign content' 'beforemiddle' text --within target "${FIXTURES_DIR}/self-closing-math.html"

write_fixture self-closing-jsonld.html '<script type="application/ld+json"/>{"x":1}</script>'
assert_output 'self-closing JSON-LD script remains open' '["{\"x\":1}"]' jsonld "${FIXTURES_DIR}/self-closing-jsonld.html"

write_fixture self-closing-unterminated-template.html '<template/>'
assert_output 'self-closing template resolves' '' text "${FIXTURES_DIR}/self-closing-unterminated-template.html"

write_fixture self-closing-br.html '<div id="target">before<br/>middle</div>outside'
assert_output 'self-closing void br preserves boundary' 'beforemiddle' text --within target "${FIXTURES_DIR}/self-closing-br.html"

write_fixture svg-breakout-script.html '<div id="view-reference"><svg><p></p><script/>REQUIRED_SENTENCE</script></svg></div>'
assert_output 'SVG breakout script keeps required sentence hidden' '' text --within view-reference "${FIXTURES_DIR}/svg-breakout-script.html"

write_fixture template-svg-close.html '<template><svg></template><script/>REQUIRED_SENTENCE</script>'
assert_output 'template SVG close keeps required sentence hidden' '' text "${FIXTURES_DIR}/template-svg-close.html"

write_fixture svg-math-close.html '<svg><math></svg><script/>REQUIRED_SENTENCE</script>'
assert_output 'SVG Math close keeps required sentence hidden' '' text "${FIXTURES_DIR}/svg-math-close.html"

write_fixture svg-foreign-object-script.html '<svg><foreignObject><script/>REQUIRED_SENTENCE</script></foreignObject></svg>'
assert_output 'SVG foreignObject script keeps required sentence hidden' '' text "${FIXTURES_DIR}/svg-foreign-object-script.html"

write_fixture svg-self-closing-script.html '<svg><script/><div>FORBIDDEN_TEXT</div></script></svg>'
assert_output 'SVG self-closing script leaves forbidden text visible' 'FORBIDDEN_TEXT' text "${FIXTURES_DIR}/svg-self-closing-script.html"

write_fixture svg-title-self-closing.html '<svg><title id="view-reference"/><metadata>TEXT</metadata></svg>'
assert_output 'SVG self-closing title excludes sibling metadata from id' '' text --within view-reference "${FIXTURES_DIR}/svg-title-self-closing.html"
