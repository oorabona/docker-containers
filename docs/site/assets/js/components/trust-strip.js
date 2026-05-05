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
      this._updateSbom(variant.attestation_url, variant.attestation_id);
      this._updateTrivy(variant.trivy_summary);
      this._updateMultiArch(variant.multi_arch_platforms);
    }

    // M-1 fix: 2-state SBOM badge (drop N/A / partial middle state — both resolve to PENDING).
    // attested (url AND id) → styled chip with link, text "📋 SBOM ATTESTED".
    // else → muted is-pending chip, text "📋 SBOM PENDING", no href.
    _updateSbom(url, id) {
      const el = this.querySelector('[data-trust="sbom"]');
      if (!el) return;
      if (url && id) {
        // Attested — both url and id present
        el.setAttribute('href', url);
        el.textContent = '📋 SBOM ATTESTED';
        el.dataset.sbomState = 'attested';
        el.title = "View Sigstore attestation for this image's SBOM";
        el.style.display = '';
        el.classList.remove('is-pending');
      } else {
        // Pending — attestation not yet generated or incomplete
        el.style.display = '';
        el.removeAttribute('href');
        el.textContent = '📋 SBOM PENDING';
        el.dataset.sbomState = 'pending';
        el.classList.add('is-pending');
        el.title = 'SBOM attestation not yet generated. Will populate on next successful build with cosign attestation.';
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
      // S-1 fix: "(advisory)" qualifier and tooltip match Liquid initial state in container-card.html.
      el.textContent = '🛡 TRIVY: ' + critical + ' CRITICAL (advisory) · SCANNED ' + date;
      el.title = 'Trivy scan results are advisory; severity counts indicate detected CVEs but do not block builds.';
      el.style.display = '';
    }

    _updateMultiArch(platforms) {
      const el = this.querySelector('[data-trust="multi-arch"]');
      if (!el) return;
      if (!platforms || platforms.length === 0) {
        el.style.display = 'none';
        return;
      }
      // Fix #8/#9: brand-voice uppercase — matches Liquid initial state ("AMD64 + ARM64").
      // Defensively strip "os/" prefix (e.g. "linux/amd64" → "amd64") before uppercasing.
      el.textContent = '🏗 ' + platforms.map(function(p) {
        var arch = p.includes('/') ? p.split('/').pop() : p;
        return arch.toUpperCase();
      }).join(' + ');
      el.style.display = '';
    }
  }

  customElements.define('trust-strip', TrustStrip);
})();
