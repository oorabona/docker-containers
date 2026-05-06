// docs/site/assets/js/components/page-toc.js
//
// Vanilla custom element (light DOM). CSP-clean (no eval, no innerHTML).
// Renders a sticky right-side TOC sidebar on desktop (>=1280px) and a
// floating drawer-button on mobile (<1280px).
// Active section tracking via IntersectionObserver.
// Smooth-scroll with prefers-reduced-motion support.

(function () {
  'use strict';

  // Approximate sticky nav height (px). Used as scroll offset.
  // Measured from .site-nav padding 0.85rem*2 + ~38px line-height ~ 64px total.
  var NAV_HEIGHT = 64;

  // Debounce helper for resize events.
  function debounce(fn, ms) {
    var t;
    return function () {
      clearTimeout(t);
      t = setTimeout(fn, ms);
    };
  }

  class PageToc extends HTMLElement {

    // -------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------

    connectedCallback() {
      this._anchors = [];      // [{id, label}] filtered to sections present in DOM
      this._sections = [];     // [Element] — observed section elements
      this._links = [];        // [<a>] — TOC anchor elements (desktop)
      this._drawerLinks = [];  // [<a>] — TOC anchor elements (mobile drawer)
      this._observer = null;
      this._activeId = null;
      this._isMobile = false;
      this._triggerBtn = null;
      this._drawer = null;
      this._overlay = null;
      this._mql = null;
      this._onMqlChange = null;
      this._onKeydown = null;

      this._parseAnchors();
      this._render();
      this._setupObserver();
      this._setupMobileQuery();
    }

    disconnectedCallback() {
      if (this._observer) {
        this._observer.disconnect();
        this._observer = null;
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
    // IntersectionObserver — active section tracking
    // -------------------------------------------------------

    _setupObserver() {
      if (!this._sections.length || typeof IntersectionObserver === 'undefined') { return; }

      var self = this;
      var intersections = {};

      this._observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          intersections[entry.target.id] = entry.intersectionRatio;
        });

        // Section with highest intersection ratio = active.
        var bestId = null;
        var bestRatio = 0;
        self._sections.forEach(function (el) {
          var ratio = intersections[el.id] || 0;
          if (ratio > bestRatio) {
            bestRatio = ratio;
            bestId = el.id;
          }
        });

        // If nothing meaningfully visible, keep previous active.
        if (bestRatio < 0.05 && self._activeId) { return; }
        if (bestId && bestId !== self._activeId) {
          self._setActive(bestId);
        }
      }, {
        rootMargin: '-' + self._computeOffset() + 'px 0px 0px 0px',
        threshold: [0, 0.1, 0.5, 1.0]
      });

      this._sections.forEach(function (el) {
        self._observer.observe(el);
      });
    }

    _computeOffset() {
      // Sticky nav + variant-action-bar (when collapsed/sticky).
      var bar = document.querySelector('variant-action-bar');
      var barH = 0;
      if (bar) {
        barH = bar.getBoundingClientRect().height || 0;
      }
      return Math.round(NAV_HEIGHT + barH + 8);
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
    // Smooth scroll on link click
    // -------------------------------------------------------

    _handleLinkClick(e, id) {
      e.preventDefault();
      var target = document.getElementById(id);
      if (!target) { return; }

      var offset = this._computeOffset();
      var top = target.getBoundingClientRect().top + window.scrollY - offset;

      var prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      window.scrollTo({ top: top, behavior: prefersReduced ? 'auto' : 'smooth' });

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
