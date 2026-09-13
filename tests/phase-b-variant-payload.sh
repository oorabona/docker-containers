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
  {"name":"valid trivy summary","dataset":{"tag":"valid","attestationUrl":"https://example.test/a","attestationId":"a","trivySummary":"{\"critical\":0}","multiArchPlatforms":"[\"linux/amd64\"]","sizeAmd64":"10 MB","sizeArm64":"9 MB"},"state":"parsed","expected":{"tag":"valid","attestation_url":"https://example.test/a","attestation_id":"a","trivy_summary":{"critical":0},"trivy_summary_state":"parsed","multi_arch_platforms":["linux/amd64"],"size_amd64":"10 MB","size_arm64":"9 MB"}},
  {"name":"malformed trivy summary","dataset":{"tag":"malformed","trivySummary":"{not json","multiArchPlatforms":"[]"},"state":"unreadable","expected":{"tag":"malformed","attestation_url":"","attestation_id":"","trivy_summary":null,"trivy_summary_state":"unreadable","multi_arch_platforms":[],"size_amd64":"","size_arm64":""}},
  {"name":"absent trivy summary","dataset":{"tag":"absent","multiArchPlatforms":"[]"},"state":"absent","expected":{"tag":"absent","attestation_url":"","attestation_id":"","trivy_summary":null,"trivy_summary_state":"absent","multi_arch_platforms":[],"size_amd64":"","size_arm64":""}},
  {"name":"malformed platforms preserve trivy state","dataset":{"tag":"platforms","trivySummary":"{\"high\":1}","multiArchPlatforms":"[not json"},"state":"parsed","expected":{"tag":"platforms","attestation_url":"","attestation_id":"","trivy_summary":{"high":1},"trivy_summary_state":"parsed","multi_arch_platforms":[],"size_amd64":"","size_arm64":""}},
  {"name":"already parsed variant","dataset":{"tag":"parsed","trivy_summary":{"low":1},"multi_arch_platforms":["linux/arm64"]},"state":"parsed","expected":{"tag":"parsed","attestation_url":"","attestation_id":"","trivy_summary":{"low":1},"trivy_summary_state":"parsed","multi_arch_platforms":["linux/arm64"],"size_amd64":"","size_arm64":""}}
]' > "${INPUTS}"

run_builder() {
  node - "$1" "${INPUTS}" <<'NODE'
const helper = process.argv[2];
const inputs = require(process.argv[3]);
require(helper);

const build = globalThis.buildPhaseBVariantPayload;
if (typeof build !== 'function') {
  throw new Error('helper did not expose buildPhaseBVariantPayload');
}

let failures = 0;
for (const test of inputs) {
  const output = build(test.dataset);
  if (output.trivy_summary_state !== test.state) {
    console.error('FAIL: ' + test.name + ' (state was ' +
      output.trivy_summary_state + ', expected ' + test.state +
      '; output: ' + JSON.stringify(output) +
      ', expected: ' + JSON.stringify(test.expected) + ')');
    failures += 1;
  } else if (JSON.stringify(output) !== JSON.stringify(test.expected)) {
    console.error('FAIL: ' + test.name + ' (output: ' + JSON.stringify(output) +
      ', expected: ' + JSON.stringify(test.expected) + ')');
    failures += 1;
  } else {
    console.log('PASS: ' + test.name + ' (output: ' + JSON.stringify(output) + ')');
  }
}
process.exitCode = failures === 0 ? 0 : 1;
NODE
}

run_builder "${HELPER}"

MUTATED_HELPER="${FIXTURES_DIR}/missing-size-arm64.js"
sed '/^      size_arm64:/d' "${HELPER}" > "${MUTATED_HELPER}"
if red_output=$(run_builder "${MUTATED_HELPER}" 2>&1); then
  echo 'FAIL: removing size_arm64 from the builder unexpectedly passed' >&2
  exit 1
fi
if [[ ${red_output} != *'size_arm64'* ]]; then
  echo "FAIL: removing size_arm64 failed with unexpected output: ${red_output}" >&2
  exit 1
fi
echo "PASS: removing size_arm64 is rejected (failure: ${red_output})"
