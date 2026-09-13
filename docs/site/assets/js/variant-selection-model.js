/* variant-selection-model.js
 *
 * Pure selection rules shared by the container detail page consumers.
 */
(function (root) {
  'use strict';

  function usableName(value) {
    return typeof value === 'string' && value.trim() !== '';
  }

  root.deduplicateFlavorList = function (flavors) {
    var source = Array.isArray(flavors) ? flavors : [];
    var deduplicated = [];
    var seen = Object.create(null);

    source.forEach(function (flavor) {
      if (!flavor || !usableName(flavor.name) || seen[flavor.name]) { return; }
      seen[flavor.name] = true;
      deduplicated.push(flavor);
    });

    return deduplicated;
  };

  root.availableFlavorNamesForVersion = function (variants, version) {
    var source = Array.isArray(variants) ? variants : [];
    var names = [];
    var seen = Object.create(null);

    source.forEach(function (variant) {
      if (!variant || variant.version !== version || !variant.tag ||
          !usableName(variant.name) || seen[variant.name]) { return; }
      seen[variant.name] = true;
      names.push(variant.name);
    });

    return names;
  };

  root.readVariantSelectionArray = function (raw) {
    if (typeof raw !== 'string') {
      return { array: [], state: 'absent' };
    }
    if (raw === '') {
      return { array: [], state: 'absent' };
    }
    try {
      var parsed = JSON.parse(raw);
      return Array.isArray(parsed)
        ? { array: parsed, state: 'parsed' }
        : { array: [], state: 'unreadable' };
    } catch (e) {
      return { array: [], state: 'unreadable' };
    }
  };

  root.parseVariantSelectionArray = function (raw) {
    return root.readVariantSelectionArray(raw).array;
  };
})(typeof window !== 'undefined' ? window : globalThis);
