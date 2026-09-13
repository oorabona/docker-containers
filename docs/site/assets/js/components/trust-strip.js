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
      this._updateSbom(variant);
      this._updateTrivy(variant.trivy_summary);
      this._updateMultiArch(variant.multi_arch_platforms);
    }

    _imageRef(tag) {
      const card = this.closest('.container-card');
      const name = card && card.dataset ? card.dataset.container : '';
      if (name && tag) return name + ':' + tag;
      return tag || 'this image';
    }

    _updateSbom(variant) {
      const el = this.querySelector('[data-trust="sbom"]');
      if (!el) return;
      const url = variant.attestation_url;
      const id = variant.attestation_id;
      const imageRef = this._imageRef(variant.tag);
      const isCardSurface = !!this.closest('.container-card');
      if (url && id) {
        el.setAttribute('href', url);
        el.title = "View Sigstore attestation for this image's SBOM";
        el.setAttribute('aria-label', 'View SBOM attestation for ' + imageRef);
        el.style.display = '';
        el.classList.remove('is-pending');
        el.textContent = isCardSurface ? '📋 SBOM' : '📋 SBOM ATTESTED';
      } else {
        el.style.display = '';
        el.removeAttribute('href');
        el.classList.add('is-pending');
        el.title = 'SBOM attestation not yet generated. Will populate on next successful build with cosign attestation.';
        el.setAttribute('aria-label', 'SBOM attestation pending for ' + imageRef);
        el.textContent = isCardSurface ? '📋 SBOM' : '📋 SBOM PENDING';
      }
    }

    _updateTrivy(summary) {
      const el = this.querySelector('[data-trust="trivy"]');
      if (!el) return;
      // Liquid's `{% if %}` treats only nil and false as absent; JavaScript
      // must keep empty strings and zero present rather than using !display_source.
      const hasLiquidDisplaySource = summary
        && summary.display_source !== undefined
        && summary.display_source !== null
        && summary.display_source !== false;
      if (!hasLiquidDisplaySource) {
        // WCAG 4.1.2: anchor with display:none must be removed from the AT tree.
        el.textContent = '';
        el.style.display = 'none';
        el.setAttribute('aria-hidden', 'true');
        return;
      }
      const source = summary.display_source;
      if (source === 'unavailable') {
        const fullLabel = 'No security evidence available — Code Scanning could not be read and no usable scan record was found';
        el.setAttribute('data-severity', 'unknown');
        el.textContent = '🛡 no evidence';
        el.title = fullLabel;
        el.setAttribute('aria-label', fullLabel);
        el.style.display = '';
        el.removeAttribute('aria-hidden');
        return;
      }
      if (source !== 'code-scanning' && source !== 'scan-record') {
        const fullLabel = 'Security evidence is not recorded for this image';
        el.setAttribute('data-severity', 'not-recorded');
        el.textContent = '🛡 not recorded';
        el.title = fullLabel;
        el.setAttribute('aria-label', fullLabel);
        el.style.display = '';
        el.removeAttribute('aria-hidden');
        return;
      }
      const counts = summary.counts || {};
      const critical = counts.critical || 0;
      const high = counts.high || 0;
      const total = critical + high + (counts.medium || 0) + (counts.low || 0) + (counts.info || 0);
      let sev;
      if (critical > 0) {
        sev = 'critical';
      } else if (high > 0) {
        sev = 'high';
      } else if (total > 0) {
        sev = 'advisory';
      } else {
        sev = 'info';
      }
      el.setAttribute('data-severity', sev);
      const date = (summary.as_of || '').slice(0, 10);
      let badgeText, fullLabel;
      if (source === 'code-scanning') {
        badgeText = total + ' open alerts';
        fullLabel = total + ' open Code Scanning alerts · fetched ' + date + ' · advisory mode (does not block builds)';
      } else if (source === 'scan-record') {
        badgeText = total + ' findings';
        fullLabel = total + ' finding(s) from the recorded scan · scanned ' + date + ' · advisory mode (does not block builds)';
      }
      el.textContent = '🛡 ' + badgeText;
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
