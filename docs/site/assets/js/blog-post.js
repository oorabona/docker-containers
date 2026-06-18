/* blog-post.js — reading enhancements for the blog article layout.
 *
 * Progressive enhancement: the article is fully readable without JS. This adds
 *   - an "On this page" table of contents (sticky on desktop, drawer on mobile)
 *     with position-based scroll-spy, built from kramdown auto-generated heading ids
 *   - hover anchors on headings (click copies the section's deep link)
 *   - a copy button on each code block
 *   - a reading-progress bar and a back-to-top button
 *
 * Loaded with `defer` from _layouts/post.html. CSP is `script-src 'self'`
 * (external file, no inline logic).
 */
(function () {
  'use strict';

  var content = document.querySelector('.post-content');
  if (!content) { return; }

  var MIN_HEADINGS = 3;
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  function scrollBehavior() { return reduceMotion.matches ? 'auto' : 'smooth'; }

  /* Keep the sticky TOC / scroll-spy aligned with the (sticky) site nav. */
  function navOffset() {
    var nav = document.querySelector('.site-nav');
    if (nav) {
      var cs = window.getComputedStyle(nav);
      if (cs.position === 'sticky' || cs.position === 'fixed') {
        return Math.round(nav.getBoundingClientRect().height) || 64;
      }
    }
    return 64;
  }
  var offset = navOffset();
  var spyOffset = offset + 24;
  document.documentElement.style.setProperty('--page-toc-nav-offset', offset + 'px');

  /* ---------- Table of contents ----------
     Only headings with a (kramdown auto-generated) id get a TOC entry and a hover
     anchor — a heading without a stable id has no link target, so it is skipped.
     `links` is a null-prototype map so a heading id like "hasOwnProperty" or
     "__proto__" cannot clobber lookups in the scroll handler. */
  var heads = [].slice.call(content.querySelectorAll('h2, h3')).filter(function (h) { return h.id; });
  var links = Object.create(null);

  if (heads.length >= MIN_HEADINGS) {
    var aside = document.getElementById('postToc');
    var layout = document.querySelector('.post-layout');
    if (aside && layout) {
      var title = document.createElement('p');
      title.className = 'post-toc-title';
      title.textContent = 'On this page';

      var toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.className = 'post-toc-toggle';
      toggle.setAttribute('aria-expanded', 'false');
      toggle.setAttribute('aria-controls', 'postTocNav');
      toggle.textContent = 'On this page';

      var nav = document.createElement('nav');
      nav.className = 'post-toc-nav';
      nav.id = 'postTocNav';

      heads.forEach(function (h) {
        var a = document.createElement('a');
        a.href = '#' + h.id;
        a.textContent = h.textContent;
        a.className = h.tagName === 'H3' ? 'lvl-3' : 'lvl-2';
        a.addEventListener('click', function () {
          aside.classList.remove('is-open');
          toggle.setAttribute('aria-expanded', 'false');
        });
        nav.appendChild(a);
        links[h.id] = a;
      });

      toggle.addEventListener('click', function () {
        var open = aside.classList.toggle('is-open');
        toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      });

      aside.appendChild(title);
      aside.appendChild(toggle);
      aside.appendChild(nav);
      aside.hidden = false;
      layout.classList.add('has-toc');
    }
  }

  /* ---------- Hover anchors on headings ---------- */
  heads.forEach(function (h) {
    var anchor = document.createElement('a');
    anchor.className = 'heading-anchor';
    anchor.href = '#' + h.id;
    anchor.textContent = '#';
    anchor.setAttribute('aria-label', 'Link to this section');
    anchor.addEventListener('click', function (e) {
      e.preventDefault();
      var url = location.href.split('#')[0] + '#' + h.id;
      if (navigator.clipboard) { navigator.clipboard.writeText(url).catch(function () {}); }
      history.replaceState(null, '', url);
      /* move focus to the target so keyboard/SR users land in the section */
      h.setAttribute('tabindex', '-1');
      h.focus({ preventScroll: true });
      h.scrollIntoView({ behavior: scrollBehavior() });
    });
    h.appendChild(anchor);
  });

  /* ---------- Copy buttons on code blocks ---------- */
  [].forEach.call(content.querySelectorAll('pre'), function (pre) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'code-copy';
    btn.textContent = 'Copy';

    function flag() {
      btn.textContent = 'Copied';
      btn.classList.add('is-copied');
      setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('is-copied'); }, 1600);
    }
    function fallbackCopy(text) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;top:-9999px;left:-9999px;opacity:0';
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      try { if (document.execCommand('copy')) { flag(); } } catch (err) { /* user can select manually */ }
      document.body.removeChild(ta);
    }

    btn.addEventListener('click', function () {
      var code = pre.querySelector('code') || pre;
      var text = code.textContent;
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(flag, function () { fallbackCopy(text); });
      } else {
        fallbackCopy(text);
      }
    });
    pre.appendChild(btn);
  });

  /* ---------- Scroll-spy (position based — at most one active) + progress + back-to-top ---------- */
  var progress = document.getElementById('readProgress');
  var toTop = document.getElementById('toTop');

  function onScroll() {
    var st = window.scrollY || document.documentElement.scrollTop;
    var h = document.documentElement.scrollHeight - window.innerHeight;
    if (progress) { progress.style.width = (h > 0 ? (st / h) * 100 : 0) + '%'; }
    if (toTop) { toTop.classList.toggle('is-visible', st > 600); }

    if (heads.length >= MIN_HEADINGS) {
      var current = null;
      heads.forEach(function (hd) { if (hd.getBoundingClientRect().top <= spyOffset) { current = hd; } });
      Object.keys(links).forEach(function (id) { links[id].classList.remove('is-active'); });
      if (current && links[current.id]) { links[current.id].classList.add('is-active'); }
    }
  }

  function onResize() {
    offset = navOffset();
    spyOffset = offset + 24;
    document.documentElement.style.setProperty('--page-toc-nav-offset', offset + 'px');
    onScroll();
  }

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onResize, { passive: true });
  onScroll();

  if (toTop) {
    toTop.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: scrollBehavior() }); });
  }
})();
