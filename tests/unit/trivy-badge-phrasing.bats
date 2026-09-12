#!/usr/bin/env bats

load "../test_helper"

setup() {
    template_unavailable_label='^[[:space:]]*\{%- assign trivy_full_label = "No security evidence available — Code Scanning could not be read and no usable scan record was found" -%\}$'
    template_code_scanning_label='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} open Code Scanning alerts · fetched \{\{ trivy_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    template_scan_record_label='^[[:space:]]*\{%- capture trivy_full_label -%\}\{\{ trivy_count \}\} finding\(s\) from the recorded scan · scanned \{\{ trivy_date \}\} · advisory mode \(does not block builds\)\{%- endcapture -%\}$'
    javascript_unavailable_label="        const fullLabel = 'No security evidence available — Code Scanning could not be read and no usable scan record was found';"
    javascript_code_scanning_label="        fullLabel = total + ' open Code Scanning alerts · fetched ' + date + ' · advisory mode (does not block builds)';"
    javascript_scan_record_label="        fullLabel = total + ' finding(s) from the recorded scan · scanned ' + date + ' · advisory mode (does not block builds)';"
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

# This source-level guard proves the label lines agree for each display source.
# It does not prove which line renders, nor what a sink ultimately displays.
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
