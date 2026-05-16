// docs/site/assets/js/components/page-toc.js
//
// Vanilla custom element (light DOM). CSP-clean (no eval, no innerHTML).
// Renders a sticky right-side TOC sidebar on desktop (>=1280px) and a
// floating drawer-button on mobile (<1280px).
// Active section tracking via scroll + requestAnimationFrame (passive).
// Smooth-scroll with prefers-reduced-motion support.

(function () {
  'use strict';

  // Fallback nav height (px) — used only when the nav element is not found.
  // Measured from .site-nav padding 0.85rem*2 + ~38px line-height ~ 64px total.
  var NAV_HEIGHT_FALLBACK = 64;

  class PageToc extends HTMLElement {

    // -------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------

    connectedCallback() {
      this._anchors = [];      // [{id, label}] filtered to sections present in DOM
      this._sections = [];     // [Element] — section elements in DOM order
      this._links = [];        // [<a>] — TOC anchor elements (desktop)
      this._drawerLinks = [];  // [<a>] — TOC anchor elements (mobile drawer)
      this._activeId = null;
      this._isMobile = false;
      this._triggerBtn = null;
      this._drawer = null;
      this._overlay = null;
      this._mql = null;
      this._onMqlChange = null;
      this._onKeydown = null;
      this._raf = null;        // pending requestAnimationFrame handle

      // Corrective re-aim guards (P2-1)
      this._clickSeq = 0;
      this._clickRaf = null;   // pending click-defer rAF handle (cancelled on new click / disconnect)
      this._reaimTimer = null;
      this._reaimAborted = false;
      this._reaimAbortListeners = null; // {wheel, touchstart, keydown} refs for cleanup

      this._parseAnchors();
      this._render();
      this._setupScrollHighlight();
      this._setupMobileQuery();
    }

    disconnectedCallback() {
      window.removeEventListener('scroll', this._boundOnScroll);
      window.removeEventListener('resize', this._boundOnScroll);
      if (this._raf !== null) {
        cancelAnimationFrame(this._raf);
        this._raf = null;
      }
      if (this._mql && this._onMqlChange) {
        this._mql.removeEventListener('change', this._onMqlChange);
        this._mql = null;
        this._onMqlChange = null;
      }
      if (this._onKeydown) {
        document.removeEventListener('keydown', this._onKeydown);
        this._onKeydown = null;
      }
      // Clean up pending click-defer rAF and corrective re-aim state.
      if (this._clickRaf !== null) {
        cancelAnimationFrame(this._clickRaf);
        this._clickRaf = null;
      }
      if (this._reaimTimer !== null) {
        clearTimeout(this._reaimTimer);
        this._reaimTimer = null;
      }
      this._removeReaimAbortListeners();
    }

    // -------------------------------------------------------
    // Data parsing (NO decodeURIComponent — raw JSON.parse only)
    // -------------------------------------------------------

    _parseAnchors() {
      var raw = this.dataset.anchors || '[]';
      var candidates;
      try {
        candidates = JSON.parse(raw);
      } catch (e) {
        candidates = [];
      }

      var self = this;
      candidates.forEach(function (entry) {
        var el = document.getElementById(entry.id);
        if (el) {
          self._anchors.push({ id: entry.id, label: entry.label });
          self._sections.push(el);
        }
      });
    }

    // -------------------------------------------------------
    // Rendering — light DOM, textContent only (XSS-safe)
    // -------------------------------------------------------

    _render() {
      // Remove any previously rendered subtree (keep <noscript> only).
      var toRemove = [];
      for (var i = 0; i < this.childNodes.length; i++) {
        var node = this.childNodes[i];
        if (node.nodeName !== 'NOSCRIPT') {
          toRemove.push(node);
        }
      }
      toRemove.forEach(function (n) { n.parentNode.removeChild(n); });

      if (this._anchors.length === 0) { return; }

      var self = this;

      // --- Desktop aside ---
      var aside = document.createElement('aside');
      aside.className = 'page-toc';
      aside.setAttribute('aria-label', 'On this page');

      var eyebrow = document.createElement('h2');
      eyebrow.className = 'page-toc-eyebrow';
      eyebrow.textContent = 'On this page';
      aside.appendChild(eyebrow);

      var ul = document.createElement('ul');
      ul.setAttribute('role', 'navigation');
      ul.setAttribute('aria-label', 'Page sections');

      this._links = [];
      this._anchors.forEach(function (entry) {
        var li = document.createElement('li');
        var a = document.createElement('a');
        a.href = '#' + entry.id;
        a.textContent = entry.label;
        a.addEventListener('click', function (e) { self._handleLinkClick(e, entry.id); });
        li.appendChild(a);
        ul.appendChild(li);
        self._links.push(a);
      });

      aside.appendChild(ul);
      this.appendChild(aside);

      // --- Mobile trigger button ---
      var btn = document.createElement('button');
      btn.className = 'page-toc-mobile-trigger';
      btn.setAttribute('aria-expanded', 'false');
      btn.setAttribute('aria-controls', 'page-toc-drawer');
      btn.setAttribute('aria-haspopup', 'dialog');
      btn.textContent = 'On this page';
      btn.addEventListener('click', function () { self._openDrawer(); });
      this.appendChild(btn);
      this._triggerBtn = btn;

      // --- Mobile drawer ---
      var drawer = document.createElement('div');
      drawer.className = 'page-toc-drawer';
      drawer.id = 'page-toc-drawer';
      drawer.setAttribute('role', 'dialog');
      drawer.setAttribute('aria-modal', 'true');
      drawer.setAttribute('aria-label', 'On this page');

      var drawerHeader = document.createElement('div');
      drawerHeader.className = 'page-toc-drawer-header';

      var drawerEyebrow = document.createElement('h2');
      drawerEyebrow.className = 'page-toc-eyebrow';
      drawerEyebrow.textContent = 'On this page';

      var closeBtn = document.createElement('button');
      closeBtn.className = 'page-toc-drawer-close';
      closeBtn.setAttribute('aria-label', 'Close navigation');
      closeBtn.textContent = '×';
      closeBtn.addEventListener('click', function () { self._closeDrawer(); });

      drawerHeader.appendChild(drawerEyebrow);
      drawerHeader.appendChild(closeBtn);
      drawer.appendChild(drawerHeader);

      var drawerUl = document.createElement('ul');
      drawerUl.setAttribute('role', 'navigation');
      drawerUl.setAttribute('aria-label', 'Page sections');

      this._drawerLinks = [];
      this._anchors.forEach(function (entry) {
        var li = document.createElement('li');
        var a = document.createElement('a');
        a.href = '#' + entry.id;
        a.textContent = entry.label;
        a.addEventListener('click', function (e) {
          self._closeDrawer();
          self._handleLinkClick(e, entry.id);
        });
        li.appendChild(a);
        drawerUl.appendChild(li);
        self._drawerLinks.push(a);
      });
      drawer.appendChild(drawerUl);
      this.appendChild(drawer);
      this._drawer = drawer;

      // --- Overlay backdrop ---
      var overlay = document.createElement('div');
      overlay.className = 'page-toc-drawer-overlay';
      overlay.setAttribute('aria-hidden', 'true');
      overlay.addEventListener('click', function () { self._closeDrawer(); });
      this.appendChild(overlay);
      this._overlay = overlay;

      // Keyboard: Escape closes drawer
      this._onKeydown = function (e) {
        if (e.key === 'Escape' && self._drawer && self._drawer.hasAttribute('data-open')) {
          self._closeDrawer();
        }
      };
      document.addEventListener('keydown', this._onKeydown);
    }

    // -------------------------------------------------------
    // Live sticky offset — reads CURRENT rendered heights
    // -------------------------------------------------------

    _stickyOffset() {
      var navH = 0;
      var barH = 0;

      // header.site-nav — position: sticky (theme.css:400)
      var nav = document.querySelector('header.site-nav');
      if (nav) {
        navH = nav.getBoundingClientRect().height || 0;
      } else {
        navH = NAV_HEIGHT_FALLBACK;
      }

      // variant-action-bar — when [data-collapsed], .vab-card gets position: fixed
      // (variant-action-bar.css:53-54). Only count height when the card is actually
      // occupying screen space (fixed or sticky).
      var bar = document.querySelector('variant-action-bar');
      if (bar) {
        var card = bar.querySelector('.vab-card') || bar;
        var cs = getComputedStyle(card);
        if (cs.position === 'fixed' || cs.position === 'sticky') {
          barH = card.getBoundingClientRect().height || 0;
        }
      }

      return Math.round(navH + barH + 8);
    }

    // -------------------------------------------------------
    // Active-section highlight via scroll + rAF (no IntersectionObserver)
    // -------------------------------------------------------

    _setupScrollHighlight() {
      if (!this._sections.length) { return; }

      var self = this;
      this._boundOnScroll = function () { self._onScroll(); };

      window.addEventListener('scroll', this._boundOnScroll, { passive: true });
      window.addEventListener('resize', this._boundOnScroll, { passive: true });

      // Prime the highlight after initial render (one rAF so layout is settled).
      this._raf = requestAnimationFrame(function () {
        self._raf = null;
        self._updateActive();
      });
    }

    _onScroll() {
      if (this._raf !== null) { return; } // already a frame pending — skip
      var self = this;
      this._raf = requestAnimationFrame(function () {
        self._raf = null;
        self._updateActive();
      });
    }

    _updateActive() {
      if (!this._sections.length) { return; }

      // Probe line: just below the bottom edge of all sticky bands.
      var line = this._stickyOffset() + 4;

      // Last section whose top edge is at or above the probe line = active.
      var activeEl = null;
      for (var i = 0; i < this._sections.length; i++) {
        var top = this._sections[i].getBoundingClientRect().top;
        if (top <= line) {
          activeEl = this._sections[i];
        }
      }

      // Scrolled to bottom — force last anchor active (short final sections
      // may never cross the probe line on their own).
      // P2-codex-nit: use scrollingElement (respects html { overflow-x: clip }).
      var scrollEl = document.scrollingElement || document.documentElement;
      if (scrollEl.scrollTop + window.innerHeight >= scrollEl.scrollHeight - 2) {
        activeEl = this._sections[this._sections.length - 1];
      }

      // Nothing qualifies (above first section) — highlight first.
      if (!activeEl) {
        activeEl = this._sections[0];
      }

      if (activeEl.id !== this._activeId) {
        this._setActive(activeEl.id);
      }
    }

    _setActive(id) {
      this._activeId = id;
      var self = this;

      this._links.forEach(function (a) {
        if (a.getAttribute('href') === '#' + id) {
          a.setAttribute('data-active', '');
        } else {
          a.removeAttribute('data-active');
        }
      });

      this._drawerLinks.forEach(function (a) {
        if (a.getAttribute('href') === '#' + id) {
          a.setAttribute('data-active', '');
        } else {
          a.removeAttribute('data-active');
        }
      });
    }

    // -------------------------------------------------------
    // P2-1 helpers: user-scroll-intent abort listeners
    // -------------------------------------------------------

    _addReaimAbortListeners(onAbort) {
      // Keys that indicate the user is navigating with keyboard scroll intent.
      var SCROLL_KEYS = { PageUp: 1, PageDown: 1, ArrowUp: 1, ArrowDown: 1, Home: 1, End: 1, ' ': 1 };

      var wheelHandler = function () { onAbort(); };
      var touchHandler = function () { onAbort(); };
      var keyHandler   = function (e) { if (SCROLL_KEYS[e.key]) { onAbort(); } };

      window.addEventListener('wheel',      wheelHandler, { once: true, passive: true });
      window.addEventListener('touchstart', touchHandler, { once: true, passive: true });
      window.addEventListener('keydown',    keyHandler,   { once: true, passive: true });

      this._reaimAbortListeners = { wheel: wheelHandler, touch: touchHandler, key: keyHandler };
    }

    _removeReaimAbortListeners() {
      if (!this._reaimAbortListeners) { return; }
      var refs = this._reaimAbortListeners;
      window.removeEventListener('wheel',      refs.wheel);
      window.removeEventListener('touchstart', refs.touch);
      window.removeEventListener('keydown',    refs.key);
      this._reaimAbortListeners = null;
    }

    // -------------------------------------------------------
    // Smooth scroll on link click
    // -------------------------------------------------------

    _handleLinkClick(e, id) {
      e.preventDefault();
      var target = document.getElementById(id);
      if (!target) { return; }

      // Cancel any not-yet-fired click rAF from a prior click, then clear all
      // in-flight re-aim state before computing anything for this new click.
      if (this._clickRaf !== null) {
        cancelAnimationFrame(this._clickRaf);
        this._clickRaf = null;
      }
      if (this._reaimTimer !== null) {
        clearTimeout(this._reaimTimer);
        this._reaimTimer = null;
      }
      this._removeReaimAbortListeners();
      this._reaimAborted = false;

      // Monotonically-increasing click token — deferred callbacks check this to
      // detect whether a newer click superseded them.
      this._clickSeq = (this._clickSeq || 0) + 1;
      var mySeq = this._clickSeq;  // captured BEFORE scheduling the rAF

      // Auto-open any <details> at-or-ancestor of target so content is visible
      // before scroll (preserves PR #404 auto-expand behavior).
      var node = target;
      while (node) {
        if (node.tagName === 'DETAILS' && !node.open) {
          node.open = true;
        }
        node = node.parentElement;
      }

      var self = this;
      var prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

      // Defer measurement to AFTER <details> open reflow (one rAF).
      this._clickRaf = requestAnimationFrame(function () {
        self._clickRaf = null;

        // Bail before touching any state if a newer click superseded this one.
        if (self._clickSeq !== mySeq) { return; }

        var offset = self._stickyOffset();
        var y = window.scrollY + target.getBoundingClientRect().top - offset;
        // Always use 'auto' for reduced-motion (instant, no animation).
        window.scrollTo({ top: y, behavior: prefersReduced ? 'auto' : 'smooth' });

        // Install one-shot user-scroll-intent abort listeners.
        self._addReaimAbortListeners(function () {
          self._reaimAborted = true;
          self._removeReaimAbortListeners();
        });

        // Corrective re-aim: after ~420ms the action-bar collapses (height shrinks)
        // and the page has settled. Runs for BOTH motion modes:
        //   - smooth: corrects residual offset from smooth-scroll + bar collapse
        //   - reduced: instant initial scroll can still land under a newly-fixed bar
        // The ONLY difference under reduced-motion is behavior:'auto' (always).
        self._reaimTimer = setTimeout(function () {
          self._reaimTimer = null;
          self._removeReaimAbortListeners();

          // Abort if user scrolled/clicked elsewhere during the wait (defense in depth).
          if (self._reaimAborted || self._clickSeq !== mySeq) { return; }

          var offset2 = self._stickyOffset();
          var residual = target.getBoundingClientRect().top - offset2;
          if (Math.abs(residual) > 6) {
            window.scrollTo({ top: window.scrollY + residual, behavior: 'auto' });
          }
        }, 420);
      });

      this._setActive(id);
    }

    // -------------------------------------------------------
    // Mobile drawer
    // -------------------------------------------------------

    _openDrawer() {
      if (!this._drawer) { return; }
      this._drawer.setAttribute('data-open', '');
      this._overlay.setAttribute('data-open', '');
      this._triggerBtn.setAttribute('aria-expanded', 'true');
      document.body.style.overflow = 'hidden';

      // Move focus into the drawer (first interactive element).
      var firstLink = this._drawer.querySelector('a, button');
      if (firstLink) { firstLink.focus(); }
    }

    _closeDrawer() {
      if (!this._drawer) { return; }
      this._drawer.removeAttribute('data-open');
      this._overlay.removeAttribute('data-open');
      this._triggerBtn.setAttribute('aria-expanded', 'false');
      document.body.style.overflow = '';
      this._triggerBtn.focus();
    }

    // -------------------------------------------------------
    // Responsive: media query listener
    // -------------------------------------------------------

    _setupMobileQuery() {
      if (typeof window.matchMedia === 'undefined') { return; }

      var self = this;
      this._mql = window.matchMedia('(max-width: 1279px)');
      this._onMqlChange = function (e) {
        self._isMobile = e.matches;
        // Transition to desktop: close any open drawer.
        if (!e.matches && self._drawer && self._drawer.hasAttribute('data-open')) {
          self._closeDrawer();
        }
      };
      this._isMobile = this._mql.matches;
      this._mql.addEventListener('change', this._onMqlChange);
    }
  }

  if (!customElements.get('page-toc')) {
    customElements.define('page-toc', PageToc);
  }

}());
