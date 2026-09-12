// docs/site/assets/js/components/security-scan.js
//
// Vanilla custom element. CSP-clean. Detail-page only.
// Re-renders Security Scan section on `phase-b-variant-changed`.
// XSS-safe: only textContent + createElement, never innerHTML (Trivy advisory data is upstream-controlled).

(function () {
  'use strict';

  function isValidAdvisory(adv) {
    const textualFields = ['rule_id', 'title', 'package_name'];
    const expectedFields = ['rule_id', 'severity', 'title', 'package_name'];
    return adv !== null && typeof adv === 'object' && !Array.isArray(adv)
      && Object.keys(adv).length === expectedFields.length
      && expectedFields.every((field) => Object.prototype.hasOwnProperty.call(adv, field))
      && ['critical', 'high', 'medium', 'low', 'info'].includes(adv.severity)
      && textualFields.every((field) => adv[field] === null || typeof adv[field] === 'string');
  }

  class SecurityScan extends HTMLElement {
    connectedCallback() {
      this._handler = (e) => this._update(e.detail);
      document.addEventListener('phase-b-variant-changed', this._handler);
    }

    disconnectedCallback() {
      if (this._handler) document.removeEventListener('phase-b-variant-changed', this._handler);
    }

    _update(variant) {
      if (!variant || !variant.trivy_summary || !variant.trivy_summary.display_source) {
        this.style.display = 'none';
        return;
      }
      const summary = variant.trivy_summary;
      this.style.display = '';
      const source = summary.display_source;
      const card = this.closest('.security-scan-card');
      const report = this.querySelector('.full-report a') || (card && card.querySelector('.security-scan-card-footer a'));
      const reportHref = report ? report.getAttribute('href') : '';

      while (this.firstChild) this.removeChild(this.firstChild);

      if (source === 'unavailable') {
        const unavailable = document.createElement('p');
        unavailable.className = 'scan-meta evidence-empty';
        unavailable.setAttribute('data-scan', 'unavailable-message');
        unavailable.textContent = 'No security evidence available — Code Scanning could not be read and no usable scan record was found';
        this.appendChild(unavailable);
        return;
      }

      const counts = summary.counts || {};
      const total = ['critical', 'high', 'medium', 'low', 'info']
        .reduce((sum, key) => sum + (counts[key] || 0), 0);
      const date = (summary.as_of || '').slice(0, 10);
      let summaryLabel;
      if (source === 'code-scanning') {
        summaryLabel = total + ' open Code Scanning alerts · fetched ' + date + ' · advisory mode (does not block builds)';
      } else if (source === 'scan-record') {
        summaryLabel = total + ' finding(s) from the recorded scan · scanned ' + date + ' · advisory mode (does not block builds)';
      } else {
        this.style.display = 'none';
        return;
      }

      const meta = document.createElement('p');
      meta.className = 'scan-meta';
      const summaryText = document.createElement('span');
      summaryText.setAttribute('data-scan', 'summary-label');
      summaryText.textContent = summaryLabel;
      meta.appendChild(summaryText);
      this.appendChild(meta);

      const observations = document.createElement('div');
      observations.className = 'scan-observations';
      observations.setAttribute('data-scan', 'observations');
      const codeScanning = summary.code_scanning;
      const scanRecord = summary.scan_record;
      if (codeScanning) {
        const codeCounts = codeScanning.counts || {};
        const codeTotal = ['critical', 'high', 'medium', 'low', 'info']
          .reduce((sum, key) => sum + (codeCounts[key] || 0), 0);
        const codeObservation = document.createElement('span');
        codeObservation.textContent = 'Code Scanning: ' + codeTotal + ' open alerts · fetched ' + (codeScanning.fetched_at || '').slice(0, 10);
        observations.appendChild(codeObservation);
      }
      if (scanRecord) {
        const recordCounts = scanRecord.counts || {};
        const recordTotal = ['critical', 'high', 'medium', 'low', 'info']
          .reduce((sum, key) => sum + (recordCounts[key] || 0), 0);
        const recordObservation = document.createElement('span');
        recordObservation.textContent = 'Recorded scan: ' + recordTotal + ' findings · scanned ' + (scanRecord.scan_at || '').slice(0, 10);
        observations.appendChild(recordObservation);
      }
      if (observations.childElementCount > 0) this.appendChild(observations);

      const grid = document.createElement('div');
      grid.className = 'severity-grid';
      ['critical', 'high', 'medium', 'low', 'info'].forEach((key) => {
        const value = counts[key] != null ? counts[key] : 0;
        const cell = document.createElement('div');
        const count = document.createElement('span');
        count.className = 'count';
        count.setAttribute('data-scan-count', key);
        count.textContent = value;
        if (value > 0) {
          count.classList.add('nonzero');
          cell.classList.add('nonzero');
        }
        const label = document.createElement('span');
        label.className = 'label';
        label.textContent = key.charAt(0).toUpperCase() + key.slice(1);
        cell.appendChild(count);
        cell.appendChild(label);
        grid.appendChild(cell);
      });
      this.appendChild(grid);

      if ((source === 'code-scanning' && total === 0) ||
          (source === 'scan-record' && (counts.critical || 0) === 0 && (counts.high || 0) === 0)) {
        const clean = document.createElement('p');
        clean.className = 'scan-clean-msg';
        clean.textContent = source === 'code-scanning'
          ? 'No open Code Scanning alerts as of ' + date + '.'
          : 'No CRITICAL or HIGH findings in recorded scan (' + date + ').';
        this.appendChild(clean);
      }

      const advisories = Array.isArray(summary.top_advisories)
        ? summary.top_advisories.filter(isValidAdvisory) : [];
      if (advisories.length > 0) {
        const advisoriesWrap = document.createElement('div');
        advisoriesWrap.setAttribute('data-scan', 'advisories-wrap');
        const heading = document.createElement('h3');
        heading.textContent = 'Top advisories (upstream, advisory)';
        const list = document.createElement('ul');
        list.className = 'top-advisories';
        list.setAttribute('data-scan', 'top-advisories');
        advisories.forEach((adv) => {
          const li = document.createElement('li');
          const strong = document.createElement('strong');
          strong.textContent = adv.rule_id || '';
          li.appendChild(strong);
          const sev = (adv.severity || '').toUpperCase();
          const pkg = adv.package_name || '';
          const title = adv.title || '';
          li.appendChild(document.createTextNode(' (' + sev + ') — ' + pkg + ' — ' + title));
          list.appendChild(li);
        });
        advisoriesWrap.appendChild(heading);
        advisoriesWrap.appendChild(list);
        this.appendChild(advisoriesWrap);
      }

      if (reportHref) {
        const fullReport = document.createElement('p');
        fullReport.className = 'full-report';
        fullReport.appendChild(document.createTextNode('→ See '));
        const link = document.createElement('a');
        link.href = reportHref;
        link.textContent = 'verification steps';
        fullReport.appendChild(link);
        fullReport.appendChild(document.createTextNode('.'));
        this.appendChild(fullReport);
      }
    }
  }

  customElements.define('security-scan', SecurityScan);
})();
