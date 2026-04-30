// docs/site/assets/js/components/trust-strip.js
//
// Vanilla custom element. CSP-clean (no eval). No dependencies.
// Listens for `phase-b-variant-changed` on the closest .container-card ancestor
// (dashboard: one trust-strip per card, prevents cross-card contamination) or
// on document when no card ancestor exists (detail page: single trust-strip).
// Initial state is rendered server-side by Liquid; this only handles updates.

(function () {
  'use strict';

  class TrustStrip extends HTMLElement {
    connectedCallback() {
      // Scope listener to the parent card on dashboard (one trust-strip per card)
      // Fall back to document on the detail page (single trust-strip)
      this._listenerRoot = this.closest('.container-card') || document;
      this._handler = (e) => this._update(e.detail);
      this._listenerRoot.addEventListener('phase-b-variant-changed', this._handler);
    }

    disconnectedCallback() {
      if (this._handler && this._listenerRoot) {
        this._listenerRoot.removeEventListener('phase-b-variant-changed', this._handler);
        this._listenerRoot = null;
        this._handler = null;
      }
    }

    _update(variant) {
      if (!variant) return;
      this._updateSbom(variant.attestation_url);
      this._updateTrivy(variant.trivy_summary);
      this._updateMultiArch(variant.multi_arch_platforms);
    }

    _updateSbom(url) {
      const el = this.querySelector('[data-trust="sbom"]');
      if (!el) return;
      if (url) {
        el.setAttribute('href', url);
        el.style.display = '';
      } else {
        el.style.display = 'none';
      }
    }

    _updateTrivy(summary) {
      const el = this.querySelector('[data-trust="trivy"]');
      if (!el) return;
      if (!summary || !summary.last_scan) {
        el.style.display = 'none';
        return;
      }
      const counts = summary.counts || {};
      const critical = counts.critical || 0;
      const high = counts.high || 0;
      const sev = critical > 0 ? 'critical' : (high > 0 ? 'high' : 'info');
      el.setAttribute('data-severity', sev);
      const date = (summary.last_scan || '').slice(0, 10);
      el.textContent = '🛡 Trivy: ' + critical + ' CRITICAL · scanned ' + date;
      el.style.display = '';
    }

    _updateMultiArch(platforms) {
      const el = this.querySelector('[data-trust="multi-arch"]');
      if (!el) return;
      if (!platforms || platforms.length === 0) {
        el.style.display = 'none';
        return;
      }
      el.textContent = '🏗 ' + platforms.join(' + ');
      el.style.display = '';
    }
  }

  customElements.define('trust-strip', TrustStrip);
})();
