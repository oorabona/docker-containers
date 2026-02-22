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
      var buildArgs = buildArgsAttr ? JSON.parse(buildArgsAttr) : [];
      updateLineageBuildArgs(buildArgs);

      // Update dep health section for selected variant
      var argNames = buildArgs.map(function(a) { return a.name; });
      updateDepHealth(argNames);

      // Update SBOM sections for selected variant
      updateSbomSection(el);
      updateChangelogSection(el);
      updateHistorySection(el);
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

    // --- Dependency Health: variant-aware filtering ---

    // Get the dep health section's embedded data (parsed once, cached)
    var _depCache = null;
    function getDepData() {
      if (_depCache) return _depCache;
      var section = document.querySelector('.dep-health-section');
      if (!section) return null;
      try {
        _depCache = {
          section: section,
          updates: JSON.parse(section.dataset.depUpdates || '[]'),
          allDeps: JSON.parse(section.dataset.depAll || '[]')
        };
      } catch (e) {
        _depCache = null;
      }
      return _depCache;
    }

    // Filter dep health section to show only deps relevant to the selected variant
    function updateDepHealth(variantArgNames) {
      var data = getDepData();
      if (!data) return;

      // Build a Set of arg names for this variant
      var argSet = {};
      variantArgNames.forEach(function(n) { argSet[n] = true; });

      // Filter deps: monitored deps whose name is in variant's build_args,
      // plus disabled deps whose name is in variant's build_args
      var relevantDeps = data.allDeps.filter(function(d) { return argSet[d.name]; });
      var relevantMonitored = relevantDeps.filter(function(d) { return d.status === 'monitored'; });
      var relevantUpdates = data.updates.filter(function(u) { return argSet[u.name]; });

      // Update summary badge
      var badge = data.section.querySelector('.dep-summary-badge');
      if (badge) {
        if (relevantUpdates.length > 0) {
          badge.className = 'dep-summary-badge dep-badge-warning';
          badge.textContent = relevantUpdates.length + ' update' + (relevantUpdates.length !== 1 ? 's' : '') + ' available';
        } else if (data.updates.length > 0 || relevantMonitored.length > 0) {
          // We have update data and this variant has no updates
          badge.className = 'dep-summary-badge dep-badge-ok';
          badge.textContent = 'all up to date';
        } else {
          badge.className = 'dep-summary-badge dep-badge-neutral';
          badge.textContent = relevantMonitored.length + ' monitored';
        }
      }

      // Update progress bar (green = monitored, amber = unmonitored)
      var barLabel = data.section.querySelector('.dep-bar-label');
      var barFill = data.section.querySelector('.dep-bar-fill');
      var barUnmon = data.section.querySelector('.dep-bar-unmonitored');
      var total = relevantDeps.length;
      var monitored = relevantMonitored.length;
      var unmonitored = total - monitored;
      if (barLabel) barLabel.textContent = monitored + '/' + total + ' dependencies monitored';
      if (barFill) barFill.style.flex = (total > 0 ? monitored : 0);
      if (barUnmon) {
        barUnmon.style.flex = unmonitored;
        barUnmon.style.display = unmonitored > 0 ? '' : 'none';
      } else if (unmonitored > 0 && barFill && barFill.parentNode) {
        // Create amber segment if it doesn't exist yet
        var seg = document.createElement('div');
        seg.className = 'dep-bar-unmonitored';
        seg.style.flex = unmonitored;
        barFill.parentNode.appendChild(seg);
      }

      // Filter update table rows
      var tableWrap = data.section.querySelector('.dep-update-table-wrap');
      if (tableWrap) {
        var rows = tableWrap.querySelectorAll('.dep-update-row');
        var visibleCount = 0;
        rows.forEach(function(row) {
          var visible = !!argSet[row.dataset.depName];
          row.style.display = visible ? '' : 'none';
          if (visible) visibleCount++;
        });
        tableWrap.style.display = visibleCount > 0 ? '' : 'none';
      }

      // Filter up-to-date items
      var uptodateDetails = data.section.querySelector('.dep-uptodate-details');
      if (uptodateDetails) {
        var items = uptodateDetails.querySelectorAll('.dep-uptodate-item');
        var uptodateVisible = 0;
        items.forEach(function(item) {
          var name = item.dataset.depName;
          // Visible if in this variant's args AND not in the updates list AND monitored
          var inVariant = !!argSet[name];
          var hasUpdate = relevantUpdates.some(function(u) { return u.name === name; });
          var visible = inVariant && !hasUpdate;
          item.style.display = visible ? '' : 'none';
          if (visible) uptodateVisible++;
        });
        uptodateDetails.style.display = uptodateVisible > 0 ? '' : 'none';
      }

      // Filter disabled/unmonitored items
      var disabledList = data.section.querySelector('.dep-disabled-list');
      if (disabledList) {
        var disabledItems = disabledList.querySelectorAll('.dep-disabled-item');
        var disabledVisible = 0;
        disabledItems.forEach(function(item) {
          var visible = !!argSet[item.dataset.depName];
          item.style.display = visible ? '' : 'none';
          if (visible) disabledVisible++;
        });
        disabledList.style.display = disabledVisible > 0 ? '' : 'none';
      }
    }

    // Count outdated deps for a variant button element
    function countVariantUpdates(variantEl) {
      var data = getDepData();
      if (!data || data.updates.length === 0) return 0;

      var buildArgsAttr = variantEl.dataset.buildArgs;
      if (!buildArgsAttr) return 0;

      var argNames = {};
      try {
        JSON.parse(buildArgsAttr).forEach(function(a) { argNames[a.name] = true; });
      } catch (e) { return 0; }

      return data.updates.filter(function(u) { return argNames[u.name]; }).length;
    }

    // Add notification badges to variant buttons showing outdated dep count
    function initDepBadges() {
      var data = getDepData();
      if (!data || data.updates.length === 0) return;

      document.querySelectorAll('.variant-tag').forEach(function(tag) {
        var count = countVariantUpdates(tag);
        if (count > 0) {
          var badge = document.createElement('span');
          badge.className = 'variant-dep-badge';
          badge.textContent = count;
          badge.setAttribute('aria-label', count + ' dependency update' + (count !== 1 ? 's' : '') + ' available');
          tag.appendChild(badge);
          tag.classList.add('has-dep-updates');
        }
      });
    }

    // --- SBOM section rendering ---

    function updateSbomSection(variantEl) {
      var section = document.getElementById('sbom-section');
      if (!section) return;

      var attr = variantEl.dataset.sbomSummary;
      if (!attr) { section.style.display = 'none'; return; }

      var summary;
      try { summary = JSON.parse(attr); } catch(e) { section.style.display = 'none'; return; }
      if (!summary.total || summary.total === 0) { section.style.display = 'none'; return; }

      section.style.display = '';
      var badge = document.getElementById('sbom-total-badge');
      if (badge) badge.textContent = summary.total + ' packages';

      var breakdown = document.getElementById('sbom-breakdown');
      if (breakdown) {
        breakdown.textContent = '';
        Object.keys(summary).forEach(function(key) {
          if (key === 'total') return;
          var chip = document.createElement('span');
          chip.className = 'sbom-type-chip';
          chip.textContent = key + ' ';
          var count = document.createElement('span');
          count.className = 'sbom-type-count';
          count.textContent = summary[key];
          chip.appendChild(count);
          breakdown.appendChild(chip);
        });
      }
    }

    function updateChangelogSection(variantEl) {
      var section = document.getElementById('changelog-section');
      if (!section) return;

      var attr = variantEl.dataset.changelog;
      if (!attr) { section.style.display = 'none'; return; }

      var changelog;
      try { changelog = JSON.parse(attr); } catch(e) { section.style.display = 'none'; return; }
      if (!changelog.changes || changelog.changes.length === 0) { section.style.display = 'none'; return; }

      section.style.display = '';
      var badge = document.getElementById('changelog-summary-badge');
      if (badge && changelog.summary) {
        badge.textContent = '+' + (changelog.summary.added || 0) +
          ' -' + (changelog.summary.removed || 0) +
          ' ~' + (changelog.summary.updated || 0);
      }

      var wrap = document.getElementById('changelog-table-wrap');
      if (wrap) {
        wrap.textContent = '';
        var table = document.createElement('table');
        table.className = 'changelog-table';

        var thead = document.createElement('thead');
        var headerRow = document.createElement('tr');
        ['Type', 'Package', 'Previous', 'Current'].forEach(function(h) {
          var th = document.createElement('th');
          th.textContent = h;
          headerRow.appendChild(th);
        });
        thead.appendChild(headerRow);
        table.appendChild(thead);

        var tbody = document.createElement('tbody');
        changelog.changes.slice(0, 50).forEach(function(change, i) {
          var tr = document.createElement('tr');
          tr.style.animationDelay = (i * 0.04) + 's';

          var tdType = document.createElement('td');
          var typeBadge = document.createElement('span');
          typeBadge.className = 'changelog-type-badge changelog-type-' + change.type;
          typeBadge.textContent = change.type;
          tdType.appendChild(typeBadge);
          tr.appendChild(tdType);

          var tdName = document.createElement('td');
          tdName.className = 'changelog-pkg-name';
          tdName.textContent = change.name;
          tr.appendChild(tdName);

          var tdFrom = document.createElement('td');
          tdFrom.className = 'changelog-version';
          tdFrom.textContent = change.from || change.version || '---';
          tr.appendChild(tdFrom);

          var tdTo = document.createElement('td');
          tdTo.className = 'changelog-version changelog-version-new';
          tdTo.textContent = change.to || (change.type === 'added' ? change.version : '---');
          tr.appendChild(tdTo);

          tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        wrap.appendChild(table);
      }
    }

    function updateHistorySection(variantEl) {
      var section = document.getElementById('history-section');
      if (!section) return;

      var attr = variantEl.dataset.buildHistory;
      if (!attr) { section.style.display = 'none'; return; }

      var history;
      try { history = JSON.parse(attr); } catch(e) { section.style.display = 'none'; return; }
      if (!history || history.length === 0) { section.style.display = 'none'; return; }

      section.style.display = '';
      var wrap = document.getElementById('history-table-wrap');
      if (wrap) {
        wrap.textContent = '';
        var table = document.createElement('table');
        table.className = 'history-table';

        var thead = document.createElement('thead');
        var headerRow = document.createElement('tr');
        ['Date', 'Version', 'Packages', 'Changes'].forEach(function(h) {
          var th = document.createElement('th');
          th.textContent = h;
          headerRow.appendChild(th);
        });
        thead.appendChild(headerRow);
        table.appendChild(thead);

        var tbody = document.createElement('tbody');
        history.forEach(function(build, i) {
          var tr = document.createElement('tr');
          tr.style.animationDelay = (i * 0.04) + 's';

          var tdDate = document.createElement('td');
          tdDate.className = 'history-date';
          var d = new Date(build.built_at);
          tdDate.textContent = isNaN(d.getTime()) ? build.built_at : d.toISOString().slice(0, 10);
          tr.appendChild(tdDate);

          var tdVer = document.createElement('td');
          tdVer.className = 'history-version';
          tdVer.textContent = build.version || '---';
          tr.appendChild(tdVer);

          var tdPkgs = document.createElement('td');
          tdPkgs.textContent = build.packages_total || '---';
          tr.appendChild(tdPkgs);

          var tdChanges = document.createElement('td');
          tdChanges.className = 'history-changes';
          tdChanges.textContent = build.changes_summary || '---';
          tr.appendChild(tdChanges);

          tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        wrap.appendChild(table);
      }
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

    // Initialize: dep badges on variant buttons, then auto-select default variant
    initDepBadges();
    var defaultVariant = document.querySelector('.variant-tag.selected');
    if (defaultVariant) {
      selectVariant(defaultVariant);
    } else {
      // Non-variant containers: read SBOM data from hidden carrier element
      var carrier = document.getElementById('sbom-data-carrier');
      if (carrier) {
        updateSbomSection(carrier);
        updateChangelogSection(carrier);
        updateHistorySection(carrier);
      }
    }
  })();
