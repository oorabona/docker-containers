// code-copy.js — verify page: clipboard copy + Reference/Walkthrough tab toggle.
// Handles copy buttons (.code-block[data-copy]) and the view-switching tablist.
// Loaded as an external file; satisfies CSP script-src 'self'. No eval needed.
(function () {
  'use strict';

  // ----- Copy buttons -------------------------------------------------------

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-copy-button]');
    if (!btn) return;

    var wrap = btn.closest('.code-block');
    if (!wrap) return;

    // Primary: data-copy on the wrapper holds the pre-computed text.
    var text = wrap.getAttribute('data-copy');

    if (!text) {
      // Fallback: read <pre><code> text, stripping .prompt spans.
      var code = wrap.querySelector('pre code');
      if (code) {
        var clone = code.cloneNode(true);
        clone.querySelectorAll('.prompt').forEach(function (p) { p.remove(); });
        text = clone.textContent.trim();
      }
    }

    if (!text) return;

    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(
        function () { markCopied(btn); },
        function () { execCommandCopy(text, btn); }
      );
    } else {
      execCommandCopy(text, btn);
    }
  });

  function markCopied(btn) {
    // Guard re-entry: a click during the 1500ms timeout would capture
    // prevIcon='ti ti-check' and reset would leave button stuck in copied state.
    if (btn.classList.contains('is-copied')) return;

    var icon = btn.querySelector('i');
    var label = btn.querySelector('.copy-label');
    var prevIcon = icon ? icon.className : null;
    var prevLabel = label ? label.textContent : null;

    btn.classList.add('is-copied');
    btn.setAttribute('aria-label', 'Copied');
    if (icon) icon.className = 'ti ti-check';
    if (label) label.textContent = 'Copied';

    setTimeout(function () {
      btn.classList.remove('is-copied');
      btn.setAttribute('aria-label', 'Copy command');
      if (icon && prevIcon) icon.className = prevIcon;
      if (label && prevLabel) label.textContent = prevLabel;
    }, 1500);
  }

  function execCommandCopy(text, btn) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;top:-9999px;left:-9999px;opacity:0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    try {
      document.execCommand('copy');
      markCopied(btn);
    } catch (err) {
      // silent — user can select text manually
    }
    document.body.removeChild(ta);
  }

  // ----- Tab toggle (Reference / Walkthrough) --------------------------------

  var tabs = document.querySelectorAll('.verify-tabs button[role="tab"]');
  var panels = document.querySelectorAll('.verify-page [role="tabpanel"]');
  var layout = document.querySelector('.verify-layout');

  if (!tabs.length) return; // not on the verify page — stop here

  function applyView(view, push) {
    var v = (view === 'walkthrough') ? 'walkthrough' : 'reference';

    // Expose active view on the grid so CSS can hide the Reference-only TOC
    if (layout) layout.setAttribute('data-view', v);

    tabs.forEach(function (tab) {
      var active = tab.dataset.view === v;
      tab.setAttribute('aria-selected', active ? 'true' : 'false');
      tab.tabIndex = active ? 0 : -1;
    });

    panels.forEach(function (panel) {
      if (panel.dataset.view === v) {
        panel.removeAttribute('hidden');
      } else {
        panel.setAttribute('hidden', '');
      }
    });

    if (push) {
      var url = new URL(window.location.href);
      if (v === 'reference') {
        url.searchParams.delete('view');
      } else {
        url.searchParams.set('view', v);
      }
      history.pushState({ view: v }, '', url.toString());
    }
  }

  tabs.forEach(function (tab) {
    tab.addEventListener('click', function () { applyView(tab.dataset.view, true); });
  });

  // Keyboard nav: manual activation pattern (WAI-ARIA 1.2 §3.5 tablist, manual variant).
  // Arrow/Home/End ONLY move focus + update roving tabindex. They do NOT activate the
  // tab (no applyView, no pushState). Activation fires only via click or Enter/Space
  // (which natively trigger the click handler on the focused button element).
  function moveFocusToTab(target) {
    Array.from(tabs).forEach(function (t) {
      t.setAttribute('tabindex', t === target ? '0' : '-1');
    });
    target.focus();
  }

  tabs.forEach(function (tab, i) {
    tab.addEventListener('keydown', function (e) {
      var tabArr = Array.from(tabs);
      var n = tabArr.length;
      var next = null;
      switch (e.key) {
        case 'ArrowRight': next = tabArr[(i + 1) % n]; break;
        case 'ArrowLeft':  next = tabArr[(i - 1 + n) % n]; break;
        case 'Home':       next = tabArr[0]; break;
        case 'End':        next = tabArr[n - 1]; break;
        default: return; // let Enter/Space fall through to native click handler
      }
      e.preventDefault();
      moveFocusToTab(next);
    });
  });

  window.addEventListener('popstate', function (e) {
    var v = (e.state && e.state.view)
      ? e.state.view
      : new URLSearchParams(window.location.search).get('view') || 'reference';
    applyView(v, false);
  });

  // Apply correct initial view (and roving tabindex) on page load.
  // applyView() always sets tabindex=0 on the active tab and -1 on others,
  // correcting the no-JS fallback where both buttons have tabindex="0".
  var init = new URLSearchParams(window.location.search).get('view');
  applyView(init === 'walkthrough' ? 'walkthrough' : 'reference', false);
})();
