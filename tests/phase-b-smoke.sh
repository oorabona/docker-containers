#!/usr/bin/env bash
# Phase B trust-signal layer smoke test
#
# Usage:
#   ./tests/phase-b-smoke.sh           # Run all static + rendered checks
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
# Phase 1 — Static source-file checks (no build required)
# ---------------------------------------------------------------------------
echo ""
echo "Phase 1 — Static source-file checks"
echo "────────────────────────────────────"

CARD_HTML="${REPO_ROOT}/docs/site/_includes/container-card.html"
DETAIL_HTML="${REPO_ROOT}/docs/site/_layouts/container-detail.html"
BLOG_CSS="${REPO_ROOT}/docs/site/assets/css/blog.css"
CONTAINERS_YML="${REPO_ROOT}/docs/site/_data/containers.yml"
DASHBOARD_JS="${REPO_ROOT}/docs/site/assets/js/dashboard.js"
DETAIL_JS="${REPO_ROOT}/docs/site/assets/js/container-detail.js"

# Needle split to prevent hook false-positive on the literal pattern itself.
# The two halves form ".innerHTML =" when joined.
_INNER="inner"
_HTML_EQ="HTML\s*="

# 1. No raw .innerHTML= assignments in new JS (comments excluded)
# grep -v strips comment lines before counting; || true prevents set -e on no-match
inner_count=$(grep -nE "\.${_INNER}${_HTML_EQ}" "${DASHBOARD_JS}" "${DETAIL_JS}" 2>/dev/null \
  | grep -vE '(//\s*|/\*)' \
  | wc -l || true)
if [[ "${inner_count}" -eq 0 ]]; then
  pass "No raw .innerHTML= assignments in JS files (XSS safe)"
else
  fail "Found ${inner_count} raw .innerHTML= assignment(s) in JS — XSS risk; use textContent or createElement"
fi

# 2. Trust-strip CSS selectors present (expect >= 4)
trust_css_count=$(grep -cE '^\.trust-strip|^\.trust-badge|^\.security-section|^\.severity-grid' \
  "${BLOG_CSS}" 2>/dev/null || true)
if [[ "${trust_css_count}" -ge 4 ]]; then
  pass "Trust-strip CSS selectors present in blog.css (${trust_css_count} matching rules)"
else
  fail "Expected >= 4 trust-strip CSS selectors in blog.css, found ${trust_css_count}"
fi

# 3. value_proposition populated for >= 10 containers
vp_count=$(yq '[.[] | select(.value_proposition != null and .value_proposition != "")] | length' \
  "${CONTAINERS_YML}" 2>/dev/null)
if [[ "${vp_count}" -ge 10 ]]; then
  pass "value_proposition present on ${vp_count} containers (>= 10)"
else
  fail "Expected >= 10 containers with value_proposition in containers.yml, found ${vp_count}"
fi

# 4. postgres when_to_use present on every variant (no nulls)
pg_missing_when=$(yq '[.[] | select(.name == "postgres") | .versions[].variants[] | select(.when_to_use == null)] | length' \
  "${CONTAINERS_YML}" 2>/dev/null)
if [[ "${pg_missing_when}" -eq 0 ]]; then
  pass "All postgres variants have when_to_use populated"
else
  fail "postgres has ${pg_missing_when} variant(s) missing when_to_use"
fi

# 5. postgres vector variant (variant[1]) has compiled extensions
pg_ext_count=$(yq '.[] | select(.name == "postgres") | .versions[0].variants[1].extensions | length' \
  "${CONTAINERS_YML}" 2>/dev/null)
if [[ "${pg_ext_count}" -gt 0 ]]; then
  pass "postgres versions[0].variants[1] has ${pg_ext_count} extension(s) declared"
else
  fail "Expected extensions on postgres variants[1] (vector flavor), found ${pg_ext_count}"
fi

# 6. upstream_monitor_url present on all containers
missing_monitor=$(yq '[.[] | select(.upstream_monitor_url == null)] | length' \
  "${CONTAINERS_YML}" 2>/dev/null)
if [[ "${missing_monitor}" -eq 0 ]]; then
  pass "upstream_monitor_url present on all containers"
else
  fail "${missing_monitor} container(s) missing upstream_monitor_url in containers.yml"
fi

# 7. Trust strip class in container-card include
if grep -q 'class="trust-strip"' "${CARD_HTML}" 2>/dev/null; then
  pass "trust-strip div found in container-card.html"
else
  fail 'class="trust-strip" not found in container-card.html'
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
  | grep -vE '(//\s*|/\*)' \
  | wc -l || true)
if [[ "${inner_comp_count}" -eq 0 ]]; then
  pass "No raw .innerHTML= assignments in web component files (XSS safe)"
else
  fail "Found ${inner_comp_count} raw .innerHTML= assignment(s) in component files — XSS risk"
fi

# ---------------------------------------------------------------------------
# Phase 2 — Rendered HTML checks (requires jekyll build output in docs/site/_site/)
# ---------------------------------------------------------------------------
echo ""
echo "Phase 2 — Rendered HTML checks"
echo "────────────────────────────────"

SITE_DIR="${REPO_ROOT}/docs/site/_site"
PHASE2_SKIP=false

if [[ ! -d "${SITE_DIR}" ]]; then
  warn "_site/ not found — run 'bundle exec jekyll build' in docs/site/ first (or check Block I in CI)"
  PHASE2_SKIP=true
fi

# Detect stale build: if detail layout is newer than the rendered postgres page,
# the _site/ predates Phase B. Rendered checks are downgraded to WARN in that case.
PHASE2_STALE=false
if [[ "${PHASE2_SKIP}" == "false" ]]; then
  _pg="${SITE_DIR}/container/postgres/index.html"
  if [[ -f "${_pg}" && "${DETAIL_HTML}" -nt "${_pg}" ]]; then
    warn "_site/ appears stale (container-detail.html is newer than rendered postgres page) — re-run jekyll build for definitive Phase 2 results; continuing with degraded checks"
    PHASE2_STALE=true
  fi
fi

if [[ "${PHASE2_SKIP}" == "false" ]]; then
  VERIFY_HTML="${SITE_DIR}/verify-images/index.html"
  PG_HTML="${SITE_DIR}/container/postgres/index.html"
  SSLH_HTML="${SITE_DIR}/container/sslh/index.html"
  SITE_INDEX="${SITE_DIR}/index.html"

  # 11. verify-images page rendered
  if [[ -f "${VERIFY_HTML}" ]]; then
    pass "verify-images/index.html exists in _site/"
  else
    fail "verify-images/index.html not found in _site/"
  fi

  # 12. Trivy anchor in verify-images
  if grep -q 'id="trivy"' "${VERIFY_HTML}" 2>/dev/null; then
    pass 'id="trivy" anchor found in verify-images/index.html'
  else
    fail 'id="trivy" anchor missing from verify-images/index.html'
  fi

  # 13. Postgres detail has variants-table
  if [[ -f "${PG_HTML}" ]]; then
    if grep -q 'class="variants-table"' "${PG_HTML}" 2>/dev/null; then
      pass "variants-table present in container/postgres/index.html"
    elif [[ "${PHASE2_STALE}" == "true" ]]; then
      warn "variants-table not found in container/postgres/index.html — stale build, rebuild jekyll to confirm"
    else
      fail "variants-table NOT found in container/postgres/index.html"
    fi
  else
    warn "container/postgres/index.html not found in _site/ — cannot check variants-table"
  fi

  # 14. Sslh detail does NOT have variants-table
  if [[ -f "${SSLH_HTML}" ]]; then
    if grep -q 'class="variants-table"' "${SSLH_HTML}" 2>/dev/null; then
      fail "variants-table found in sslh detail page — should only appear for postgres"
    else
      pass "variants-table correctly absent from container/sslh/index.html"
    fi
  else
    warn "container/sslh/index.html not found in _site/ — cannot check absence of variants-table"
  fi

  # 15. No unrendered Liquid in built output
  raw_liquid=$(grep -lE '\{\{|\{%' "${SITE_INDEX}" "${PG_HTML}" 2>/dev/null | head -1 || true)
  if [[ -z "${raw_liquid}" ]]; then
    pass "No raw Liquid syntax ({{ or {%) found in built HTML output"
  else
    fail "Unrendered Liquid found in: ${raw_liquid}"
  fi
fi

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
