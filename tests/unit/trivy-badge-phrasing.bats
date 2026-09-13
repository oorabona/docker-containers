#!/usr/bin/env bats

load "../test_helper"

setup() {
    template_unavailable_label='^[[:space:]]*\{%- assign trivy_full_label = "No security evidence available — Code Scanning could not be read and no usable scan record was found" -%\}$'
    template_code_scanning_label='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} open Code Scanning alerts · fetched \{\{ trivy_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    template_scan_record_label='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} finding\(s\) from the recorded scan · scanned \{\{ trivy_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    javascript_unavailable_label="        const fullLabel = 'No security evidence available — Code Scanning could not be read and no usable scan record was found';"
    javascript_code_scanning_label="        fullLabel = total + ' open Code Scanning alerts · fetched ' + date + ' · advisory mode (does not block builds)';"
    javascript_scan_record_label="        fullLabel = total + ' finding(s) from the recorded scan · scanned ' + date + ' · advisory mode (does not block builds)';"
    verification_total_findings_sentence='The build does not fail when findings are detected; it surfaces the total reported count for the operator to triage.'
    legacy_cves_detected_spelling='The build does not fail when CVEs are detected; it surfaces the count for the operator to triage.'
    legacy_badge_count_spelling='The badge count is the number of findings. One CVE affecting multiple packages contributes multiple findings.'
}

assert_template_label() {
    local display_source="$1"
    local expected_label="$2"
    local badge_file="$3"

    run grep -qxE "$expected_label" "$badge_file"
    if [ "$status" -ne 0 ]; then
        echo "missing $display_source badge label in $badge_file" >&2
    fi
    [ "$status" -eq 0 ]
}

assert_javascript_label() {
    local display_source="$1"
    local expected_label="$2"
    local badge_file="$3"

    run grep -qFx "$expected_label" "$badge_file"
    if [ "$status" -ne 0 ]; then
        echo "missing $display_source badge label in $badge_file" >&2
    fi
    [ "$status" -eq 0 ]
}

assert_verification_total_findings_sentence() {
    local surface="$1"

    # Not -q: quiet grep stops at the first match, so a read failure in the
    # rest of the file would never surface. Reading it through keeps an I/O
    # error non-zero.
    run grep -F -- "$verification_total_findings_sentence" "$surface"
    [ "$status" -eq 0 ] || {
        echo "missing total-findings sentence in $surface" >&2
        return 1
    }
}

assert_legacy_verification_spelling_absent() {
    local spelling="$1"
    local surface="$2"

    run grep -qF "$spelling" "$surface"
    if [ "$status" -gt 1 ]; then
        echo "grep failed while checking $surface for a legacy spelling" >&2
        return 1
    fi
    [ "$status" -eq 1 ] || {
        echo "legacy spelling remains in $surface: $spelling" >&2
        return 1
    }
}

assert_trivy_severity_transitions() {
    local badge_file="$1"
    local producer="$2"

    run node - "$badge_file" "$producer" <<'NODE'
const fs = require('fs');
const [file, producer] = process.argv.slice(-2);
const source = fs.readFileSync(file, 'utf8');
const liquid = producer === 'liquid';
const transition = liquid
  ? /\{%- if trivy_critical > 0 -%\}\s*\{%- assign trivy_sev = "critical" -%\}\s*\{%- elsif trivy_high > 0 -%\}\s*\{%- assign trivy_sev = "high" -%\}\s*\{%- elsif trivy_count > 0 -%\}\s*\{%- assign trivy_sev = "advisory" -%\}\s*\{%- else -%\}\s*\{%- assign trivy_sev = "info" -%\}/
  : /if \(critical > 0\) \{\s*sev = 'critical';\s*\} else if \(high > 0\) \{\s*sev = 'high';\s*\} else if \(total > 0\) \{\s*sev = 'advisory';\s*\} else \{\s*sev = 'info';/;
if (!transition.test(source)) {
  console.error('missing ordered critical/high/advisory/clean severity transition in ' + file);
  process.exit(1);
}
NODE
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        return 1
    }
}

# These source-level guards prove only the pinned source text: a sentence moved
# into a Liquid or HTML comment still satisfies them.
# tests/assert-rendered-site.sh asserts the phrasing against a rendered site
# directory; these guards certify source text only.
@test "verification surfaces carry the total-findings sentence" {
    assert_verification_total_findings_sentence "$PROJECT_ROOT/docs/site/verify-images.md"
    assert_verification_total_findings_sentence "$PROJECT_ROOT/docs/site/_includes/components/verify-walkthrough.html"
    assert_verification_total_findings_sentence "$PROJECT_ROOT/docs/site/_includes/jsonld-faq.html"
}

@test "verification surfaces reject the known legacy CVEs-detected spelling" {
    for surface in \
        "$PROJECT_ROOT/docs/site/verify-images.md" \
        "$PROJECT_ROOT/docs/site/_includes/components/verify-walkthrough.html" \
        "$PROJECT_ROOT/docs/site/_includes/jsonld-faq.html"; do
        assert_legacy_verification_spelling_absent "$legacy_cves_detected_spelling" "$surface"
    done
}

@test "verification surfaces reject the known legacy badge-count spelling" {
    for surface in \
        "$PROJECT_ROOT/docs/site/verify-images.md" \
        "$PROJECT_ROOT/docs/site/_includes/components/verify-walkthrough.html" \
        "$PROJECT_ROOT/docs/site/_includes/jsonld-faq.html"; do
        assert_legacy_verification_spelling_absent "$legacy_badge_count_spelling" "$surface"
    done
}

@test "badge producers define matching source-specific label lines" {
    for badge_file in \
        "$PROJECT_ROOT/docs/site/_includes/container-card.html" \
        "$PROJECT_ROOT/docs/site/_layouts/container-detail.html"; do
        assert_template_label unavailable "$template_unavailable_label" "$badge_file"
        assert_template_label code-scanning "$template_code_scanning_label" "$badge_file"
        assert_template_label scan-record "$template_scan_record_label" "$badge_file"
    done

    assert_javascript_label unavailable "$javascript_unavailable_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    assert_javascript_label code-scanning "$javascript_code_scanning_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
    assert_javascript_label scan-record "$javascript_scan_record_label" "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js"
}

# Source-level guard: the server templates are Liquid and the browser producer is
# JavaScript, so this locks their equivalent control-flow rather than a label alone.
@test "medium-only Trivy badges use an advisory state in every producer" {
    assert_trivy_severity_transitions "$PROJECT_ROOT/docs/site/_includes/container-card.html" liquid
    assert_trivy_severity_transitions "$PROJECT_ROOT/docs/site/_layouts/container-detail.html" liquid
    assert_trivy_severity_transitions "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js" javascript

    run grep -qE '^\.trust-badge--trivy\[data-severity="advisory"\],' "$PROJECT_ROOT/docs/site/assets/css/theme.css"
    [ "$status" -eq 0 ] || {
        echo "missing neutral advisory badge rule in docs/site/assets/css/theme.css" >&2
        return 1
    }
}

@test "zero-total Trivy badges retain the clean info state in every producer" {
    assert_trivy_severity_transitions "$PROJECT_ROOT/docs/site/_includes/container-card.html" liquid
    assert_trivy_severity_transitions "$PROJECT_ROOT/docs/site/_layouts/container-detail.html" liquid
    assert_trivy_severity_transitions "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js" javascript
}

@test "security evidence directs initial and variant-switch renders to verification steps" {
    local template="$PROJECT_ROOT/docs/site/_layouts/container-detail.html"

    # The initial server render is static HTML apart from the guide URL filter.
    run grep -qE '<p class="full-report">→ See <a href="\{\{ .*/verify-images/.*\}\}#trivy">verification steps</a>\.</p>' "$template"
    [ "$status" -eq 0 ] || {
        echo "initial security evidence render does not expose verification steps" >&2
        return 1
    }

    run node - "$PROJECT_ROOT/docs/site/assets/js/components/security-scan.js" <<'NODE'
const fs = require('fs');
const source = fs.readFileSync(process.argv[process.argv.length - 1], 'utf8');

class Element {
  constructor(tag = '') { this.tag = tag; this.children = []; this.attributes = {}; this.style = {}; this.classList = { add() {} }; this.textContent = ''; }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  get firstChild() { return this.children[0] || null; }
  get childElementCount() { return this.children.filter((child) => child.tag).length; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] || ''; }
  querySelector() { return null; }
}
global.HTMLElement = Element;
global.document = { addEventListener() {}, removeEventListener() {}, createElement(tag) { return new Element(tag); }, createTextNode(text) { return { textContent: String(text) }; } };
global.customElements = { define(_name, component) { global.SecurityScan = component; } };
eval(source);

function text(node) { return [node.textContent || '', ...(node.children || []).map(text)].join(' '); }
function find(node, predicate) { if (predicate(node)) return node; for (const child of node.children || []) { const found = find(child, predicate); if (found) return found; } return null; }
function assert(condition, message) { if (!condition) throw new Error(message); }
function observation(display_source) {
  return { trivy_summary: { display_source, as_of: '2026-09-05T14:00:00Z', counts: { critical: 0, high: 1, medium: 0, low: 0, info: 0 }, top_advisories: [], code_scanning: display_source === 'code-scanning' ? { fetched_at: '2026-09-05T14:00:00Z', counts: { critical: 0, high: 1, medium: 0, low: 0, info: 0 } } : null, scan_record: display_source === 'scan-record' ? { scan_at: '2026-09-05T14:00:00Z', counts: { critical: 0, high: 1, medium: 0, low: 0, info: 0 } } : null } };
}
const component = new global.SecurityScan();
component.closest = () => ({ querySelector() { return { getAttribute() { return '/verify-images/#trivy'; } }; } });
for (const displaySource of ['code-scanning', 'scan-record']) {
  component._update(observation(displaySource));
  const link = find(component, (node) => node.tag === 'a');
  const rendered = text(component);
  assert(link && link.href === '/verify-images/#trivy' && link.textContent === 'verification steps', displaySource + ' did not render the verification link');
  assert(!/gh api|Full report/i.test(rendered), displaySource + ' rendered a forbidden API call-to-action');
}
NODE
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        return 1
    }
}

@test "security evidence wording does not advertise an API report" {
    local template="$PROJECT_ROOT/docs/site/_layouts/container-detail.html"
    local javascript="$PROJECT_ROOT/docs/site/assets/js/components/security-scan.js"
    local css="$PROJECT_ROOT/docs/site/assets/css/container-detail.css"

    for surface in "$template" "$javascript" "$css"; do
        run grep -qF 'Full report via gh api' "$surface"
        [ "$status" -ne 0 ] || {
            echo "forbidden API call-to-action remains in $surface" >&2
            return 1
        }
    done
}

@test "verification guide identifies the Code Scanning query as current and open" {
    local guide="$PROJECT_ROOT/docs/site/verify-images.md"

    run grep -qF 'the `gh api` command above queries the current open Code Scanning alert list.' "$guide"
    [ "$status" -eq 0 ] || {
        echo "verification guide does not describe the open Code Scanning query" >&2
        return 1
    }
    for stale in 'full advisory list' 'historical Code Scanning alert list'; do
        run grep -qF "$stale" "$guide"
        [ "$status" -ne 0 ] || {
            echo "verification guide overclaims a $stale" >&2
            return 1
        }
    done
}

@test "security evidence eyebrow and card comment cover all badge states" {
    local template="$PROJECT_ROOT/docs/site/_layouts/container-detail.html"
    local card="$PROJECT_ROOT/docs/site/_includes/container-card.html"

    run grep -qF '<p class="eyebrow">Security evidence</p>' "$template"
    [ "$status" -eq 0 ] || return 1
    run grep -qF 'Security scan results' "$template"
    [ "$status" -ne 0 ] || {
        echo "Code Scanning result remains under a scan-only eyebrow" >&2
        return 1
    }

    run node - "$card" <<'NODE'
const fs = require('fs');
const source = fs.readFileSync(process.argv[process.argv.length - 1], 'utf8');
const normalizedSource = source.replace(/\s+/g, ' ');
const requiredComment = [
  // This complete count-and-buckets sentence is intentionally terminal-punctuation-pinned:
  // its period separates the independent state-behaviour claim that follows.
  'Compact card badge displays the total across all five severity buckets.',
  'Its state is critical when any critical finding exists, else high when',
  'any high finding exists, else neutral advisory for any medium, low, or',
  'info finding, else clean at zero. `display_source: unavailable` is',
  'separate: it renders no evidence with the unknown state',
  'every other present source is shown as not recorded',
];
for (const line of requiredComment) {
  if (!normalizedSource.includes(line)) throw new Error('card comment is missing: ' + line);
}
if (source.includes('of the most severe non-zero level')) throw new Error('card comment still claims a most-severe count');
const countExpression = /assign trivy_count = trivy_critical \| plus: trivy_high \| plus: trivy_medium \| plus: trivy_low \| plus: trivy_info/.test(source);
if (!countExpression) throw new Error('card does not sum all five severity buckets');
const counts = { critical: 1, high: 4, medium: 0, low: 0, info: 0 };
const total = Object.values(counts).reduce((sum, count) => sum + count, 0);
if (total !== 5) throw new Error('critical=1, high=4 must render a total badge count of 5');
const transitions = /if trivy_critical > 0[\s\S]*elsif trivy_high > 0[\s\S]*elsif trivy_count > 0[\s\S]*else[\s\S]*assign trivy_sev = "info"/.test(source);
if (!transitions || !/trivy_source == "unavailable"[\s\S]*trivy_sev = "unknown"[\s\S]*trivy_badge_text = "no evidence"/.test(source)) {
  throw new Error('card does not distinguish critical, high, advisory, clean, and unavailable states');
}
NODE
    [ "$status" -eq 0 ] || {
        echo "$output" >&2
        return 1
    }
}

@test "security scan ignores malformed advisory rows during a variant change" {
    run node - "$PROJECT_ROOT/docs/site/assets/js/components/security-scan.js" <<'NODE'
const fs = require('fs');
const source = fs.readFileSync(process.argv[process.argv.length - 1], 'utf8');

class Element {
  constructor(tag = '') {
    this.tag = tag;
    this.children = [];
    this.attributes = {};
    this.style = {};
    this.classList = { add() {} };
  }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  get firstChild() { return this.children[0] || null; }
  get childElementCount() { return this.children.filter((child) => child.tag).length; }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name] || ''; }
  querySelector() { return null; }
}

global.HTMLElement = Element;
global.document = {
  addEventListener() {},
  removeEventListener() {},
  createElement(tag) { return new Element(tag); },
  createTextNode(text) { return { textContent: text }; },
};
global.customElements = { define(_name, component) { global.SecurityScan = component; } };
eval(source);

function find(node, predicate) {
  if (predicate(node)) return node;
  for (const child of node.children || []) {
    const found = find(child, predicate);
    if (found) return found;
  }
  return null;
}

const component = new global.SecurityScan();
component._card = { querySelector() { return { getAttribute() { return '/verify-images/'; } }; } };
component.closest = function () { return this._card; };
component._update({ trivy_summary: {
  display_source: 'code-scanning',
  as_of: '2026-09-05T14:00:00Z',
  counts: { critical: 1, high: 0, medium: 0, low: 0, info: 0 },
  top_advisories: [null, { rule_id: 'CVE-bad', severity: 3, title: null, package_name: null }],
  scan_record: null,
  code_scanning: {
    fetched_at: '2026-09-05T14:00:00Z',
    counts: { critical: 1, high: 0, medium: 0, low: 0, info: 0 },
    top_advisories: [],
  },
} });

const critical = find(component, (node) => node.attributes && node.attributes['data-scan-count'] === 'critical');
const report = find(component, (node) => node.tag === 'a' && node.href === '/verify-images/');
if (!critical || String(critical.textContent) !== '1' || !report) process.exit(1);
NODE
    [ "$status" -eq 0 ]
}

@test "browser Trivy renderers preserve all evidence states across a variant switch" {
    run node - \
        "$PROJECT_ROOT/docs/site/assets/js/components/security-scan.js" \
        "$PROJECT_ROOT/docs/site/assets/js/components/trust-strip.js" <<'NODE'
const fs = require('fs');
const [securitySource, trustSource] = process.argv.slice(-2).map((file) => fs.readFileSync(file, 'utf8'));
const listeners = {};

class Element {
  constructor(tag = '') {
    this.tag = tag;
    this.children = [];
    this.attributes = {};
    this.style = {};
    this.className = '';
    this.textContent = '';
    this.classList = { add() {}, remove() {} };
  }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  get firstChild() { return this.children[0] || null; }
  get childElementCount() { return this.children.filter((child) => child.tag).length; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] || ''; }
  removeAttribute(name) { delete this.attributes[name]; }
  closest() { return null; }
  querySelector() { return null; }
}

global.HTMLElement = Element;
global.document = {
  addEventListener(name, listener) { (listeners[name] ||= []).push(listener); },
  removeEventListener() {},
  createElement(tag) { return new Element(tag); },
  createTextNode(text) { return { textContent: String(text) }; },
  dispatch(detail) { (listeners['phase-b-variant-changed'] || []).forEach((listener) => listener({ detail })); },
};
global.customElements = { define(name, component) { global[name] = component; } };
eval(securitySource);
eval(trustSource);

const codeZero = { trivy_summary: { display_source: 'code-scanning', as_of: '2026-09-05T14:00:00Z', counts: { critical: 0, high: 0, medium: 0, low: 0, info: 0 }, top_advisories: [], scan_record: null, code_scanning: { fetched_at: '2026-09-05T14:00:00Z', counts: { critical: 0, high: 0, medium: 0, low: 0, info: 0 }, top_advisories: [] } } };
const codeFinding = { trivy_summary: { display_source: 'code-scanning', as_of: '2026-09-05T14:00:00Z', counts: { critical: 1, high: 0, medium: 0, low: 0, info: 0 }, top_advisories: [], scan_record: null, code_scanning: { fetched_at: '2026-09-05T14:00:00Z', counts: { critical: 1, high: 0, medium: 0, low: 0, info: 0 }, top_advisories: [] } } };
const scanRecord = { trivy_summary: { display_source: 'scan-record', as_of: '2026-09-04T14:00:00Z', counts: { critical: 0, high: 1, medium: 0, low: 0, info: 0 }, top_advisories: [], scan_record: { scan_at: '2026-09-04T14:00:00Z', counts: { critical: 0, high: 1, medium: 0, low: 0, info: 0 } }, code_scanning: null } };
const unavailable = { trivy_summary: { display_source: 'unavailable', as_of: null, counts: null, top_advisories: [], scan_record: null, code_scanning: null } };

function text(node) {
  return [node.textContent || '', ...(node.children || []).map(text)].join(' ');
}
function hasCount(node) {
  return !!node.attributes && Object.prototype.hasOwnProperty.call(node.attributes, 'data-scan-count')
    || (node.children || []).some(hasCount);
}
function assert(condition, message) { if (!condition) throw new Error(message); }

const security = new global['security-scan']();
security.connectedCallback();
document.dispatch(codeZero);
assert(/No open Code Scanning alerts/.test(text(security)), 'Code-Scanning zero did not render clean observation');
document.dispatch(codeFinding);
assert(/1 open Code Scanning alerts/.test(text(security)), 'Code-Scanning finding did not render its count');
document.dispatch(scanRecord);
assert(/1 finding\(s\) from the recorded scan/.test(text(security)), 'scan record did not render its count');
document.dispatch(unavailable);
assert(/No security evidence available/.test(text(security)), 'unavailable security section did not render neutral state');
assert(!/\b0\b|No open|No CRITICAL or HIGH/.test(text(security)), 'unavailable security section rendered a number or clean sentence');
assert(!hasCount(security), 'unavailable security section rendered a severity count');

const trust = new global['trust-strip']();
const badge = new Element('a');
trust.querySelector = (selector) => selector === '[data-trust="trivy"]' ? badge : null;
trust.connectedCallback();
document.dispatch(codeZero);
assert(/0 open alerts/.test(badge.textContent), 'Code-Scanning zero badge did not render');
document.dispatch(codeFinding);
assert(/1 open alerts/.test(badge.textContent), 'Code-Scanning finding badge did not render');
document.dispatch(scanRecord);
assert(/1 findings/.test(badge.textContent), 'scan record badge did not render');
document.dispatch(unavailable);
assert(badge.textContent === '🛡 no evidence', 'unavailable badge did not render neutral state');
assert(!/\d|No open|No CRITICAL or HIGH/.test(badge.textContent + ' ' + badge.attributes['aria-label']), 'unavailable badge rendered a number or clean sentence');
NODE
    [ "$status" -eq 0 ]
}

@test "verification guide mirrors the Code Scanning severity field and filters" {
    local guide="$PROJECT_ROOT/docs/site/verify-images.md"

    run grep -qF 'security_severity_level' "$guide"
    [ "$status" -eq 0 ] || {
        echo "missing security_severity_level positive control in $guide" >&2
        return 1
    }
    run grep -qF 'tool_name=Trivy&amp;state=open&amp;per_page=100' "$guide"
    [ "$status" -eq 0 ] || {
        echo "missing producer-equivalent Code Scanning filters in $guide" >&2
        return 1
    }
    run grep -qF 'rule.severity' "$guide"
    [ "$status" -ne 0 ] || {
        echo "guide still buckets Code Scanning alerts by rule.severity" >&2
        return 1
    }
}

@test "current Trivy artifacts do not describe the deleted overlay or dead selector" {
    local adr="$PROJECT_ROOT/docs/adr/ADR-008-trivy-severity-policy.md"
    local helper="$PROJECT_ROOT/helpers/trivy-utils.sh"
    local css="$PROJECT_ROOT/docs/site/assets/css/components/security-scan-card.css"
    local template="$PROJECT_ROOT/docs/site/_layouts/container-detail.html"

    run grep -qF 'Trivy summary and evidence-channel helpers' "$adr"
    [ "$status" -eq 0 ] || return 1
    run grep -qF 'classList.add' "$css"
    [ "$status" -eq 0 ] || return 1
    run grep -qF 'classList.add' "$template"
    [ "$status" -eq 0 ] || return 1

    for stale in \
        'side-channel overlay merge implementation' \
        'freshness comparison callers' \
        '[data-scan="last-scan"]' \
        'toggles class "nonzero"' \
        "classList.toggle('nonzero'"; do
        case "$stale" in
            'side-channel overlay merge implementation') target="$adr" ;;
            'freshness comparison callers') target="$helper" ;;
            '[data-scan="last-scan"]'|'toggles class "nonzero"') target="$css" ;;
            "classList.toggle('nonzero'") target="$template" ;;
        esac
        run grep -qF "$stale" "$target"
        [ "$status" -ne 0 ] || {
            echo "stale overlay claim remains in $target: $stale" >&2
            return 1
        }
    done
}
