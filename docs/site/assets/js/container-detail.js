  (function() {
    'use strict';

    // Theme management
    var currentTheme = localStorage.getItem('preferredTheme') || 'dark';

    function applyTheme(theme) {
      document.documentElement.setAttribute('data-theme', theme);
      var icon = document.querySelector('.theme-toggle i');
      if (icon) icon.className = theme === 'dark' ? 'ti ti-moon' : 'ti ti-sun';
    }

    function initTheme() {
      var saved = localStorage.getItem('preferredTheme');
      if (!saved) {
        currentTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      }
      applyTheme(currentTheme);
    }

    initTheme();

    // Variant selection
    function selectVariant(el) {
      var section = el.closest('.variants-section');
      if (section) {
        section.querySelectorAll('.variant-tag').forEach(function(t) {
          t.classList.remove('selected');
          t.setAttribute('aria-pressed', 'false');
        });
      }
      el.classList.add('selected');
      el.setAttribute('aria-pressed', 'true');

      var tag = el.dataset.tag || '';
      var sizeAmd64 = el.dataset.sizeAmd64 || '---';
      var sizeArm64 = el.dataset.sizeArm64 || '---';

      var tagEl = document.querySelector('[data-meta="current-tag"]');
      var amdEl = document.querySelector('[data-meta="size-amd64"]');
      var armEl = document.querySelector('[data-meta="size-arm64"]');

      if (tagEl) tagEl.textContent = tag;
      if (amdEl) amdEl.textContent = sizeAmd64;
      if (armEl) armEl.textContent = sizeArm64;

      // Update lineage build_digest and base_image
      var buildDigest = el.dataset.buildDigest || '';
      var baseImage = el.dataset.baseImage || '';
      var digestEl = document.querySelector('[data-lineage="build-digest"] .lineage-value');
      var baseImgEl = document.querySelector('[data-lineage="base-image"] .lineage-value');
      if (digestEl) digestEl.textContent = (buildDigest && buildDigest !== 'unknown') ? buildDigest : '---';
      if (baseImgEl) baseImgEl.textContent = (baseImage && baseImage !== 'unknown') ? baseImage : '---';

      // Update lineage build_args for selected variant (empty array clears them)
      var buildArgsAttr = el.dataset.buildArgs;
      updateLineageBuildArgs(buildArgsAttr ? JSON.parse(buildArgsAttr) : []);
    }

    // Create a lineage item DOM element safely (no innerHTML)
    function createLineageItem(name, value, index) {
      var item = document.createElement('div');
      item.className = 'lineage-item';
      item.setAttribute('data-build-arg', name);
      item.style.animationDelay = (index * 0.06) + 's';

      var label = document.createElement('span');
      label.className = 'lineage-label';
      label.textContent = name;

      var val = document.createElement('span');
      val.className = 'lineage-value';
      val.textContent = value;

      item.appendChild(label);
      item.appendChild(val);
      return item;
    }

    // Animate lineage build_args swap
    function updateLineageBuildArgs(args) {
      var grid = document.querySelector('.lineage-grid');
      if (!grid) return;

      // Find existing build_arg items (not digest/base_image)
      var existingArgs = grid.querySelectorAll('.lineage-item[data-build-arg]');

      // Exit animation on old items
      existingArgs.forEach(function(item) { item.classList.add('lineage-exit'); });

      // After exit animation, replace with new items
      setTimeout(function() {
        existingArgs.forEach(function(item) { item.remove(); });
        args.forEach(function(arg, i) {
          grid.appendChild(createLineageItem(arg.name, arg.value, i));
        });
      }, 250);
    }

    // Event delegation
    document.addEventListener('click', function(e) {
      var tag = e.target.closest('.variant-tag');
      if (tag) selectVariant(tag);

      if (e.target.closest('.theme-toggle')) {
        currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
        localStorage.setItem('preferredTheme', currentTheme);
        applyTheme(currentTheme);
      }
    });

    document.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' || e.key === ' ') {
        var tag = e.target.closest('.variant-tag');
        if (tag) { e.preventDefault(); selectVariant(tag); }
      }
    });

    // Auto-select default variant on page load so lineage shows
    // the default variant's digest instead of "per-variant"
    var defaultVariant = document.querySelector('.variant-tag.selected');
    if (defaultVariant) selectVariant(defaultVariant);
  })();
