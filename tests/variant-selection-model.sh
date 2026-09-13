#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../docs/site/assets/js/variant-selection-model.js"
FIXTURES_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${FIXTURES_DIR}"
}
trap cleanup EXIT

INPUTS="${FIXTURES_DIR}/inputs.json"
printf '%s\n' '[
  {"name":"duplicate names keep the first entry","operation":"deduplicate","input":[{"name":"base","label":"first"},{"name":"base","label":"second"},{"name":"base","label":"third"}],"expected":[{"name":"base","label":"first"}]},
  {"name":"empty and missing names are dropped","operation":"deduplicate","input":[{"name":"","label":"empty"},{"label":"missing"}],"expected":[]},
  {"name":"version A unnamed variants are unavailable while B is available","operation":"available","variants":[{"version":"A","name":"","tag":"a-base"},{"version":"A","name":"","tag":"a-tools"},{"version":"B","name":"vector","tag":"b-vector"}],"version":"A","expected":[]},
  {"name":"version B named variant is available control","operation":"available","variants":[{"version":"A","name":"","tag":"a-base"},{"version":"B","name":"vector","tag":"b-vector"}],"version":"B","expected":["vector"]},
  {"name":"empty tag does not make a flavor available","operation":"available","variants":[{"version":"A","name":"base","tag":""}],"version":"A","expected":[]},
  {"name":"array JSON parses","operation":"parse","input":"[1,2]","expected":[1,2]},
  {"name":"object JSON yields an empty array","operation":"parse","input":"{\"a\":1}","expected":[]},
  {"name":"malformed JSON yields an empty array","operation":"parse","input":"[not json","expected":[]},
  {"name":"undefined yields an empty array","operation":"parse-undefined","expected":[]},
  {"name":"undefined is absent","operation":"read-undefined","expected":{"array":[],"state":"absent"}},
  {"name":"empty string is absent","operation":"read","input":"","expected":{"array":[],"state":"absent"}},
  {"name":"array JSON is parsed","operation":"read","input":"[1,2]","expected":{"array":[1,2],"state":"parsed"}},
  {"name":"object JSON is unreadable","operation":"read","input":"{\"a\":1}","expected":{"array":[],"state":"unreadable"}},
  {"name":"malformed JSON is unreadable","operation":"read","input":"[not json","expected":{"array":[],"state":"unreadable"}}
]' > "${INPUTS}"

node - "${HELPER}" "${INPUTS}" <<'NODE'
const helper = process.argv[2];
const inputs = require(process.argv[3]);
require(helper);

const deduplicate = globalThis.deduplicateFlavorList;
const available = globalThis.availableFlavorNamesForVersion;
const parse = globalThis.parseVariantSelectionArray;
const read = globalThis.readVariantSelectionArray;
const functions = [deduplicate, available, parse, read];
if (functions.some((fn) => typeof fn !== 'function')) {
  throw new Error('helper did not expose every variant selection function');
}

let failures = 0;
for (const test of inputs) {
  let output;
  if (test.operation === 'deduplicate') output = deduplicate(test.input);
  if (test.operation === 'available') output = available(test.variants, test.version);
  if (test.operation === 'parse') output = parse(test.input);
  if (test.operation === 'parse-undefined') output = parse(undefined);
  if (test.operation === 'read') output = read(test.input);
  if (test.operation === 'read-undefined') output = read(undefined);
  if (JSON.stringify(output) === JSON.stringify(test.expected)) {
    console.log('PASS: ' + test.name + ' (output: ' + JSON.stringify(output) + ')');
  } else {
    console.error('FAIL: ' + test.name + ' (output: ' + JSON.stringify(output) +
      ', expected: ' + JSON.stringify(test.expected) + ')');
    failures += 1;
  }
}
process.exitCode = failures === 0 ? 0 : 1;
NODE
