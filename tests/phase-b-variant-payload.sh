#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../docs/site/assets/js/phase-b-variant-payload.js"
FIXTURES_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${FIXTURES_DIR}"
}
trap cleanup EXIT

INPUTS="${FIXTURES_DIR}/inputs.json"
printf '%s\n' '[
  {"name":"valid trivy summary","dataset":{"tag":"valid","attestationUrl":"https://example.test/a","attestationId":"a","trivySummary":"{\"critical\":0}","multiArchPlatforms":"[\"linux/amd64\"]","sizeAmd64":"10 MB","sizeArm64":"9 MB"},"state":"parsed","summary":{"critical":0},"platforms":["linux/amd64"]},
  {"name":"malformed trivy summary","dataset":{"tag":"malformed","trivySummary":"{not json","multiArchPlatforms":"[]"},"state":"unreadable","summary":null,"platforms":[]},
  {"name":"absent trivy summary","dataset":{"tag":"absent","multiArchPlatforms":"[]"},"state":"absent","summary":null,"platforms":[]},
  {"name":"malformed platforms preserve trivy state","dataset":{"tag":"platforms","trivySummary":"{\"high\":1}","multiArchPlatforms":"[not json"},"state":"parsed","summary":{"high":1},"platforms":[]},
  {"name":"already parsed variant","dataset":{"tag":"parsed","trivy_summary":{"low":1},"multi_arch_platforms":["linux/arm64"]},"state":"parsed","summary":{"low":1},"platforms":["linux/arm64"]}
]' > "${INPUTS}"

run_builder() {
  node - "$1" "${INPUTS}" <<'NODE'
const helper = process.argv[2];
const inputs = require(process.argv[3]);
require(helper);

const build = globalThis.buildPhaseBVariantPayload;
const fields = [
  'tag', 'attestation_url', 'attestation_id', 'trivy_summary',
  'trivy_summary_state', 'multi_arch_platforms', 'size_amd64', 'size_arm64'
];
if (typeof build !== 'function') {
  throw new Error('helper did not expose buildPhaseBVariantPayload');
}

for (const test of inputs) {
  const output = build(test.dataset);
  for (const field of fields) {
    if (!Object.prototype.hasOwnProperty.call(output, field)) {
      throw new Error(test.name + ': missing ' + field);
    }
  }
  if (output.trivy_summary_state !== test.state) {
    throw new Error(test.name + ': state was ' + output.trivy_summary_state);
  }
  if (JSON.stringify(output.trivy_summary) !== JSON.stringify(test.summary)) {
    throw new Error(test.name + ': summary was ' + JSON.stringify(output.trivy_summary));
  }
  if (JSON.stringify(output.multi_arch_platforms) !== JSON.stringify(test.platforms)) {
    throw new Error(test.name + ': platforms were ' + JSON.stringify(output.multi_arch_platforms));
  }
  console.log('PASS: ' + test.name + ' (output: ' + JSON.stringify(output) + ')');
}
NODE
}

run_builder "${HELPER}"

MUTATED_HELPER="${FIXTURES_DIR}/missing-size-arm64.js"
sed '/^      size_arm64:/d' "${HELPER}" > "${MUTATED_HELPER}"
if red_output=$(run_builder "${MUTATED_HELPER}" 2>&1); then
  echo 'FAIL: removing size_arm64 from the builder unexpectedly passed' >&2
  exit 1
fi
if [[ ${red_output} != *'missing size_arm64'* ]]; then
  echo "FAIL: removing size_arm64 failed with unexpected output: ${red_output}" >&2
  exit 1
fi
echo "PASS: removing size_arm64 is rejected (failure: ${red_output})"
