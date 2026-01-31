  (function() {
    'use strict';

    // State
    var currentRegistry = localStorage.getItem('preferredRegistry') || 'ghcr';
    var currentSearch = '';
    var currentStatus = 'all';
    var currentTheme = localStorage.getItem('preferredTheme') || 'dark';

    // Announce status changes to screen readers (F-005: aria-live)
    function announceStatus(message) {
      var liveRegion = document.getElementById('status-live');
      if (liveRegion) {
        liveRegion.textContent = message;
      }
    }

    // Theme management
    function initTheme() {
      var savedTheme = localStorage.getItem('preferredTheme');
      if (!savedTheme) {
        var prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        currentTheme = prefersDark ? 'dark' : 'light';
      } else {
        currentTheme = savedTheme;
      }
      applyTheme(currentTheme);
    }

    function applyTheme(theme) {
      document.documentElement.setAttribute('data-theme', theme);
      var icon = document.querySelector('.theme-toggle i');
      if (icon) {
        icon.className = theme === 'dark' ? 'ti ti-moon' : 'ti ti-sun';
      }
    }

    function toggleTheme() {
      currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
      localStorage.setItem('preferredTheme', currentTheme);
      applyTheme(currentTheme);
      announceStatus('Theme switched to ' + currentTheme + ' mode');
    }

    // Apply theme immediately to avoid flash
    initTheme();

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
        var matchesSearch = currentSearch === '' || name.includes(currentSearch);
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

    // Select a variant tag and update pull command + metadata
    function selectVariantTag(element) {
      var card = element.closest('.container-card');
      var tag = element.dataset.tag;

      card.querySelectorAll('.variant-tag').forEach(function(t) {
        t.classList.remove('selected');
        t.setAttribute('aria-pressed', 'false');
      });
      element.classList.add('selected');
      element.setAttribute('aria-pressed', 'true');

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
      if (sizeAmd64El) sizeAmd64El.textContent = element.dataset.sizeAmd64 || '—';
      if (sizeArm64El) sizeArm64El.textContent = element.dataset.sizeArm64 || '—';

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

      navigator.clipboard.writeText(input.value).then(showCopied).catch(function() {
        input.select();
        document.execCommand('copy');
        showCopied();
      });
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

      // Theme toggle
      var themeBtn = document.querySelector('.theme-toggle');
      if (themeBtn) themeBtn.addEventListener('click', toggleTheme);

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
