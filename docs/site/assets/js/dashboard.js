  (function() {
    'use strict';

    // State (theme managed by shared theme.js)
    var currentRegistry = localStorage.getItem('preferredRegistry') || 'ghcr';
    var currentSearch = '';
    var currentStatus = 'all';

    // Announce status changes to screen readers (F-005: aria-live)
    function announceStatus(message) {
      var liveRegion = document.getElementById('status-live');
      if (liveRegion) {
        liveRegion.textContent = message;
      }
    }

    // Set global registry for all containers
    function setGlobalRegistry(registry, save) {
      if (save === undefined) save = true;
      currentRegistry = registry;
      if (save) {
        localStorage.setItem('preferredRegistry', registry);
      }

      // Update toggle buttons and ARIA state
      document.querySelectorAll('.registry-btn').forEach(function(btn) {
        var isActive = btn.dataset.registry === registry;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
      });

      // Update all container cards
      document.querySelectorAll('.container-card').forEach(function(card) {
        var pullSection = card.querySelector('.pull-section');
        if (pullSection) {
          var ghcrBase = pullSection.dataset.ghcrBase;
          var dockerhubBase = pullSection.dataset.dockerhubBase;
          var defaultTag = pullSection.dataset.defaultTag;
          var selectedVariant = card.querySelector('.variant-tag.selected');
          var tag = selectedVariant ? selectedVariant.dataset.tag : defaultTag;
          var baseUrl = registry === 'ghcr' ? ghcrBase : dockerhubBase;
          var imageUrl = baseUrl + ':' + tag;
          var containerName = card.dataset.container;
          var input = document.getElementById('pull-' + containerName);
          if (input) {
            input.value = 'docker pull ' + imageUrl;
          }
        }
      });

      if (save) {
        announceStatus('Registry switched to ' + (registry === 'ghcr' ? 'GitHub Container Registry' : 'Docker Hub'));
      }
    }

    // Filter containers by search query
    function filterContainers(query) {
      currentSearch = query.toLowerCase().trim();
      applyFilters();
    }

    // Filter containers by status
    function filterByStatus(status) {
      currentStatus = status;

      document.querySelectorAll('.filter-btn').forEach(function(btn) {
        var isActive = btn.dataset.status === status;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
      });

      applyFilters();
    }

    // Apply all filters
    function applyFilters() {
      var cards = document.querySelectorAll('.container-card');
      var visibleCount = 0;

      cards.forEach(function(card) {
        var name = card.dataset.container.toLowerCase();
        var statusColor = card.classList.contains('status-green') ? 'up-to-date' :
                         card.classList.contains('status-warning') ? 'update-available' :
                         'not-published';
        // F1: also match description text and variant tag names
        var descEl = card.querySelector('.card-description');
        var desc = descEl ? descEl.textContent.toLowerCase() : '';
        var variantTexts = Array.from(card.querySelectorAll('.variant-tag'))
          .map(function(t) { return t.dataset.tag ? t.dataset.tag.toLowerCase() : ''; })
          .join(' ');
        var searchable = name + ' ' + desc + ' ' + variantTexts;
        var matchesSearch = currentSearch === '' || searchable.includes(currentSearch);
        var matchesStatus = currentStatus === 'all' || statusColor === currentStatus;
        var isVisible = matchesSearch && matchesStatus;
        card.style.display = isVisible ? '' : 'none';
        if (isVisible) visibleCount++;
      });

      // Show/hide no results message
      var cardsGrid = document.querySelector('.cards-grid');
      if (!cardsGrid) return;
      var noResults = cardsGrid.querySelector('.no-results');

      if (visibleCount === 0) {
        if (!noResults) {
          noResults = document.createElement('div');
          noResults.className = 'no-results';
          var icon = document.createElement('i');
          icon.className = 'ti ti-search-off';
          var msg = document.createElement('p');
          msg.textContent = 'No containers match your filters';
          noResults.appendChild(icon);
          noResults.appendChild(msg);
          cardsGrid.appendChild(noResults);
        }
        noResults.style.display = '';
        announceStatus('No containers match your filters');
      } else {
        if (noResults) noResults.style.display = 'none';
        announceStatus(visibleCount + ' container' + (visibleCount !== 1 ? 's' : '') + ' shown');
      }
    }

    // Update filter button counts
    function updateFilterCounts() {
      var cards = document.querySelectorAll('.container-card');
      var counts = { 'all': cards.length, 'up-to-date': 0, 'update-available': 0, 'not-published': 0 };

      cards.forEach(function(card) {
        if (card.classList.contains('status-green')) {
          counts['up-to-date']++;
        } else if (card.classList.contains('status-warning')) {
          counts['update-available']++;
        } else {
          counts['not-published']++;
        }
      });

      Object.keys(counts).forEach(function(status) {
        var countEl = document.getElementById('count-' + status);
        if (countEl) countEl.textContent = counts[status];
      });
    }

    function isLargeImageSize(size) {
      var match = String(size || '').trim().match(/^([0-9]+(?:\.[0-9]+)?)\s*(MB|GB)$/i);
      if (!match) return false;

      var value = parseFloat(match[1]);
      var unit = match[2].toUpperCase();
      if (!Number.isFinite(value) || value <= 0) return false;

      return unit === 'GB' || (unit === 'MB' && value > 1024);
    }

    function setAmd64SizeMeta(element, size) {
      var displaySize = size || '—';
      element.textContent = displaySize;

      var isLarge = isLargeImageSize(displaySize);
      element.classList.toggle('image-size--large', isLarge);
      if (isLarge) {
        element.title = 'Large image (>1 GB)';
        element.setAttribute('aria-label', 'Image size ' + displaySize + '. Large image (>1 GB)');

        var sr = document.createElement('span');
        sr.className = 'sr-only';
        sr.textContent = ' Large image (>1 GB)';
        element.appendChild(sr);
      } else {
        element.removeAttribute('title');
        element.removeAttribute('aria-label');
      }
    }

    // Select a variant tag and update pull command + metadata
    function selectVariantTag(element) {
      var card = element.closest('.container-card');
      var tag = element.dataset.tag;

      var variantTags = card.querySelectorAll('.variant-tag');
      // The card's true default is the FIRST variant carrying the
      // default badge — multi-version cards (e.g. postgres) repeat the
      // badge on every version's base variant, so iterating every match
      // and overwriting would point at the last version's default
      // instead of the one the page initially selected.
      var defaultVariantEl = null;
      variantTags.forEach(function(t) {
        if (!defaultVariantEl && t.querySelector('.badge-primary, .badge[aria-hidden]')) {
          defaultVariantEl = t;
        }
        t.classList.remove('selected', 'is-reset-target');
        t.setAttribute('aria-pressed', 'false');
      });
      element.classList.add('selected');
      element.setAttribute('aria-pressed', 'true');
      // When a non-default variant is selected, surface the default pill
      // as a reset affordance (visual emphasis + tooltip swap).
      if (defaultVariantEl && defaultVariantEl !== element) {
        defaultVariantEl.classList.add('is-reset-target');
        if (!defaultVariantEl.dataset.origTitle) {
          defaultVariantEl.dataset.origTitle = defaultVariantEl.title || '';
        }
        defaultVariantEl.title = 'Reset to default variant';
      } else if (defaultVariantEl) {
        // default is now selected, restore title
        if (defaultVariantEl.dataset.origTitle !== undefined) {
          defaultVariantEl.title = defaultVariantEl.dataset.origTitle;
          delete defaultVariantEl.dataset.origTitle;
        }
      }

      var pullSection = card.querySelector('.pull-section');
      var ghcrBase = pullSection ? pullSection.dataset.ghcrBase : '';
      var dockerhubBase = pullSection ? pullSection.dataset.dockerhubBase : '';
      var baseUrl = currentRegistry === 'ghcr' ? ghcrBase : dockerhubBase;
      var imageUrl = baseUrl + ':' + tag;

      var containerName = card.dataset.container;
      var input = document.getElementById('pull-' + containerName);
      if (input) input.value = 'docker pull ' + imageUrl;

      var sizeAmd64El = card.querySelector('[data-meta="size-amd64"]');
      var sizeArm64El = card.querySelector('[data-meta="size-arm64"]');
      if (sizeAmd64El) setAmd64SizeMeta(sizeAmd64El, element.dataset.sizeAmd64 || '—');
      if (sizeArm64El) sizeArm64El.textContent = element.dataset.sizeArm64 || '—';

      // Phase B: dispatch event for vanilla custom-element trust strip + Security Scan section
      var variantData = {
        attestation_url: element.dataset.attestationUrl || '',
        attestation_id: element.dataset.attestationId || '',
        trivy_summary: null,
        multi_arch_platforms: []
      };
      try {
        if (element.dataset.trivySummary) variantData.trivy_summary = JSON.parse(element.dataset.trivySummary);
      } catch (e) { /* swallow */ }
      try {
        if (element.dataset.multiArchPlatforms) variantData.multi_arch_platforms = JSON.parse(element.dataset.multiArchPlatforms);
      } catch (e) { /* swallow */ }
      card.dispatchEvent(new CustomEvent('phase-b-variant-changed', { detail: variantData, bubbles: true }));

      announceStatus('Selected variant ' + tag);
    }



    // Copy text to clipboard with visual feedback
    function copyToClipboard(inputId, button) {
      var input = document.getElementById(inputId);
      if (!input) return;

      var iconElement = button.querySelector('i');

      function showCopied() {
        if (iconElement) iconElement.className = 'ti ti-check';
        button.classList.add('copied');
        announceStatus('Pull command copied to clipboard');
        setTimeout(function() {
          if (iconElement) iconElement.className = 'ti ti-copy';
          button.classList.remove('copied');
        }, 2000);
      }

      // Modern path: navigator.clipboard.writeText returns a Promise but
      // can also throw synchronously when clipboard is undefined (insecure
      // contexts, older browsers). Wrap to fall through to the legacy path.
      var clipboardPromise = null;
      try {
        if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
          clipboardPromise = navigator.clipboard.writeText(input.value);
        }
      } catch (e) {
        clipboardPromise = null;
      }

      function legacyCopy() {
        input.select();
        var ok = false;
        try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
        if (ok) {
          showCopied();
        } else {
          console.warn('[dashboard] clipboard copy failed (execCommand returned false)');
        }
      }

      if (clipboardPromise && typeof clipboardPromise.then === 'function') {
        clipboardPromise.then(showCopied).catch(function(e) {
          console.warn('[dashboard] navigator.clipboard.writeText failed; falling back', e);
          legacyCopy();
        });
      } else {
        legacyCopy();
      }
    }

    // Event delegation (F-006: no inline onclick handlers)
    document.addEventListener('DOMContentLoaded', function() {
      // Restore registry preference
      setGlobalRegistry(currentRegistry, false);

      // Auto-select text on click
      document.querySelectorAll('input[id^="pull-"]').forEach(function(input) {
        input.addEventListener('click', function() { this.select(); });
      });

      // Update filter counts
      updateFilterCounts();

      // Theme toggle (ThemeManager from theme.js + accessibility announcement)
      var themeBtn = document.querySelector('.theme-toggle');
      if (themeBtn) themeBtn.addEventListener('click', function() {
        ThemeManager.toggleTheme();
        announceStatus('Theme switched to ' + ThemeManager.currentTheme + ' mode');
      });

      // Registry buttons
      document.querySelectorAll('.registry-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
          setGlobalRegistry(this.dataset.registry);
        });
      });

      // Search input
      var searchInput = document.getElementById('search-input');
      if (searchInput) {
        searchInput.addEventListener('input', function() {
          filterContainers(this.value);
        });
      }

      // Filter buttons
      document.querySelectorAll('.filter-btn').forEach(function(btn) {
        btn.addEventListener('click', function() {
          filterByStatus(this.dataset.status);
        });
      });

      // Event delegation for variant tags and copy buttons (works for dynamic content)
      document.addEventListener('click', function(e) {
        var variantTag = e.target.closest('.variant-tag');
        if (variantTag && variantTag.closest('.container-card')) {
          selectVariantTag(variantTag);
          return;
        }

        var copyBtn = e.target.closest('.copy-btn');
        if (copyBtn) {
          var card = copyBtn.closest('.container-card');
          if (card) {
            copyToClipboard('pull-' + card.dataset.container, copyBtn);
          }
          return;
        }
      });

      // Keyboard support for variant tags (Enter/Space)
      document.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' || e.key === ' ') {
          var variantTag = e.target.closest('.variant-tag');
          if (variantTag && variantTag.closest('.container-card')) {
            e.preventDefault();
            selectVariantTag(variantTag);
          }
        }
      });
    });
  })();
