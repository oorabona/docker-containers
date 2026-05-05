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

    _updateSbom(url, id) {
      const el = this.querySelector('[data-trust="sbom"]');
      if (!el) return;
      const isCardSurface = !!this.closest('.container-card');
      if (url && id) {
        el.setAttribute('href', url);
        el.title = "View Sigstore attestation for this image's SBOM";
        el.style.display = '';
        el.classList.remove('is-pending');
        el.textContent = isCardSurface ? '📋 SBOM' : '📋 SBOM ATTESTED';
      } else {
        el.style.display = '';
        el.removeAttribute('href');
        el.classList.add('is-pending');
        el.title = 'SBOM attestation not yet generated. Will populate on next successful build with cosign attestation.';
        el.textContent = isCardSurface ? '📋 SBOM' : '📋 SBOM PENDING';
      }
    }

    _updateTrivy(summary) {
      const el = this.querySelector('[data-trust="trivy"]');
      if (!el) return;
      if (!summary || !summary.last_scan) {
        // WCAG 4.1.2: anchor with display:none must be removed from the AT tree.
        el.style.display = 'none';
        el.setAttribute('aria-hidden', 'true');
        return;
      }
      const counts = summary.counts || {};
      const critical = counts.critical || 0;
      const high = counts.high || 0;
      // Pick the count + label of the active severity so the number on the
      // badge always matches the badge colour. info-level (no CRIT, no HIGH)
      // surfaces "0" so the chip stays a positive signal rather than blank.
      let sev, displayCount, compactLabel, ariaSeverity;
      if (critical > 0) {
        sev = 'critical'; displayCount = critical; compactLabel = 'CRIT'; ariaSeverity = 'CRITICAL';
      } else if (high > 0) {
        sev = 'high';     displayCount = high;     compactLabel = 'HIGH'; ariaSeverity = 'HIGH';
      } else {
        sev = 'info';     displayCount = 0;        compactLabel = '';     ariaSeverity = 'critical / high';
      }
      el.setAttribute('data-severity', sev);
      const date = (summary.last_scan || '').slice(0, 10);
      const fullLabel = displayCount + ' ' + ariaSeverity + ' CVE(s) · scanned ' + date + ' · advisory mode (does not block builds)';
      // Compact label on dashboard cards (narrow width); full label on the
      // detail-page badge. Both surfaces duplicate the full label into
      // aria-label so screen-reader / touch users get the same context as
      // hover-tooltip users.
      const isCardSurface = !!this.closest('.container-card');
      if (isCardSurface) {
        el.textContent = '🛡 ' + displayCount + (compactLabel ? ' ' + compactLabel : '');
      } else {
        el.textContent = '🛡 TRIVY: ' + displayCount + ' ' + ariaSeverity + ' (advisory) · SCANNED ' + date;
      }
      el.title = fullLabel;
      el.setAttribute('aria-label', fullLabel);
      el.style.display = '';
      el.removeAttribute('aria-hidden');
    }

    _updateMultiArch(platforms) {
      const el = this.querySelector('[data-trust="multi-arch"]');
      if (!el) return;
      if (!platforms || platforms.length === 0) {
        // WCAG 4.1.2: anchor with display:none must be removed from the AT tree.
        el.style.display = 'none';
        el.setAttribute('aria-hidden', 'true');
        return;
      }
      // Card surface: compact count format (e.g. "🏗 ×2") — matches Liquid card output.
      // Detail surface: full format (e.g. "🏗 AMD64 + ARM64").
      // Defensively strip "os/" prefix (e.g. "linux/amd64" → "amd64") before uppercasing.
      const isCardSurface = !!this.closest('.container-card');
      const archNames = platforms.map(function(p) {
        var arch = p.includes('/') ? p.split('/').pop() : p;
        return arch.toUpperCase();
      });
      el.textContent = isCardSurface
        ? '🏗 ×' + platforms.length
        : '🏗 ' + archNames.join(' + ');
      el.title = 'Multi-arch manifest: ' + platforms.join(', ');
      el.setAttribute('aria-label', 'Multi-arch: ' + archNames.join(', '));
      el.style.display = '';
      el.removeAttribute('aria-hidden');
    }
  }

  customElements.define('trust-strip', TrustStrip);
})();
