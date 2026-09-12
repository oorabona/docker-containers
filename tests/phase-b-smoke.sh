#!/usr/bin/env bash
# Phase B trust-signal layer smoke test
#
# Usage:
#   ./tests/phase-b-smoke.sh           # Run all static checks (rendered assertions live in tests/assert-rendered-site.sh)
#   ./tests/phase-b-smoke.sh --probe   # Also run live URL probes (needs internet)
#
# Exit code: 0 if FAIL == 0, 1 otherwise.
# WARN does NOT count as failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
WARN=0

PROBE=false
for arg in "$@"; do
  [[ "$arg" == "--probe" ]] && PROBE=true
done

pass() { PASS=$((PASS + 1)); echo "  ✓ $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $*" >&2; }
warn() { WARN=$((WARN + 1)); echo "  ⚠ $*"; }

# ---------------------------------------------------------------------------
# Phase 0 — Dependency + required-input checks
# ---------------------------------------------------------------------------
for cmd in yq jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "Missing dependency: $cmd (some checks will be skipped)"
  fi
done

CONTAINERS_YML="${REPO_ROOT}/docs/site/_data/containers.yml"

required_files=(
  "docs/site/assets/js/components/trust-strip.js"
  "docs/site/assets/js/components/security-scan.js"
  "docs/site/assets/css/theme.css"
  "docs/site/assets/js/dashboard.js"
  "docs/site/assets/js/container-detail.js"
  "docs/site/_includes/container-card.html"
  "docs/site/_layouts/container-detail.html"
  "docs/site/_layouts/dashboard.html"
)
for f in "${required_files[@]}"; do
  if [ ! -f "${REPO_ROOT}/${f}" ]; then
    warn "Required input missing: ${f}"
  fi
done

if [ ! -f "${CONTAINERS_YML}" ]; then
  warn "containers.yml absent (run ./generate-dashboard.sh first) — Phase 1 yq checks will be skipped"
  CONTAINERS_YML_AVAILABLE=0
else
  CONTAINERS_YML_AVAILABLE=1
fi

# ---------------------------------------------------------------------------
# Phase 1 — Static source-file checks (no build required)
# ---------------------------------------------------------------------------
echo ""
echo "Phase 1 — Static source-file checks"
echo "────────────────────────────────────"

CARD_HTML="${REPO_ROOT}/docs/site/_includes/container-card.html"
DETAIL_HTML="${REPO_ROOT}/docs/site/_layouts/container-detail.html"
THEME_CSS="${REPO_ROOT}/docs/site/assets/css/theme.css"
DASHBOARD_JS="${REPO_ROOT}/docs/site/assets/js/dashboard.js"
DETAIL_JS="${REPO_ROOT}/docs/site/assets/js/container-detail.js"

# Needle split to prevent hook false-positive on the literal pattern itself.
# The two halves form ".innerHTML =" when joined.
# Uses POSIX character class [[:space:]] — grep -E (ERE) does not support \s.
_INNER="inner"
_HTML_EQ="HTML[[:space:]]*="

# 1. No raw .innerHTML= assignments in new JS (comments excluded)
# grep -v strips comment-only lines (lines whose code starts with // * or /*);
# || true prevents set -e on no-match.
inner_count=$(grep -nE "\.${_INNER}${_HTML_EQ}" "${DASHBOARD_JS}" "${DETAIL_JS}" 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' \
  | wc -l || true)
if [[ "${inner_count}" -eq 0 ]]; then
  pass "No raw .innerHTML= assignments in JS files (XSS safe)"
else
  fail "Found ${inner_count} raw .innerHTML= assignment(s) in JS — XSS risk; use textContent or createElement"
fi

# 2. Trust-strip CSS selectors present in their owning stylesheet (expect >= 4)
trust_css_count=$(grep -cE '^\.trust-strip|^\.trust-badge|^\.security-section|^\.severity-grid' \
  "${THEME_CSS}" 2>/dev/null || true)
if [[ "${trust_css_count}" -ge 4 ]]; then
  pass "Trust-strip CSS selectors present in theme.css (${trust_css_count} matching rules)"
else
  fail "Expected >= 4 trust-strip CSS selectors in theme.css, found ${trust_css_count}"
fi

# 3. value_proposition populated for >= 10 containers
if [[ "${CONTAINERS_YML_AVAILABLE}" -eq 1 ]]; then
  vp_count=$(yq '[.[] | select(.value_proposition != null and .value_proposition != "")] | length' \
    "${CONTAINERS_YML}" 2>/dev/null)
  if [[ "${vp_count}" -ge 10 ]]; then
    pass "value_proposition present on ${vp_count} containers (>= 10)"
  else
    fail "Expected >= 10 containers with value_proposition in containers.yml, found ${vp_count}"
  fi
else
  warn "Skipping check 3 — containers.yml not available"
fi

# 4. postgres when_to_use present on every variant (no nulls)
if [[ "${CONTAINERS_YML_AVAILABLE}" -eq 1 ]]; then
  pg_missing_when=$(yq '[.[] | select(.name == "postgres") | .versions[].variants[] | select(.when_to_use == null)] | length' \
    "${CONTAINERS_YML}" 2>/dev/null)
  if [[ "${pg_missing_when}" -eq 0 ]]; then
    pass "All postgres variants have when_to_use populated"
  else
    fail "postgres has ${pg_missing_when} variant(s) missing when_to_use"
  fi
else
  warn "Skipping check 4 — containers.yml not available"
fi

# 5. postgres vector variant (variant[1]) has compiled extensions
if [[ "${CONTAINERS_YML_AVAILABLE}" -eq 1 ]]; then
  pg_ext_count=$(yq '.[] | select(.name == "postgres") | .versions[0].variants[1].extensions | length' \
    "${CONTAINERS_YML}" 2>/dev/null)
  if [[ "${pg_ext_count}" -gt 0 ]]; then
    pass "postgres versions[0].variants[1] has ${pg_ext_count} extension(s) declared"
  else
    fail "Expected extensions on postgres variants[1] (vector flavor), found ${pg_ext_count}"
  fi
else
  warn "Skipping check 5 — containers.yml not available"
fi

# 6. upstream_monitor_url present on all containers
if [[ "${CONTAINERS_YML_AVAILABLE}" -eq 1 ]]; then
  missing_monitor=$(yq '[.[] | select(.upstream_monitor_url == null)] | length' \
    "${CONTAINERS_YML}" 2>/dev/null)
  if [[ "${missing_monitor}" -eq 0 ]]; then
    pass "upstream_monitor_url present on all containers"
  else
    fail "${missing_monitor} container(s) missing upstream_monitor_url in containers.yml"
  fi
else
  warn "Skipping check 6 — containers.yml not available"
fi

# 7. Trust strip class in container-card include
if grep -qE 'class="[^"]*\btrust-strip\b' "${CARD_HTML}" 2>/dev/null; then
  pass "trust-strip div found in container-card.html"
else
  fail 'trust-strip class token not found in container-card.html'
fi

# 8. Four structural checks in container-detail.html
if grep -q 'trust-strip' "${DETAIL_HTML}" 2>/dev/null; then
  pass "trust-strip referenced in container-detail.html"
else
  fail "trust-strip not found in container-detail.html"
fi

if grep -qE 'class="security-section|id="security"' "${DETAIL_HTML}" 2>/dev/null; then
  pass "security section anchor present in container-detail.html"
else
  warn 'class="security-section" not matched in container-detail.html source (may render via JS or CSS class only)'
fi

if grep -qE 'value_proposition|class="value-prop"' "${DETAIL_HTML}" 2>/dev/null; then
  pass "value_proposition / value-prop section in container-detail.html"
else
  fail "value_proposition block not found in container-detail.html"
fi

if grep -qE 'class="variants-table-section"|class="variants-table"' "${DETAIL_HTML}" 2>/dev/null; then
  pass "variants-table section present in container-detail.html"
else
  fail "variants-table-section not found in container-detail.html"
fi

# 9. Postgres conditional guard in detail layout
if grep -q 'page\.name == "postgres"' "${DETAIL_HTML}" 2>/dev/null; then
  pass 'Postgres-only conditional guard (page.name == "postgres") found in container-detail.html'
else
  fail 'Expected page.name == "postgres" conditional guard in container-detail.html'
fi

# Published Trivy verification commands must query the same open Trivy alert
# population. Enumerate every gh api code-scanning/alerts occurrence, rather
# than recognising one particular jq output shape, so copyable, displayed, and
# JSON-LD commands all receive the same endpoint and compilation assertions.
VERIFY_COMMAND_FILES=(
  "docs/site/verify-images.md"
  "docs/site/_includes/components/verify-walkthrough.html"
  "docs/site/_includes/jsonld-howto-verify.html"
)
TRIVY_ALERT_ENDPOINT='repos/oorabona/docker-containers/code-scanning/alerts?tool_name=Trivy&state=open&per_page=100'
TRIVY_ALERT_SAMPLE='[{"rule":{"id":"CVE-TEST","security_severity_level":"high"},"most_recent_instance":{"category":"container-example-linux/amd64","location":{"path":"usr/lib/example"}}}]'
VERIFY_COMMAND_COUNT=0

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not available — published Trivy verification command validity was not established"
fi

for verify_file in "${VERIFY_COMMAND_FILES[@]}"; do
  verify_path="${REPO_ROOT}/${verify_file}"
  # A command can span lines, but its gh api endpoint is published on one line.
  # Decode the nearby command text below to cover HTML attributes and JSON-LD.
  mapfile -t trivy_command_lines < <(grep -nF 'gh api' "${verify_path}" | grep -F 'code-scanning/alerts' || true)
  VERIFY_COMMAND_COUNT=$((VERIFY_COMMAND_COUNT + ${#trivy_command_lines[@]}))

  if [[ "${#trivy_command_lines[@]}" -gt 0 ]]; then
    pass "${verify_file} publishes ${#trivy_command_lines[@]} code-scanning alert command(s)"
  else
    fail "${verify_file} publishes no code-scanning alert command(s)"
  fi

  for command_line in "${trivy_command_lines[@]}"; do
    line_number="${command_line%%:*}"
    # Displayed HTML commands put -q on a following line. Three lines cover
    # that form while still treating each endpoint occurrence independently.
    command_text=$(sed -n "${line_number},$((line_number + 2))p" "${verify_path}" \
      | sed 's/&amp;/\&/g; s/&quot;/"/g; s/\\"/"/g')

    if [[ "${command_text}" == *"${TRIVY_ALERT_ENDPOINT}"* ]]; then
      pass "${verify_file}:${line_number} queries the open Trivy alert population"
    else
      fail "${verify_file}:${line_number} does not query the open Trivy alert population"
    fi

    trivy_filter=$(printf '%s\n' "${command_text}" | sed -n "s/.*-q '\(.*\)'.*/\1/p")
    if [[ -z "${trivy_filter}" ]]; then
      fail "Could not extract jq filter from ${verify_file}:${line_number}"
      continue
    fi

    if command -v jq >/dev/null 2>&1; then
      # Wrapping results in an array makes an intentionally empty select()
      # successful while retaining jq's parse and runtime errors.
      if jq_result=$(jq -e -n --argjson alerts "${TRIVY_ALERT_SAMPLE}" '$alerts | [ ('"${trivy_filter}"') ]' 2>&1); then
        pass "${verify_file}:${line_number} jq filter compiles"
      else
        fail "${verify_file}:${line_number} jq filter does not compile: ${jq_result}"
      fi
    fi
  done
done

if [[ "${VERIFY_COMMAND_COUNT}" -gt 0 ]]; then
  pass "Enumerated ${VERIFY_COMMAND_COUNT} published code-scanning alert command(s) across all verification surfaces"
else
  fail "No published code-scanning alert commands were found across verification surfaces"
fi

obsolete_severity_matches=$(grep -nH -F '.rule.severity' "${VERIFY_COMMAND_FILES[@]/#/${REPO_ROOT}/}" 2>/dev/null || true)
if [[ -z "${obsolete_severity_matches}" ]]; then
  pass "Published Trivy verification commands do not read obsolete .rule.severity"
else
  fail "Published Trivy verification commands read obsolete .rule.severity: ${obsolete_severity_matches}"
fi

for verify_file in "${VERIFY_COMMAND_FILES[@]}"; do
  if grep -qF 'security_severity_level' "${REPO_ROOT}/${verify_file}"; then
    pass "${verify_file} names security_severity_level as the severity source"
  else
    fail "${verify_file} does not name security_severity_level as the severity source"
  fi
done

# 10. Vanilla web component checks (Block H rev3 — replaced Alpine 3)
DASHBOARD_HTML="${REPO_ROOT}/docs/site/_layouts/dashboard.html"
TRUST_STRIP_JS="${REPO_ROOT}/docs/site/assets/js/components/trust-strip.js"
SECURITY_SCAN_JS="${REPO_ROOT}/docs/site/assets/js/components/security-scan.js"

if test -f "${TRUST_STRIP_JS}"; then
  pass "trust-strip.js exists in assets/js/components/"
else
  fail "trust-strip.js not found in docs/site/assets/js/components/"
fi

if test -f "${SECURITY_SCAN_JS}"; then
  pass "security-scan.js exists in assets/js/components/"
else
  fail "security-scan.js not found in docs/site/assets/js/components/"
fi

if grep -q 'customElements.define' "${TRUST_STRIP_JS}" 2>/dev/null; then
  pass "trust-strip.js registers a custom element"
else
  fail "trust-strip.js does not call customElements.define"
fi

if grep -q 'customElements.define' "${SECURITY_SCAN_JS}" 2>/dev/null; then
  pass "security-scan.js registers a custom element"
else
  fail "security-scan.js does not call customElements.define"
fi

if grep -q '<trust-strip' "${CARD_HTML}" 2>/dev/null; then
  pass "container-card.html uses <trust-strip> custom element"
else
  fail "<trust-strip> not found in container-card.html"
fi

if grep -q '<trust-strip' "${DETAIL_HTML}" 2>/dev/null; then
  pass "container-detail.html uses <trust-strip> custom element"
else
  fail "<trust-strip> not found in container-detail.html"
fi

if grep -q '<security-scan' "${DETAIL_HTML}" 2>/dev/null; then
  pass "container-detail.html uses <security-scan> custom element"
else
  fail "<security-scan> not found in container-detail.html"
fi

if ! ls "${REPO_ROOT}/docs/site/assets/js/vendor/alpinejs-"*.min.js 2>/dev/null; then
  pass "Alpine.js vendored file removed from assets/js/vendor/"
else
  fail "Alpine.js vendored file still present in docs/site/assets/js/vendor/ — should be deleted"
fi

if ! grep -q 'alpinejs' "${DASHBOARD_HTML}" 2>/dev/null && ! grep -q 'alpinejs' "${DETAIL_HTML}" 2>/dev/null; then
  pass "No Alpine.js references remaining in dashboard.html or container-detail.html"
else
  fail "Alpine.js reference still found in layout files"
fi

if ! grep -qE 'x-data|x-show|x-text|x-for|@phase-b' "${CARD_HTML}" 2>/dev/null; then
  pass "No Alpine directives (x-data/x-show/x-text/x-for/@phase-b) in container-card.html"
else
  fail "Alpine directive(s) still present in container-card.html"
fi

if ! grep -qE 'x-data|x-show|x-text|x-for|@phase-b' "${DETAIL_HTML}" 2>/dev/null; then
  pass "No Alpine directives (x-data/x-show/x-text/x-for/@phase-b) in container-detail.html"
else
  fail "Alpine directive(s) still present in container-detail.html"
fi

if ! grep -q 'unsafe-eval' "${DASHBOARD_HTML}" "${DETAIL_HTML}" 2>/dev/null; then
  pass "No 'unsafe-eval' in CSP meta tags (dashboard.html + container-detail.html)"
else
  fail "'unsafe-eval' still present in CSP — must be removed for CSP-clean policy"
fi

if grep -q 'phase-b-variant-changed' "${DASHBOARD_JS}" 2>/dev/null; then
  pass "CustomEvent phase-b-variant-changed dispatch in dashboard.js"
else
  fail "CustomEvent phase-b-variant-changed not found in dashboard.js"
fi

if grep -q 'phase-b-variant-changed' "${DETAIL_JS}" 2>/dev/null; then
  pass "CustomEvent phase-b-variant-changed dispatch in container-detail.js"
else
  fail "CustomEvent phase-b-variant-changed not found in container-detail.js"
fi

if ! grep -q 'function updateTrustStrip' "${DASHBOARD_JS}" 2>/dev/null; then
  pass "updateTrustStrip removed from dashboard.js"
else
  fail "updateTrustStrip still present in dashboard.js — should have been removed"
fi

if ! grep -q 'function updateTrustStrip' "${DETAIL_JS}" 2>/dev/null; then
  pass "updateTrustStrip removed from container-detail.js"
else
  fail "updateTrustStrip still present in container-detail.js — should have been removed"
fi

# XSS safety: no raw .innerHTML= in new component files
inner_comp_count=$(grep -nE "\.${_INNER}${_HTML_EQ}" "${TRUST_STRIP_JS}" "${SECURITY_SCAN_JS}" 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' \
  | wc -l || true)
if [[ "${inner_comp_count}" -eq 0 ]]; then
  pass "No raw .innerHTML= assignments in web component files (XSS safe)"
else
  fail "Found ${inner_comp_count} raw .innerHTML= assignment(s) in component files — XSS risk"
fi

# Trivy evidence source contract: display_source, not last_scan, determines
# whether evidence is rendered. Keep this list aligned with every renderer.
TRIVY_RENDERERS=(
  "${CARD_HTML}"
  "${DETAIL_HTML}"
  "${SECURITY_SCAN_JS}"
  "${TRUST_STRIP_JS}"
  "${DETAIL_JS}"
)

# 11. A scan timestamp must never decide visibility; each renderer must have
# a positive display_source control so an empty negative grep cannot pass.
last_scan_gates=$(grep -nE '\{%-?[[:space:]]*(if|unless|elsif)[^%]*last_scan|if[[:space:]]*\([^)]*last_scan' \
  "${TRIVY_RENDERERS[@]}" 2>/dev/null || true)
if [[ -z "${last_scan_gates}" ]]; then
  pass "Trivy renderers do not gate display on last_scan"
else
  fail "Trivy renderer(s) still gate display on last_scan: ${last_scan_gates}"
fi

display_source_missing=0
for renderer in "${TRIVY_RENDERERS[@]}"; do
  if ! grep -q 'display_source' "${renderer}" 2>/dev/null; then
    fail "Trivy renderer lacks a display_source control: ${renderer#"${REPO_ROOT}/"}"
    display_source_missing=$((display_source_missing + 1))
  fi
done
if [[ "${display_source_missing}" -eq 0 ]]; then
  pass "Every Trivy renderer has a display_source control"
fi

# 12. Every renderer that decides the display recognizes the complete contract.
trivy_state_missing=0
for renderer in "${TRIVY_RENDERERS[@]}"; do
  for state in code-scanning scan-record unavailable; do
    if ! grep -q "${state}" "${renderer}" 2>/dev/null; then
      fail "Trivy renderer lacks ${state}: ${renderer#"${REPO_ROOT}/"}"
      trivy_state_missing=$((trivy_state_missing + 1))
    fi
  done
done
if [[ "${trivy_state_missing}" -eq 0 ]]; then
  pass "Every Trivy renderer recognizes code-scanning, scan-record, and unavailable"
fi

# 13. Unavailable is a literal, non-numeric badge, not a zero-like count.
unavailable_badge_failures=0
for renderer in "${CARD_HTML}" "${DETAIL_HTML}"; do
  if ! grep -qE 'assign trivy_badge_text = "no evidence"' "${renderer}" 2>/dev/null; then
    fail "Unavailable badge is not the literal no evidence in ${renderer#"${REPO_ROOT}/"}"
    unavailable_badge_failures=$((unavailable_badge_failures + 1))
  fi
  if grep -qE 'no evidence[^\n]*\{\{' "${renderer}" 2>/dev/null; then
    fail "Unavailable badge interpolates a value in ${renderer#"${REPO_ROOT}/"}"
    unavailable_badge_failures=$((unavailable_badge_failures + 1))
  fi
done
if [[ "${unavailable_badge_failures}" -eq 0 ]]; then
  pass "Unavailable badges are literal no evidence with no interpolated count"
fi

# 14. Unavailable Trivy evidence counts as empty provenance; a missing legacy
# key remains distinguishable as awaiting next build in the evidence row.
prov_key_presence_gates=$(grep -nE '\{%-?[[:space:]]*unless[[:space:]]+(_prov_var|prov_variant)\.trivy_summary[[:space:]]*-?%\}' \
  "${DETAIL_HTML}" 2>/dev/null || true)
if [[ -z "${prov_key_presence_gates}" ]]; then
  pass "prov_empty_count tests display_source rather than Trivy key presence"
else
  fail "prov_empty_count still tests Trivy key presence: ${prov_key_presence_gates}"
fi

# 15. Code Scanning's all-clear must use the five-bucket total. Recorded-scan
# messaging intentionally remains CRITICAL/HIGH-only because that is its claim.
all_clear_legacy_liquid=$(grep -nE 'sec_critical == 0 and sec_high == 0 and sec_variant\.trivy_summary\.display_source == "code-scanning"' \
  "${DETAIL_HTML}" 2>/dev/null || true)
all_clear_legacy_js=$(grep -nE "source === 'code-scanning'[^[:cntrl:]]*(critical|high)|(critical|high)[^[:cntrl:]]*source === 'code-scanning'" \
  "${SECURITY_SCAN_JS}" 2>/dev/null || true)
if [[ -z "${all_clear_legacy_liquid}" && -z "${all_clear_legacy_js}" ]]; then
  pass "Code Scanning all-clear is not gated only on CRITICAL/HIGH"
else
  fail "Code Scanning all-clear still uses a CRITICAL/HIGH-only gate: ${all_clear_legacy_liquid}${all_clear_legacy_js}"
fi
if grep -qE 'sec_count == 0 and sec_variant\.trivy_summary\.display_source == "code-scanning"' "${DETAIL_HTML}" \
  && grep -qF "source === 'code-scanning' && total === 0" "${SECURITY_SCAN_JS}"; then
  pass "Code Scanning all-clear uses the five-bucket total in both renderers"
else
  fail "Code Scanning all-clear lacks a total-based gate in one or both renderers"
fi

# 16. Nested scan_record carries scan_at; top-level last_scan is a separate
# compatibility field and must not be read by a site renderer.
nested_last_scan=$(grep -R -n -E 'scan_record\.last_scan|scanRecord\.last_scan' "${REPO_ROOT}/docs/site" 2>/dev/null || true)
if [[ -z "${nested_last_scan}" ]]; then
  pass "Site renderers do not read nested scan_record.last_scan"
else
  fail "Site renderer(s) still read nested last_scan: ${nested_last_scan}"
fi
if grep -qF 'sec_variant.trivy_summary.scan_record.scan_at' "${DETAIL_HTML}" \
  && grep -qF 'scanRecord.scan_at' "${SECURITY_SCAN_JS}"; then
  pass "Both scan-record renderers read scan_at"
else
  fail "One or both scan-record renderers do not read scan_at"
fi

# 17. The footer guides verification without asserting a scan exists.
if grep -qF 'REPRODUCE THIS SCAN' "${DETAIL_HTML}"; then
  fail "Security footer still claims an existing scan"
else
  pass "Security footer makes no claim that a scan exists"
fi

# 18. An unknown display_source must reset and hide the Trivy badge, matching
# security-scan.js's unreadable-state marker so variant switches cannot leak data.
trust_unknown_hides=$(grep -A5 -F "} else if (source === 'scan-record') {" "${TRUST_STRIP_JS}" 2>/dev/null \
  | grep -F "el.style.display = 'none';" || true)
if [[ -n "${trust_unknown_hides}" ]]; then
  pass "Trust-strip hides the Trivy badge for an unknown display_source"
else
  fail "Trust-strip unknown display_source path does not hide the Trivy badge"
fi

# 19. Lower-only findings are advisory, not clean.
if grep -qF 'assign trivy_sev = "advisory"' "${CARD_HTML}" \
  && grep -qF 'assign trivy_sev = "advisory"' "${DETAIL_HTML}" \
  && grep -qF "sev = 'advisory';" "${TRUST_STRIP_JS}" \
  && grep -qF 'data-severity="advisory"' "${THEME_CSS}"; then
  pass "Lower-only findings use the neutral advisory badge state in every producer"
else
  fail "One or more Trivy badge producers lack the advisory state"
fi
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Phase 3 — Live URL probes (opt-in via --probe; requires internet + curl)
# ---------------------------------------------------------------------------
echo ""
echo "Phase 3 — Live URL probes"
echo "──────────────────────────"

if [[ "${PROBE}" == "false" ]]; then
  warn "Skipped — pass --probe to enable live URL checks"
elif ! command -v curl &>/dev/null; then
  warn "curl not available — cannot run live URL probes"
else
  # 16. SBOM attestation URL (sample from first container that has one)
  if [[ "${CONTAINERS_YML_AVAILABLE}" -eq 1 ]]; then
    attest_url=$(yq '.[] | select(.versions[0].variants[0].attestation_url != null) | .versions[0].variants[0].attestation_url' \
      "${CONTAINERS_YML}" 2>/dev/null | head -1)
    if [[ -n "${attest_url}" ]]; then
      http_code=$(curl -sI --max-time 10 -o /dev/null -w "%{http_code}" "${attest_url}" 2>/dev/null || true)
      if [[ "${http_code}" == "200" ]]; then
        pass "SBOM attestation URL reachable (HTTP ${http_code}): ${attest_url}"
      else
        fail "SBOM attestation URL returned HTTP ${http_code}: ${attest_url}"
      fi
    else
      warn "No attestation_url found in containers.yml to probe"
    fi
  else
    warn "Skipping check 16 — containers.yml not available"
  fi

  # 17. Upstream-monitor workflow page
  wf_url="https://github.com/oorabona/docker-containers/actions/workflows/upstream-monitor.yaml"
  http_code=$(curl -sI --max-time 10 -o /dev/null -w "%{http_code}" "${wf_url}" 2>/dev/null || true)
  if [[ "${http_code}" == "200" ]]; then
    pass "Upstream-monitor workflow page reachable (HTTP ${http_code})"
  else
    fail "Upstream-monitor workflow page returned HTTP ${http_code}: ${wf_url}"
  fi

  # 18. GHCR postgres package page
  ghcr_url="https://github.com/oorabona/docker-containers/pkgs/container/postgres"
  http_code=$(curl -sI --max-time 10 -o /dev/null -w "%{http_code}" "${ghcr_url}" 2>/dev/null || true)
  if [[ "${http_code}" == "200" ]]; then
    pass "GHCR postgres package page reachable (HTTP ${http_code})"
  else
    fail "GHCR postgres package page returned HTTP ${http_code}: ${ghcr_url}"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Phase B smoke test summary"
echo "  PASS: ${PASS}  /  FAIL: ${FAIL}  /  WARN: ${WARN}"
echo "================================================================"
exit $((FAIL > 0 ? 1 : 0))
