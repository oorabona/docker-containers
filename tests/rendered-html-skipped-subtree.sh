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

assert_failure() {
  local name=$1
  shift
  local output

  if output=$(python3 "${EXTRACTOR}" "$@" 2>&1); then
    echo "FAIL: ${name} unexpectedly succeeded: ${output}" >&2
    exit 1
  fi
  echo "PASS: ${name} (failure: ${output})"
}

assert_failure_containing() {
  local name=$1
  local expected=$2
  shift 2
  local output

  if output=$(python3 "${EXTRACTOR}" "$@" 2>&1); then
    echo "FAIL: ${name} unexpectedly succeeded: ${output}" >&2
    exit 1
  fi
  if [[ ${output} != *"${expected}"* ]]; then
    echo "FAIL: ${name} failure was ${output@Q}; expected substring ${expected@Q}" >&2
    exit 1
  fi
  echo "PASS: ${name} (failure: ${output})"
}

assert_skipped_boundary_failure() {
  local name=$1
  local fixture=$2
  local expected_failure=$3

  assert_failure_containing "${name}: text" "${expected_failure}" text "${fixture}"
  assert_failure_containing "${name}: text --within" "${expected_failure}" text --within y "${fixture}"
  assert_failure_containing "${name}: count" "${expected_failure}" count --class x "${fixture}"
  assert_failure_containing "${name}: attribute" "${expected_failure}" attribute data-tag --class x "${fixture}"
}

write_fixture control.html '<div id="y" class="selected" data-tag="outside">control</div>'
assert_output 'control attribute' 'outside' attribute data-tag --class selected "${FIXTURES_DIR}/control.html"

write_fixture attr-hidden-duplicate.html '<div class="selected" data-tag="outside"></div><template><span class="a" class="b"></span></template>'
assert_output 'attribute ignores duplicate class in template' 'outside' attribute data-tag --class selected "${FIXTURES_DIR}/attr-hidden-duplicate.html"

write_fixture attr-target-duplicate.html '<div class="selected" data-tag="one" data-tag="two"></div>'
assert_failure 'attribute rejects duplicate requested attribute on match' attribute data-tag --class selected "${FIXTURES_DIR}/attr-target-duplicate.html"

write_fixture attr-selector-duplicate.html '<div class="selected" class="selected" data-tag="outside"></div>'
assert_failure 'attribute rejects duplicate selector attribute on match' attribute data-tag --class selected "${FIXTURES_DIR}/attr-selector-duplicate.html"

write_fixture count-hidden-duplicate.html '<div class="x"></div><template><span class="x" class="x"></span></template>'
assert_output 'count ignores duplicate class in template' '1' count --class x "${FIXTURES_DIR}/count-hidden-duplicate.html"

write_fixture count-noscript-id.html '<noscript><div id="x"></div></noscript>'
assert_output 'count ignores id in noscript' '0' count --id x "${FIXTURES_DIR}/count-noscript-id.html"

write_fixture text-within-hidden-duplicate.html '<div id="y">outside</div><template><div id="y">hidden</div></template>'
assert_output 'text --within ignores duplicate id in template' 'outside' text --within y "${FIXTURES_DIR}/text-within-hidden-duplicate.html"

write_fixture text-hidden-duplicate.html '<div>outside</div><template><span id="x" id="x">hidden</span></template>'
assert_output 'plain text ignores duplicate id in template' 'outside' text "${FIXTURES_DIR}/text-hidden-duplicate.html"

write_fixture same-name-start-in-template.html '<div id="y">inside<template><div id="y">hidden</template>after</div>outside'
assert_output 'text --within ignores same-name start in template' 'insideafter' text --within y "${FIXTURES_DIR}/same-name-start-in-template.html"

write_fixture same-name-close-in-template.html '<div id="y">inside<template></div>hidden</template>after</div>outside'
assert_output 'text --within ignores same-name close in template' 'insideafter' text --within y "${FIXTURES_DIR}/same-name-close-in-template.html"

write_fixture crossing-close.html '<template><noscript></template></noscript>'
assert_skipped_boundary_failure 'crossing skipped close fails' "${FIXTURES_DIR}/crossing-close.html" 'crosses open'

write_fixture unterminated-template.html '<template><div class="x">hidden</div>'
assert_skipped_boundary_failure 'unterminated template fails' "${FIXTURES_DIR}/unterminated-template.html" 'unterminated skipped element'
