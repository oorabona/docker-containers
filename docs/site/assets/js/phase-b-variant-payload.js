/* phase-b-variant-payload.js
 *
 * Builds the detail-page `phase-b-variant-changed` payload. dashboard.js
 * dispatches the same event on the dashboard with a different target and does
 * not use this detail-page helper.
 *
 * For DOM datasets, trivy_summary_state is `absent` unless data-trivy-summary
 * is present, `parsed` after JSON.parse succeeds, and `unreadable` when it
 * throws. A producer that passes an already-parsed variant (the action bar)
 * can report only `parsed` or `absent`, because that blob was parsed earlier.
 */
(function (root) {
  'use strict';

  function has(data, key) {
    return Object.prototype.hasOwnProperty.call(data, key);
  }

  function value(data, datasetKey, variantKey) {
    if (has(data, datasetKey)) { return data[datasetKey] || ''; }
    return data[variantKey] || '';
  }

  function parsedPlatforms(data) {
    if (has(data, 'multiArchPlatforms')) {
      try {
        var platforms = JSON.parse(data.multiArchPlatforms);
        return Array.isArray(platforms) ? platforms : [];
      } catch (e) {
        return [];
      }
    }
    return Array.isArray(data.multi_arch_platforms) ? data.multi_arch_platforms : [];
  }

  root.buildPhaseBVariantPayload = function (dataset) {
    var data = dataset || {};
    var trivySummary = null;
    var trivySummaryState = 'absent';

    if (has(data, 'trivySummary')) {
      try {
        trivySummary = JSON.parse(data.trivySummary);
        trivySummaryState = 'parsed';
      } catch (e) {
        trivySummaryState = 'unreadable';
      }
    } else if (has(data, 'trivy_summary') && data.trivy_summary !== null &&
               typeof data.trivy_summary !== 'undefined') {
      trivySummary = data.trivy_summary;
      trivySummaryState = 'parsed';
    }

    return {
      tag: value(data, 'tag', 'tag'),
      attestation_url: value(data, 'attestationUrl', 'attestation_url'),
      attestation_id: value(data, 'attestationId', 'attestation_id'),
      trivy_summary: trivySummary,
      trivy_summary_state: trivySummaryState,
      multi_arch_platforms: parsedPlatforms(data),
      size_amd64: value(data, 'sizeAmd64', 'size_amd64'),
      size_arm64: value(data, 'sizeArm64', 'size_arm64')
    };
  };
})(typeof window !== 'undefined' ? window : globalThis);
