  (function() {
    'use strict';

    // Theme managed by shared theme.js (window.ThemeManager namespace)

    // Registry management for pull command
    var currentRegistry = localStorage.getItem('preferredRegistry') || 'ghcr';

    function updatePullCommand(tag) {
      var pullSection = document.getElementById('detail-pull');
      var input = document.getElementById('detail-pull-cmd');
      if (!pullSection || !input) return;

      var base = currentRegistry === 'ghcr'
        ? pullSection.dataset.ghcrBase
        : pullSection.dataset.dockerhubBase;
      var effectiveTag = tag || pullSection.dataset.defaultTag;
      input.value = 'docker pull ' + base + ':' + effectiveTag;
    }

    function setDetailRegistry(registry) {
      currentRegistry = registry;
      localStorage.setItem('preferredRegistry', registry);

      document.querySelectorAll('.detail-registry-btn').forEach(function(btn) {
        var isActive = btn.dataset.registry === registry;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-checked', isActive ? 'true' : 'false');
      });

      // Get current variant tag
      var selected = document.querySelector('.variant-tag.selected');
      var tag = selected ? selected.dataset.tag : null;
      updatePullCommand(tag);
    }

    function copyDetailPullCommand() {
      var input = document.getElementById('detail-pull-cmd');
      var button = document.getElementById('detail-copy-btn');
      if (!input || !button) return;

      var icon = button.querySelector('i');

      function showCopied() {
        if (icon) icon.className = 'ti ti-check';
        button.classList.add('copied');
        setTimeout(function() {
          if (icon) icon.className = 'ti ti-copy';
          button.classList.remove('copied');
        }, 2000);
      }

      navigator.clipboard.writeText(input.value).then(showCopied).catch(function() {
        input.select();
        document.execCommand('copy');
        showCopied();
      });
    }

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

      // Update pull command with selected variant tag
      updatePullCommand(tag);

      // Phase B: dispatch event for vanilla custom-element trust strip + Security Scan section
      var variantData = {
        attestation_url: el.dataset.attestationUrl || '',
        trivy_summary: null,
        multi_arch_platforms: []
      };
      try {
        if (el.dataset.trivySummary) variantData.trivy_summary = JSON.parse(el.dataset.trivySummary);
      } catch (e) { /* swallow */ }
      try {
        if (el.dataset.multiArchPlatforms) variantData.multi_arch_platforms = JSON.parse(el.dataset.multiArchPlatforms);
      } catch (e) { /* swallow */ }
      document.dispatchEvent(new CustomEvent('phase-b-variant-changed', { detail: variantData }));

      // Phase B: postgres variants comparison table follows selected variant's version.
      // Guard on DOM presence — only postgres detail page renders .variants-table-section.
      var variantsSection = document.querySelector('.variants-table-section');
      if (variantsSection) {
        // Variant tag format: "18-vector", "18.2-alpine", "17-base", etc.
        // Extract leading major version digits (terminated by '.', '-', or end-of-string).
        var versionMatch = tag.match(/^(\d+)(?:[.-]|$)/);
        var versionMajor = versionMatch ? versionMatch[1] : null;
        if (versionMajor) {
          var tables = variantsSection.querySelectorAll('.variants-table[data-version]');
          var activeLabel = document.querySelector('[data-field="active-version"]');
          tables.forEach(function(t) {
            // data-version is e.g. "18" or "17" — match by leading digits.
            var tableVerMatch = (t.dataset.version || '').match(/^(\d+)/);
            var tableMajor = tableVerMatch ? tableVerMatch[1] : '';
            var isActive = tableMajor === versionMajor;
            if (isActive) {
              t.setAttribute('data-active', 'true');
              if (activeLabel) activeLabel.textContent = t.dataset.version;
            } else {
              t.removeAttribute('data-active');
            }
          });
        }
      }
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

    // Current SBOM packages data (set when variant is selected)
    var currentSbomPackages = null;

    // Type labels for display
    var sbomTypeLabels = {
      apk: 'Alpine packages',
      golang: 'Go binaries',
      generic: 'Standalone binaries',
      oci: 'Container image',
      pip: 'Python packages',
      npm: 'Node.js packages',
      other: 'Other'
    };

    function updateSbomSection(variantEl) {
      var section = document.getElementById('sbom-section');
      if (!section) return;

      var attr = variantEl.dataset.sbomSummary;
      if (!attr) { section.style.display = 'none'; return; }

      var summary;
      try { summary = JSON.parse(attr); } catch(e) { section.style.display = 'none'; return; }
      if (!summary.total || summary.total === 0) { section.style.display = 'none'; return; }

      // Parse packages data
      currentSbomPackages = null;
      var pkgAttr = variantEl.dataset.sbomPackages;
      if (pkgAttr) {
        try { currentSbomPackages = JSON.parse(pkgAttr); } catch(e) { /* ignore */ }
      }

      section.style.display = '';
      var badge = document.getElementById('sbom-total-badge');
      if (badge) badge.textContent = summary.total + ' packages';

      var breakdown = document.getElementById('sbom-breakdown');
      var panel = document.getElementById('sbom-package-panel');
      if (panel) { panel.style.display = 'none'; panel.textContent = ''; }

      if (breakdown) {
        breakdown.textContent = '';
        Object.keys(summary).forEach(function(key) {
          if (key === 'total') return;
          var chip = document.createElement('span');
          chip.className = 'sbom-type-chip';
          if (currentSbomPackages && currentSbomPackages[key]) {
            chip.className += ' sbom-type-chip-clickable';
            chip.setAttribute('role', 'button');
            chip.setAttribute('tabindex', '0');
            chip.setAttribute('aria-expanded', 'false');
            chip.title = 'Click to show ' + (sbomTypeLabels[key] || key) + ' details';
          }
          chip.dataset.type = key;
          chip.textContent = key + ' ';
          var count = document.createElement('span');
          count.className = 'sbom-type-count';
          count.textContent = summary[key];
          chip.appendChild(count);
          breakdown.appendChild(chip);
        });
      }
    }

    function togglePackagePanel(type) {
      var panel = document.getElementById('sbom-package-panel');
      if (!panel || !currentSbomPackages || !currentSbomPackages[type]) return;

      // If already showing this type, collapse
      if (panel.style.display !== 'none' && panel.dataset.activeType === type) {
        panel.style.display = 'none';
        panel.dataset.activeType = '';
        // Update chip aria
        var chips = document.querySelectorAll('.sbom-type-chip-clickable');
        chips.forEach(function(c) { c.setAttribute('aria-expanded', 'false'); c.classList.remove('sbom-type-chip-active'); });
        return;
      }

      var packages = currentSbomPackages[type];
      panel.textContent = '';
      panel.dataset.activeType = type;

      // Header
      var header = document.createElement('div');
      header.className = 'sbom-panel-header';
      var title = document.createElement('span');
      title.className = 'sbom-panel-title';
      title.textContent = (sbomTypeLabels[type] || type) + ' (' + packages.length + ')';
      header.appendChild(title);
      var closeBtn = document.createElement('button');
      closeBtn.className = 'sbom-panel-close';
      closeBtn.textContent = '\u00D7';
      closeBtn.title = 'Close';
      closeBtn.setAttribute('aria-label', 'Close package list');
      closeBtn.onclick = function() { togglePackagePanel(type); };
      header.appendChild(closeBtn);
      panel.appendChild(header);

      // Package grid
      var grid = document.createElement('div');
      grid.className = 'sbom-package-grid';
      packages.forEach(function(pkg) {
        var item = document.createElement('div');
        item.className = 'sbom-package-item';
        var name = document.createElement('span');
        name.className = 'sbom-pkg-name';
        name.textContent = pkg.n;
        name.title = pkg.n;
        item.appendChild(name);
        var ver = document.createElement('span');
        ver.className = 'sbom-pkg-version';
        ver.textContent = pkg.v;
        ver.title = pkg.v;
        item.appendChild(ver);
        grid.appendChild(item);
      });
      panel.appendChild(grid);

      panel.style.display = '';

      // Update chip states
      var chips = document.querySelectorAll('.sbom-type-chip-clickable');
      chips.forEach(function(c) {
        var isActive = c.dataset.type === type;
        c.setAttribute('aria-expanded', isActive ? 'true' : 'false');
        if (isActive) c.classList.add('sbom-type-chip-active');
        else c.classList.remove('sbom-type-chip-active');
      });
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

    var _historyChart = null;

    function formatDuration(seconds) {
      if (seconds == null) return '---';
      if (seconds < 60) return seconds + 's';
      var m = Math.floor(seconds / 60);
      var s = seconds % 60;
      return m + 'm' + (s > 0 ? s + 's' : '');
    }

    function renderHistoryChart(history) {
      var chartWrap = document.getElementById('history-chart-wrap');
      var canvas = document.getElementById('history-trend-chart');
      if (!chartWrap || !canvas || typeof Chart === 'undefined') return;
      if (history.length < 2) { chartWrap.style.display = 'none'; return; }

      // Destroy previous chart instance
      if (_historyChart) { _historyChart.destroy(); _historyChart = null; }

      // Reverse for chronological order (oldest first)
      var sorted = history.slice().reverse();
      var labels = sorted.map(function(b) {
        var d = new Date(b.built_at);
        return isNaN(d.getTime()) ? '?' : d.toISOString().slice(5, 10);
      });
      var pkgData = sorted.map(function(b) { return b.packages_total || null; });
      var durData = sorted.map(function(b) { return b.duration_seconds || null; });
      var hasDuration = durData.some(function(v) { return v !== null; });

      var isDark = document.documentElement.getAttribute('data-theme') !== 'light';
      var gridColor = isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.06)';
      var textColor = isDark ? 'rgba(255,255,255,0.5)' : 'rgba(0,0,0,0.5)';

      var datasets = [{
        label: 'Packages',
        data: pkgData,
        borderColor: '#6366f1',
        backgroundColor: 'rgba(99,102,241,0.1)',
        fill: true,
        tension: 0.3,
        yAxisID: 'y',
        pointRadius: 3,
        pointHoverRadius: 5
      }];

      if (hasDuration) {
        datasets.push({
          label: 'Build (min)',
          data: durData.map(function(v) { return v != null ? +(v / 60).toFixed(1) : null; }),
          borderColor: '#f59e0b',
          backgroundColor: 'rgba(245,158,11,0.1)',
          fill: false,
          tension: 0.3,
          yAxisID: 'y1',
          pointRadius: 3,
          pointHoverRadius: 5,
          borderDash: [4, 2]
        });
      }

      var scales = {
        x: { grid: { color: gridColor }, ticks: { color: textColor, font: { size: 10 } } },
        y: {
          position: 'left',
          title: { display: true, text: 'Packages', color: textColor, font: { size: 10 } },
          grid: { color: gridColor },
          ticks: { color: textColor, font: { size: 10 } }
        }
      };
      if (hasDuration) {
        scales.y1 = {
          position: 'right',
          title: { display: true, text: 'Build (min)', color: textColor, font: { size: 10 } },
          grid: { drawOnChartArea: false },
          ticks: { color: textColor, font: { size: 10 } }
        };
      }

      chartWrap.style.display = '';
      _historyChart = new Chart(canvas, {
        type: 'line',
        data: { labels: labels, datasets: datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            legend: { labels: { color: textColor, font: { size: 11 }, usePointStyle: true, pointStyle: 'circle' } }
          },
          scales: scales
        }
      });
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

      // Render trend chart
      renderHistoryChart(history);

      // Render table
      var wrap = document.getElementById('history-table-wrap');
      if (wrap) {
        wrap.textContent = '';
        var table = document.createElement('table');
        table.className = 'history-table';

        var hasDuration = history.some(function(b) { return b.duration_seconds != null; });
        var headers = ['Date', 'Version', 'Packages'];
        if (hasDuration) headers.push('Duration');
        headers.push('Changes');

        var thead = document.createElement('thead');
        var headerRow = document.createElement('tr');
        headers.forEach(function(h) {
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

          if (hasDuration) {
            var tdDur = document.createElement('td');
            tdDur.className = 'history-duration';
            tdDur.textContent = formatDuration(build.duration_seconds);
            tr.appendChild(tdDur);
          }

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

      var chip = e.target.closest('.sbom-type-chip-clickable');
      if (chip) togglePackagePanel(chip.dataset.type);

      var regBtn = e.target.closest('.detail-registry-btn');
      if (regBtn) setDetailRegistry(regBtn.dataset.registry);

      if (e.target.closest('#detail-copy-btn') || e.target.closest('.detail-copy-btn')) {
        copyDetailPullCommand();
      }

      if (e.target.closest('.theme-toggle')) {
        ThemeManager.toggleTheme();
      }
    });

    document.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' || e.key === ' ') {
        var chip = e.target.closest('.sbom-type-chip-clickable');
        if (chip) { e.preventDefault(); togglePackagePanel(chip.dataset.type); return; }
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

    // Initialize registry toggle from localStorage preference
    setDetailRegistry(currentRegistry);

    // Auto-select pull input text on click
    var pullInput = document.getElementById('detail-pull-cmd');
    if (pullInput) {
      pullInput.addEventListener('click', function() { this.select(); });
    }
  })();
