// docs/site/assets/js/components/security-scan.js
//
// Vanilla custom element. CSP-clean. Detail-page only.
// Re-renders Security Scan section on `phase-b-variant-changed`.
// XSS-safe: only textContent + createElement, never innerHTML (Trivy advisory data is upstream-controlled).

(function () {
  'use strict';

  class SecurityScan extends HTMLElement {
    connectedCallback() {
      this._handler = (e) => this._update(e.detail);
      document.addEventListener('phase-b-variant-changed', this._handler);
    }

    disconnectedCallback() {
      if (this._handler) document.removeEventListener('phase-b-variant-changed', this._handler);
    }

    _update(variant) {
      if (!variant || !variant.trivy_summary) {
        this.style.display = 'none';
        return;
      }
      const summary = variant.trivy_summary;
      if (!summary.last_scan) {
        this.style.display = 'none';
        return;
      }
      this.style.display = '';

      // last_scan
      const lastScanEl = this.querySelector('[data-scan="last-scan"]');
      if (lastScanEl) lastScanEl.textContent = (summary.last_scan || '').slice(0, 10);

      // severity counts
      const counts = summary.counts || {};
      ['critical', 'high', 'medium', 'low', 'info'].forEach((k) => {
        const span = this.querySelector('[data-scan-count="' + k + '"]');
        if (!span) return;
        const value = counts[k] != null ? counts[k] : 0;
        span.textContent = value;
        // Toggle .nonzero on the count span and its parent cell so CSS selectors
        // (.severity-grid > *:nth-child(N).nonzero .count and .count[data-nonzero])
        // can color critical/high columns when their value is > 0.
        span.classList.toggle('nonzero', value > 0);
        if (span.parentElement) span.parentElement.classList.toggle('nonzero', value > 0);
      });

      // top advisories
      const list = this.querySelector('[data-scan="top-advisories"]');
      if (!list) return;
      const advisories = Array.isArray(summary.top_advisories) ? summary.top_advisories : [];
      // Clear children (don't use innerHTML)
      while (list.firstChild) list.removeChild(list.firstChild);
      advisories.forEach((adv) => {
        const li = document.createElement('li');
        const strong = document.createElement('strong');
        strong.textContent = adv.rule_id || '';
        li.appendChild(strong);
        const sev = (adv.severity || '').toUpperCase();
        const pkg = adv.package_name || '';
        const title = adv.title || '';
        li.appendChild(document.createTextNode(' (' + sev + ') — ' + pkg + ' — ' + title));
        list.appendChild(li);
      });

      // Hide the advisories block entirely if empty
      const advisoriesWrap = this.querySelector('[data-scan="advisories-wrap"]');
      if (advisoriesWrap) {
        advisoriesWrap.style.display = advisories.length > 0 ? '' : 'none';
      }
    }
  }

  customElements.define('security-scan', SecurityScan);
})();
