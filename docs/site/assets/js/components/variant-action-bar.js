// docs/site/assets/js/components/variant-action-bar.js
//
// Vanilla custom element (light DOM). CSP-clean (no eval, no innerHTML).
// Renders: registry pills + version pills + flavor pills + pull/verify commands + per-variant signals strip.
// Sticky-on-scroll (auto-collapses to signals strip; scroll up re-expands). Dispatches variant-action-bar:variant-changed.
// Two-way sync with legacy phase-b-variant-changed / version-tabs-changed events.

(function () {
  'use strict';

  class VariantActionBar extends HTMLElement {

    // -------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------

    connectedCallback() {
      this._parseData();
      this._render();
      this._attachListeners();
      this._initSticky();
    }

    disconnectedCallback() {
      if (this._observer) { this._observer.disconnect(); }
      // F5: clean up nav resize tracking
      if (this._navResizeObserver) { this._navResizeObserver.disconnect(); }
      if (this._resizeHandler) { window.removeEventListener('resize', this._resizeHandler); }
      // F7: remove version-tabs-changed listener to prevent leak on DOM re-attach
      if (this._versionTabsHandler) { document.removeEventListener('version-tabs-changed', this._versionTabsHandler); }
    }

    // -------------------------------------------------------
    // Data parsing
    // -------------------------------------------------------

    _parseData() {
      // F3: Liquid uses | escape (HTML-entity encoding). Browsers auto-decode attribute
      // values, so attr arrives as raw JSON. decodeURIComponent is wrong here — it throws
      // URIError on any bare % in tag names or URLs. Drop it entirely.
      var parse = function (attr, fallback) {
        try { return JSON.parse(attr || ''); }
        catch (e) { return fallback; }
      };

      this._container = this.dataset.container || '';
      this._imageBase = this.dataset.imageBase || '';
      this._imageBaseDockerHub = this.dataset.imageBaseDockerhub || this.dataset.imageBase || '';
      this._defaultTag = this.dataset.defaultTag || '';

      // Registry options (default: GHCR + Docker Hub)
      var defaultRegistries = [
        { id: 'ghcr', label: 'GHCR', host: 'ghcr.io/' },
        { id: 'dockerhub', label: 'Docker Hub', host: '' }
      ];
      this._registries = parse(this.dataset.registries, defaultRegistries);
      if (!this._registries || !this._registries.length) {
        this._registries = defaultRegistries;
      }
      var defaultFromAttr = (this.dataset.defaultRegistry || '').trim();
      this._selectedRegistry = defaultFromAttr
        || (this._registries.length > 0 ? this._registries[0].id : 'ghcr');

      // versions: array of version-group objects with .tag + .variants[]
      this._versions = parse(this.dataset.versions, []);
      // flavors: flat array of flavor objects ({ name, label })
      this._flavors = parse(this.dataset.flavors, []);
      // variants: flat lookup array of all variant objects
      this._variants = parse(this.dataset.variants, []);

      // Select the first version/flavor as default
      this._selectedVersion = this.dataset.defaultVersion
        || (this._versions[0] && this._versions[0].tag) || '';
      this._selectedFlavor = this.dataset.defaultFlavor
        || (this._flavors[0] && this._flavors[0].name) || '';

      // Find initial selected variant
      this._currentVariant = this._findVariant(this._selectedVersion, this._selectedFlavor);
    }

    // Find a variant matching version + flavor.
    // Falls back to defaultTag match, then first variant.
    _findVariant(version, flavor) {
      var variants = this._variants;
      if (!variants || variants.length === 0) { return null; }

      // Exact match on version + flavor
      if (version && flavor) {
        for (var i = 0; i < variants.length; i++) {
          var v = variants[i];
          if (v.version === version && v.flavor === flavor) { return v; }
        }
      }

      // Match by version only (no flavor dimension)
      if (version) {
        for (var j = 0; j < variants.length; j++) {
          if (variants[j].version === version) { return variants[j]; }
        }
      }

      // Match by default tag
      if (this._defaultTag) {
        for (var k = 0; k < variants.length; k++) {
          if (variants[k].tag === this._defaultTag) { return variants[k]; }
        }
      }

      return variants[0] || null;
    }

    // -------------------------------------------------------
    // Render (DOM construction — no innerHTML, XSS-safe)
    // -------------------------------------------------------

    _render() {
      while (this.firstChild) { this.removeChild(this.firstChild); }

      // Sentinel div for IntersectionObserver — must precede card in DOM
      var sentinel = document.createElement('div');
      sentinel.className = 'vab-sentinel';
      sentinel.setAttribute('aria-hidden', 'true');
      this.appendChild(sentinel);

      var card = document.createElement('div');
      card.className = 'vab-card';
      this.appendChild(card);

      // Row 1 — selectors: [REGISTRY pills] · [VERSION pills] · [FLAVOR pills]
      var hasMultipleVersions = this._versions && this._versions.length > 1;
      var hasFlavors = this._flavors && this._flavors.length > 0;
      var hasRegistries = this._registries && this._registries.length > 1;

      if (hasRegistries || hasMultipleVersions || hasFlavors) {
        var row1 = document.createElement('div');
        row1.className = 'vab-row vab-row--selectors';

        if (hasRegistries) {
          row1.appendChild(
            this._makePillGroup('Registry', this._registries, 'id', this._selectedRegistry,
              'vab-registry-pill', 'vab-registry-pills vab-pill-group--registry')
          );
        }

        if (hasMultipleVersions) {
          row1.appendChild(
            this._makePillGroup('Version', this._versions, 'tag', this._selectedVersion,
              'vab-version-pill', 'vab-version-pills')
          );
        }

        if (hasFlavors) {
          row1.appendChild(
            this._makePillGroup('Flavor', this._flavors, 'name', this._selectedFlavor,
              'vab-flavor-pill', 'vab-flavor-pills')
          );
        }

        card.appendChild(row1);
      }

      // Row 2 — commands (docker pull + cosign verify)
      var row2 = document.createElement('div');
      row2.className = 'vab-row vab-row--commands';
      row2.appendChild(this._makeCommandBlock('pull'));
      row2.appendChild(this._makeCommandBlock('verify'));
      card.appendChild(row2);

      // Row 3 — signals strip (status · size amd64 · size arm64)
      var row3 = document.createElement('div');
      row3.className = 'vab-row vab-row--signals';
      row3.appendChild(this._makeSignalsStrip());
      card.appendChild(row3);

      // Store refs
      this._cardEl = card;
      this._sentinelEl = sentinel;

      this._updateCommands();
      this._updateSignals();
    }

    // Build a labelled pill group (radiogroup)
    // F4: roving tabindex — only the active pill has tabindex=0, others -1.
    _makePillGroup(labelText, items, valueKey, selected, pillClass, groupClass) {
      var wrap = document.createElement('div');
      wrap.className = 'vab-pill-group ' + groupClass;

      var label = document.createElement('span');
      label.className = 'vab-pill-label';
      label.textContent = labelText;
      label.setAttribute('aria-hidden', 'true');
      wrap.appendChild(label);

      var row = document.createElement('div');
      row.className = 'vab-pills';
      row.setAttribute('role', 'radiogroup');
      row.setAttribute('aria-label', labelText);

      for (var i = 0; i < items.length; i++) {
        var item = items[i];
        var isActive = item[valueKey] === selected;
        var pill = document.createElement('button');
        pill.type = 'button';
        pill.className = pillClass + (isActive ? ' vab-pill--active' : '');
        pill.setAttribute('role', 'radio');
        pill.setAttribute('aria-checked', isActive ? 'true' : 'false');
        pill.setAttribute('data-value', item[valueKey]);
        // F4: roving tabindex — only the selected pill is in the tab sequence
        pill.tabIndex = isActive ? 0 : -1;
        pill.textContent = item.label || item[valueKey];
        row.appendChild(pill);
      }

      wrap.appendChild(row);
      return wrap;
    }

    // Build one command block (eyebrow + code + copy button)
    _makeCommandBlock(type) {
      var labelText = type === 'pull' ? 'PULL' : 'VERIFY';
      var ariaLabel = type === 'pull' ? 'Docker pull command' : 'Cosign verify command';

      var wrap = document.createElement('div');
      wrap.className = 'vab-command-block';

      var eyebrow = document.createElement('p');
      eyebrow.className = 'vab-command-label eyebrow';
      eyebrow.setAttribute('aria-hidden', 'true');
      eyebrow.textContent = labelText;
      wrap.appendChild(eyebrow);

      var inputRow = document.createElement('div');
      inputRow.className = 'vab-command-input-row';

      var code = document.createElement('code');
      code.className = 'vab-command-code';
      code.setAttribute('data-vab-cmd', type);
      code.setAttribute('aria-label', ariaLabel);
      inputRow.appendChild(code);

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'vab-copy-btn';
      btn.setAttribute('data-vab-copy', type);
      btn.setAttribute('aria-label', 'Copy ' + labelText.toLowerCase() + ' command');
      var icon = document.createElement('span');
      icon.className = 'vab-copy-icon';
      icon.setAttribute('aria-hidden', 'true');
      icon.textContent = '⧉'; // ⧉
      btn.appendChild(icon);
      inputRow.appendChild(btn);

      wrap.appendChild(inputRow);
      return wrap;
    }

    // Build the signals strip
    _makeSignalsStrip() {
      var strip = document.createElement('div');
      strip.className = 'vab-signals';

      var makeSig = function (wrapCls, labelText, signalKey) {
        var wrap = document.createElement('span');
        wrap.className = 'vab-signal ' + wrapCls;
        var lbl = document.createElement('span');
        lbl.className = 'vab-signal-label';
        lbl.textContent = labelText;
        var val = document.createElement('span');
        val.className = 'vab-signal-value';
        val.setAttribute('data-vab-signal', signalKey);
        wrap.appendChild(lbl);
        wrap.appendChild(val);
        return wrap;
      };

      var sep = function () {
        var s = document.createElement('span');
        s.className = 'vab-signal-sep';
        s.setAttribute('aria-hidden', 'true');
        s.textContent = '·'; // ·
        return s;
      };

      strip.appendChild(makeSig('vab-signal--status', 'STATUS', 'status'));
      strip.appendChild(sep());
      strip.appendChild(makeSig('vab-signal--size', 'AMD64', 'size-amd64'));
      strip.appendChild(sep());
      strip.appendChild(makeSig('vab-signal--size', 'ARM64', 'size-arm64'));
      return strip;
    }

    // -------------------------------------------------------
    // Update content when variant changes
    // -------------------------------------------------------

    _updateCommands() {
      var v = this._currentVariant;
      var tag = (v && v.tag) ? v.tag : this._defaultTag;
      var ghcrBase = this._imageBase;
      var owner = this._extractOwner(ghcrBase);

      // Pull command uses selected registry; verify always uses GHCR (Sigstore lives there)
      var pullBase = (this._selectedRegistry === 'dockerhub')
        ? this._imageBaseDockerHub
        : ghcrBase;
      var pullCmd = 'docker pull ' + pullBase + ':' + tag;
      var verifyCmd = 'cosign verify ' + ghcrBase + ':' + tag
        + ' --certificate-identity-regexp=https://github.com/' + owner
        + ' --certificate-oidc-issuer=https://token.actions.githubusercontent.com';

      var pullEl = this.querySelector('[data-vab-cmd="pull"]');
      var verifyEl = this.querySelector('[data-vab-cmd="verify"]');
      if (pullEl) { pullEl.textContent = pullCmd; }
      if (verifyEl) { verifyEl.textContent = verifyCmd; }

      // Show verify note when registry is not GHCR
      var verifyBlock = verifyEl && verifyEl.closest('.vab-command-block');
      if (verifyBlock) {
        var existingNote = verifyBlock.querySelector('.vab-verify-note');
        if (this._selectedRegistry !== 'ghcr') {
          if (!existingNote) {
            var note = document.createElement('small');
            note.className = 'vab-verify-note';
            note.setAttribute('role', 'status');
            note.setAttribute('aria-live', 'polite');
            note.textContent = 'Verified via GHCR · attestation source';
            verifyBlock.appendChild(note);
          }
        } else {
          if (existingNote) { verifyBlock.removeChild(existingNote); }
        }
      }
    }

    _extractOwner(base) {
      // ghcr.io/owner/container -> owner
      var parts = (base || '').split('/');
      return parts.length >= 2 ? parts[1] : '';
    }

    _updateSignals() {
      var v = this._currentVariant;
      var statusText = v
        ? (v.build_digest && v.build_digest !== 'unknown' ? 'OK' : 'PENDING')
        : '—'; // —

      var statusSig = this.querySelector('[data-vab-signal="status"]');
      if (statusSig) {
        statusSig.textContent = statusText;
        var statusWrap = statusSig.closest('.vab-signal--status');
        if (statusWrap) { statusWrap.setAttribute('data-status', statusText.toLowerCase()); }
      }

      var amdEl = this.querySelector('[data-vab-signal="size-amd64"]');
      var armEl = this.querySelector('[data-vab-signal="size-arm64"]');
      if (amdEl) { amdEl.textContent = (v && v.size_amd64) ? v.size_amd64 : '—'; }
      if (armEl) { armEl.textContent = (v && v.size_arm64) ? v.size_arm64 : '—'; }
    }

    // -------------------------------------------------------
    // Pill selection
    // -------------------------------------------------------

    _onVersionPillClick(value) {
      this._selectedVersion = value;
      this._updatePillActive('vab-version-pill', value);
      this._currentVariant = this._findVariant(this._selectedVersion, this._selectedFlavor);
      this._updateCommands();
      this._updateSignals();
      this._dispatchVariantChanged();
    }

    _onFlavorPillClick(value) {
      this._selectedFlavor = value;
      this._updatePillActive('vab-flavor-pill', value);
      this._currentVariant = this._findVariant(this._selectedVersion, this._selectedFlavor);
      this._updateCommands();
      this._updateSignals();
      this._dispatchVariantChanged();
    }


    _onRegistryPillClick(value) {
      this._selectedRegistry = value;
      this._updatePillActive('vab-registry-pill', value);
      this._updateCommands();
    }


    // F4: also update roving tabindex when active pill changes
    _updatePillActive(pillClass, value) {
      var pills = this.querySelectorAll('.' + pillClass);
      for (var i = 0; i < pills.length; i++) {
        var active = pills[i].dataset.value === value;
        pills[i].classList.toggle('vab-pill--active', active);
        pills[i].setAttribute('aria-checked', active ? 'true' : 'false');
        // F4: keep roving tabindex invariant
        pills[i].tabIndex = active ? 0 : -1;
      }
    }

    // -------------------------------------------------------
    // Copy to clipboard
    // -------------------------------------------------------

    _onCopyClick(type) {
      var codeEl = this.querySelector('[data-vab-cmd="' + type + '"]');
      if (!codeEl) { return; }
      var text = codeEl.textContent || '';
      var btnEl = this.querySelector('[data-vab-copy="' + type + '"]');
      var iconEl = btnEl && btnEl.querySelector('.vab-copy-icon');

      var showCopied = function () {
        if (iconEl) { iconEl.textContent = '✓'; } // ✓
        if (btnEl) { btnEl.classList.add('vab-copy-btn--copied'); }
        setTimeout(function () {
          if (iconEl) { iconEl.textContent = '⧉'; } // ⧉
          if (btnEl) { btnEl.classList.remove('vab-copy-btn--copied'); }
        }, 2000);
      };

      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(showCopied).catch(showCopied);
      } else {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
        document.body.appendChild(ta);
        ta.focus();
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        document.body.removeChild(ta);
        showCopied();
      }
    }

    // -------------------------------------------------------
    // Custom event dispatch (new + legacy bridge)
    // -------------------------------------------------------

    _dispatchVariantChanged() {
      var v = this._currentVariant;
      var detail = {
        variant: v,
        tag: (v && v.tag) || this._defaultTag,
        attestation_url: (v && v.attestation_url) || '',
        attestation_id:  (v && v.attestation_id)  || '',
        trivy_summary:   (v && v.trivy_summary)    || null,
        multi_arch_platforms: (v && v.multi_arch_platforms) || []
      };

      document.dispatchEvent(new CustomEvent('variant-action-bar:variant-changed', {
        bubbles: true, detail: detail
      }));

      // Backwards-compatible bridge: existing trust-strip, security-scan, provenance
      document.dispatchEvent(new CustomEvent('phase-b-variant-changed', {
        bubbles: true, detail: detail
      }));

      // F1: also drive container-detail.js which listens to version-tabs-changed
      // to update SBOM, changelog, lineage, history, dep-health, etc.
      // Tag detail.source so our own version-tabs-changed listener can skip it
      // and prevent A<->B ping-pong.
      var versionTabsEvent = new CustomEvent('version-tabs-changed', {
        bubbles: true,
        detail: { variant: v, tag: detail.tag, source: 'variant-action-bar' }
      });
      document.body.dispatchEvent(versionTabsEvent);
    }

    // Two-way sync: if legacy version-tabs fires, update our pills + commands.
    // F1 re-entry guard: skip events that originated from this component.
    // F7: extracted as named method so disconnectedCallback can removeEventListener.
    _onVersionTabsChanged(e) {
      // F1: ignore events we dispatched ourselves — prevents A<->B ping-pong
      if (e.detail && e.detail.source === 'variant-action-bar') { return; }

      var newTag = e.detail && e.detail.tag;
      if (!newTag) { return; }
      var found = null;
      var variants = this._variants;
      for (var i = 0; i < variants.length; i++) {
        if (variants[i].tag === newTag) { found = variants[i]; break; }
      }
      if (!found) { return; }
      this._currentVariant = found;
      if (found.version) {
        this._selectedVersion = found.version;
        this._updatePillActive('vab-version-pill', found.version);
      }
      if (found.flavor) {
        this._selectedFlavor = found.flavor;
        this._updatePillActive('vab-flavor-pill', found.flavor);
      }
      this._updateCommands();
      this._updateSignals();
    }

    // -------------------------------------------------------
    // Sticky / collapse
    // -------------------------------------------------------

    _refreshNavHeight() {
      var navEl = document.querySelector('.site-nav');
      var navH = navEl ? Math.round(navEl.getBoundingClientRect().height) : 60;
      this.style.setProperty('--vab-nav-height', navH + 'px');
      this._setupStickyObserver(navH);
    }

    _setupStickyObserver(navH) {
      if (this._observer) { this._observer.disconnect(); }
      var self = this;
      this._observer = new IntersectionObserver(function (entries) {
        var collapsed = !entries[0].isIntersecting;
        self._setCollapsed(collapsed);
      }, {
        root: null,
        rootMargin: '-' + navH + 'px 0px 0px 0px',
        threshold: 0
      });
      if (this._sentinelEl) { this._observer.observe(this._sentinelEl); }
    }

    _initSticky() {
      if (!('IntersectionObserver' in window)) { return; }
      var self = this;

      var navEl = document.querySelector('.site-nav');
      var navH = navEl ? Math.round(navEl.getBoundingClientRect().height) : 60;
      this.style.setProperty('--vab-nav-height', navH + 'px');

      this._setupStickyObserver(navH);

      // F5: keep nav height fresh on resize/orientation change so rootMargin
      // stays correct across breakpoints.
      if (typeof ResizeObserver !== 'undefined' && navEl) {
        this._navResizeObserver = new ResizeObserver(function (entries) {
          var height = entries[0].contentRect.height;
          self.style.setProperty('--vab-nav-height', height + 'px');
          self._setupStickyObserver(Math.round(height));
        });
        this._navResizeObserver.observe(navEl);
      } else {
        // Fallback: debounced resize listener for browsers without ResizeObserver
        var resizeTimer;
        this._resizeHandler = function () {
          clearTimeout(resizeTimer);
          resizeTimer = setTimeout(function () { self._refreshNavHeight(); }, 100);
        };
        window.addEventListener('resize', this._resizeHandler);
      }
    }

    _setCollapsed(collapsed) {
      if (collapsed) {
        this.setAttribute('data-collapsed', '');
      } else {
        this.removeAttribute('data-collapsed');
      }
    }

    // -------------------------------------------------------
    // Delegated event listeners
    // -------------------------------------------------------

    _attachListeners() {
      var self = this;

      this.addEventListener('click', function (e) {
        var rPill = e.target.closest('.vab-registry-pill');
        if (rPill) { self._onRegistryPillClick(rPill.dataset.value); return; }

        var vPill = e.target.closest('.vab-version-pill');
        if (vPill) { self._onVersionPillClick(vPill.dataset.value); return; }

        var fPill = e.target.closest('.vab-flavor-pill');
        if (fPill) { self._onFlavorPillClick(fPill.dataset.value); return; }

        var copyBtn = e.target.closest('.vab-copy-btn');
        if (copyBtn) { self._onCopyClick(copyBtn.getAttribute('data-vab-copy')); return; }
      });

      // F4: keyboard navigation for radiogroup pills (WAI-ARIA APG roving tabindex).
      // ArrowLeft/Right move focus+selection; Home/End jump to first/last.
      this.addEventListener('keydown', function (e) {
        var pill = e.target.closest('.vab-registry-pill, .vab-version-pill, .vab-flavor-pill');
        if (!pill) { return; }
        var keys = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
        if (keys.indexOf(e.key) === -1) { return; }
        e.preventDefault();
        var group = pill.parentElement;
        var pills = Array.prototype.slice.call(group.querySelectorAll('button'));
        var idx = pills.indexOf(pill);
        var next;
        if (e.key === 'ArrowLeft')       { next = (idx - 1 + pills.length) % pills.length; }
        else if (e.key === 'ArrowRight') { next = (idx + 1) % pills.length; }
        else if (e.key === 'Home')       { next = 0; }
        else                             { next = pills.length - 1; }
        pills[next].focus();
        pills[next].click();
      });

      // F7: store bound handler reference so disconnectedCallback can remove it cleanly.
      // F1: _onVersionTabsChanged has the re-entry guard (source === 'variant-action-bar').
      this._versionTabsHandler = this._onVersionTabsChanged.bind(this);
      document.addEventListener('version-tabs-changed', this._versionTabsHandler);
    }
  }

  if (!customElements.get('variant-action-bar')) {
    customElements.define('variant-action-bar', VariantActionBar);
  }
})();
