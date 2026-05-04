/* version-tabs.js — <version-tabs> custom element (M4 closure)
   WAI-ARIA Authoring Practices "Tabs with Manual Activation" pattern.
   Dispatches the existing `phase-b-variant-changed` event so <trust-strip>
   and <security-scan> keep working WITHOUT modification.
   Prior-art: vanilla-web-components.md (docker-containers Phase B). */

(function () {
  'use strict';

  class VersionTabs extends HTMLElement {
    connectedCallback() {
      // Guard: avoid double-init on DOM reparenting (prior-art gotcha: M-severity)
      if (this._initialized) return;
      this._initialized = true;

      // Event delegation — single listener on host covers all tab groups
      this._clickHandler = (e) => {
        var tab = e.target.closest('[role="tab"]');
        if (tab) this._activateTab(tab);
      };
      this._keydownHandler = (e) => this._handleKeydown(e);

      this.addEventListener('click', this._clickHandler);
      this.addEventListener('keydown', this._keydownHandler);

      // Fix #1: dispatch phase-b-variant-changed for the initial active tab so
      // <trust-strip>, <security-scan>, and Provenance are correctly initialized
      // on multi-version pages where the first [aria-selected="true"] tab is the
      // data source (not the hidden synthetic .variant-tag.selected button).
      // Defer to next microtask so container-detail.js listeners are registered first.
      Promise.resolve().then(() => this._dispatchInitialVariant());
    }

    disconnectedCallback() {
      if (this._clickHandler) this.removeEventListener('click', this._clickHandler);
      if (this._keydownHandler) this.removeEventListener('keydown', this._keydownHandler);
      this._initialized = false;
    }

    /* ------------------------------------------------------------------ */
    /*  Tab activation                                                      */
    /* ------------------------------------------------------------------ */

    _activateTab(tab) {
      if (!tab || tab.getAttribute('aria-selected') === 'true') return;

      // Deselect all tabs in the SAME tablist
      var tablist = tab.closest('[role="tablist"]');
      if (tablist) {
        tablist.querySelectorAll('[role="tab"]').forEach(function (t) {
          t.setAttribute('aria-selected', 'false');
          t.classList.remove('version-tab--selected');
        });
      }

      // Activate clicked tab
      tab.setAttribute('aria-selected', 'true');
      tab.classList.add('version-tab--selected');
      tab.focus();

      // Build variant payload — same shape as container-detail.js selectVariant() L110–121
      var variantData = {
        tag: tab.dataset.tag || '',
        attestation_url: tab.dataset.attestationUrl || '',
        trivy_summary: null,
        multi_arch_platforms: [],
        size_amd64: tab.dataset.sizeAmd64 || '',
        size_arm64: tab.dataset.sizeArm64 || ''
      };
      try {
        if (tab.dataset.trivySummary) {
          variantData.trivy_summary = JSON.parse(tab.dataset.trivySummary);
        }
      } catch (_) { /* swallow malformed JSON */ }
      try {
        if (tab.dataset.multiArchPlatforms) {
          variantData.multi_arch_platforms = JSON.parse(tab.dataset.multiArchPlatforms);
        }
      } catch (_) { /* swallow malformed JSON */ }

      // Dispatch `phase-b-variant-changed` — <trust-strip> and <security-scan>
      // listen on document; keeps backward-compat with container-detail.js selectVariant()
      document.dispatchEvent(new CustomEvent('phase-b-variant-changed', {
        detail: variantData,
        bubbles: false
      }));

      // Also dispatch a component-scoped event for container-detail.js to intercept
      this.dispatchEvent(new CustomEvent('version-tabs-changed', {
        detail: variantData,
        bubbles: true
      }));
    }

    /* ------------------------------------------------------------------ */
    /*  Keyboard navigation — WAI-ARIA Tabs Manual Activation              */
    /*  ←/→  : navigate within tablist                                     */
    /*  ↑/↓  : navigate between tablist groups (version groups)            */
    /*  Home : jump to first tab in current tablist                        */
    /*  End  : jump to last tab in current tablist                         */
    /*  Enter/Space : activate focused tab                                 */
    /* ------------------------------------------------------------------ */

    _handleKeydown(e) {
      var tab = e.target.closest('[role="tab"]');
      if (!tab) return;

      var tablist = tab.closest('[role="tablist"]');
      if (!tablist) return;

      var tabs = Array.from(tablist.querySelectorAll('[role="tab"]'));
      var idx = tabs.indexOf(tab);
      var target;

      switch (e.key) {
        case 'ArrowLeft': {
          e.preventDefault();
          var prev = tabs[idx - 1] || tabs[tabs.length - 1];
          prev.focus();
          break;
        }
        case 'ArrowRight': {
          e.preventDefault();
          var next = tabs[idx + 1] || tabs[0];
          next.focus();
          break;
        }
        case 'ArrowUp': {
          e.preventDefault();
          var prevGroup = this._adjacentGroup(tablist, -1);
          if (prevGroup) {
            var prevGroupTabs = Array.from(prevGroup.querySelectorAll('[role="tab"]'));
            target = prevGroupTabs[Math.min(idx, prevGroupTabs.length - 1)];
            if (target) target.focus();
          }
          break;
        }
        case 'ArrowDown': {
          e.preventDefault();
          var nextGroup = this._adjacentGroup(tablist, +1);
          if (nextGroup) {
            var nextGroupTabs = Array.from(nextGroup.querySelectorAll('[role="tab"]'));
            target = nextGroupTabs[Math.min(idx, nextGroupTabs.length - 1)];
            if (target) target.focus();
          }
          break;
        }
        case 'Home': {
          e.preventDefault();
          if (tabs[0]) tabs[0].focus();
          break;
        }
        case 'End': {
          e.preventDefault();
          if (tabs[tabs.length - 1]) tabs[tabs.length - 1].focus();
          break;
        }
        case 'Enter':
        case ' ': {
          e.preventDefault();
          this._activateTab(tab);
          break;
        }
        default:
          break;
      }
    }

    /* Return the previous (-1) or next (+1) [role="tablist"] sibling group */
    _adjacentGroup(tablist, direction) {
      var groups = Array.from(this.querySelectorAll('[role="tablist"]'));
      var idx = groups.indexOf(tablist);
      return groups[idx + direction] || null;
    }

    /* Fix #1: fire phase-b-variant-changed for the initial active tab so
       Provenance, <trust-strip>, and <security-scan> bootstrap correctly on
       multi-version pages (where container-detail.js may only have the hidden
       synthetic .variant-tag.selected to work from). */
    _dispatchInitialVariant() {
      // Find the first [aria-selected="true"] tab in the component
      var initialTab = this.querySelector('[role="tab"][aria-selected="true"]');
      if (!initialTab) return;
      var variantData = {
        tag: initialTab.dataset.tag || '',
        attestation_url: initialTab.dataset.attestationUrl || '',
        trivy_summary: null,
        multi_arch_platforms: [],
        size_amd64: initialTab.dataset.sizeAmd64 || '',
        size_arm64: initialTab.dataset.sizeArm64 || ''
      };
      try {
        if (initialTab.dataset.trivySummary) {
          variantData.trivy_summary = JSON.parse(initialTab.dataset.trivySummary);
        }
      } catch (_) { /* swallow */ }
      try {
        if (initialTab.dataset.multiArchPlatforms) {
          variantData.multi_arch_platforms = JSON.parse(initialTab.dataset.multiArchPlatforms);
        }
      } catch (_) { /* swallow */ }
      document.dispatchEvent(new CustomEvent('phase-b-variant-changed', {
        detail: variantData,
        bubbles: false
      }));

      // P0-N1 fix: also dispatch version-tabs-changed (bubbles on host) so
      // container-detail.js:version-tabs-changed listener calls selectVariant(),
      // which populates SBOM/changelog/history/dep-health/lineage/pull-command.
      // Both consumers are idempotent: phase-b-variant-changed listeners only
      // update DOM text/visibility; selectVariant() is guarded by dataset reads
      // that are stable across calls. No double-flash risk.
      this.dispatchEvent(new CustomEvent('version-tabs-changed', {
        detail: variantData,
        bubbles: true
      }));
    }
  }

  // Guard against double-registration (Jekyll layouts may include the script twice)
  if (!customElements.get('version-tabs')) {
    customElements.define('version-tabs', VersionTabs);
  }
})();
