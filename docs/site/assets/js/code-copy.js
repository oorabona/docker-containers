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

  // Left/Right arrow keys navigate the tablist (ARIA 1.2 composite widget pattern)
  tabs.forEach(function (tab, i) {
    tab.addEventListener('keydown', function (e) {
      var n = tabs.length;
      var next = -1;
      if (e.key === 'ArrowRight') next = (i + 1) % n;
      else if (e.key === 'ArrowLeft') next = (i - 1 + n) % n;
      if (next !== -1) {
        tabs[next].focus();
        applyView(tabs[next].dataset.view, true);
        e.preventDefault();
      }
    });
  });

  window.addEventListener('popstate', function (e) {
    var v = (e.state && e.state.view)
      ? e.state.view
      : new URLSearchParams(window.location.search).get('view') || 'reference';
    applyView(v, false);
  });

  var init = new URLSearchParams(window.location.search).get('view');
  if (init === 'walkthrough') applyView('walkthrough', false);
})();
