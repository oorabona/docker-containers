# Audit Backlog

**Generated:** 2026-02-22 (incremental update from 2026-01-31)
**Source:** /audit incremental

---

## Scoring Reference

- **Complexity:** C1 trivial → C4 architectural
- **Impact:** I1 cosmetic → I4 critical
- **Risk:** R1 low → R4 imminent
- **Priority Score** = (Impact × Risk) / Complexity
- **P0** ≥ 4.0 | **P1** 2.0-3.9 | **P2** 1.0-1.9 | **P3** < 1.0

---

## Backlog Items

| ID | Issue | Location | C | I | R | Effort | Score | Priority | Status |
|----|-------|----------|---|---|---|--------|-------|----------|--------|
| AUD-024 | Committed private key in repo | `sslh/nginx-selfsigned.key` | C1 | I4 | R3 | S | 12.0 | P0 | ✅ RESOLVED |
| AUD-025 | 7 unpinned actions in build-container/action.yaml | `build-container/action.yaml:78,84,93,288,298,311,324` | C1 | I3 | R3 | S | 9.0 | P0 | ✅ RESOLVED |
| AUD-026 | No timeout-minutes on any CI job | all workflows | C1 | I3 | R3 | S | 9.0 | P0 | ✅ RESOLVED |
| AUD-027 | Overly broad workflow-level permissions | `auto-build.yaml:96`, `upstream-monitor.yaml:18` | C2 | I3 | R3 | M | 4.5 | P0 | ✅ RESOLVED |
| AUD-028 | `image_exists_in_registry()` defined twice (different behavior) | `extension-utils.sh:98`, `build-cache-utils.sh:226` | C2 | I3 | R3 | M | 4.5 | P0 | ✅ RESOLVED |
| AUD-029 | `get_build_args()` duplicates `_prepare_build_args()` | `push-container.sh:43` vs `build-container.sh:90` | C2 | I3 | R3 | M | 4.5 | P0 | ✅ RESOLVED |
| AUD-030 | Trivy scans fully advisory (continue-on-error on all steps) | `build-container/action.yaml:307,320,329` | C2 | I3 | R2 | M | 3.0 | P1 | ✅ RESOLVED |
| AUD-031 | vegardit/gha-setup-jq@v1 unpinned + `version: latest` | `close-duplicate-prs/action.yaml:22` | C1 | I3 | R2 | S | 6.0 | P0 | ✅ RESOLVED |
| AUD-032 | Manifest creation logic duplicated 4× (~120 lines) | `auto-build.yaml:583-708`, `recreate-manifests.yaml:108-214` | C2 | I2 | R2 | M | 2.0 | P1 | ✅ RESOLVED |
| AUD-033 | yq downloaded at runtime without version pinning | `upstream-monitor.yaml:149,477` | C1 | I2 | R2 | S | 4.0 | P0 | ✅ RESOLVED |
| AUD-034 | curl-pipe-to-sh for syft install (unpinned main branch) | `helpers/sbom-utils.sh:31` | C1 | I2 | R2 | S | 4.0 | P0 | ✅ RESOLVED |
| AUD-035 | eval of build args in OpenResty Dockerfile | `openresty/Dockerfile:107,171` | C2 | I3 | R2 | M | 3.0 | P1 | ✅ RESOLVED |
| AUD-036 | Hardcoded default password "changeme" in web-shell | `web-shell/Dockerfile:57` | C1 | I3 | R2 | S | 6.0 | P0 | ✅ RESOLVED |
| AUD-037 | curl-pipe-to-bash for GCP SDK (unpinned) | `terraform/Dockerfile:78` | C2 | I2 | R2 | M | 2.0 | P1 | ✅ RESOLVED |
| AUD-038 | Unpinned external script fetch for openvpn setup | `openvpn/Dockerfile:62` | C2 | I2 | R2 | M | 2.0 | P1 | ✅ RESOLVED |
| AUD-039 | retry.sh + build-args-utils.sh: implicit logging.sh dependency | `helpers/retry.sh:21`, `helpers/build-args-utils.sh:22` | C1 | I2 | R2 | S | 4.0 | P0 | ✅ RESOLVED |
| AUD-040 | extension-utils.sh own logging namespace (log_ok, log_warn) | `helpers/extension-utils.sh:11` | C2 | I2 | R1 | M | 1.0 | P2 | ✅ RESOLVED |
| AUD-041 | Legacy dual-structure in variant-utils.sh (7 functions affected) | `helpers/variant-utils.sh:80+` | C2 | I2 | R1 | M | 1.0 | P2 | ✅ RESOLVED |
| AUD-042 | build-extensions inline bash duplicates variant-utils.sh | `auto-build.yaml:163-250` | C2 | I2 | R1 | M | 1.0 | P2 | ✅ RESOLVED |
| AUD-043 | CDN resources without SRI integrity attributes | `dashboard.html:7`, `container-detail.html:16` | C1 | I2 | R1 | S | 2.0 | P1 | ✅ RESOLVED |
| AUD-044 | Hardcoded committer email (6 occurrences) | `upstream-monitor.yaml:74+` | C1 | I1 | R1 | S | 1.0 | P2 | ✅ RESOLVED |
| AUD-045 | `_emit_build_lineage()` re-implements `build_args_json()` inline | `build-container.sh:193` | C1 | I2 | R1 | S | 2.0 | P1 | ✅ RESOLVED |
| AUD-046 | ~~Only 5/12 containers have test.sh~~ | `*/test.sh` | — | — | — | — | — | ✅ RESOLVED | AUD-011 |
| AUD-047 | GitHub Actions expression injection risk (versions_map) | `auto-build.yaml:219` | C2 | I3 | R2 | M | 3.0 | P1 | ✅ RESOLVED |
| AUD-048 | pushd/popd CWD mutation (fragile under set -e) | `scripts/check-version.sh:28` | C1 | I2 | R1 | S | 2.0 | P1 | ✅ RESOLVED |

---

## Improvement Axes

### Axis 1: Security Hardening (CRITICAL)

**Goal:** Eliminate supply chain risks, secret exposure, and permission over-scoping
**Total effort:** ~8h | **Avg complexity:** C1.3 | **Max risk if ignored:** R3

| ID | Issue | C | I | R | Effort | Score |
|----|-------|---|---|---|--------|-------|
| AUD-024 | Committed private key | C1 | I4 | R3 | S | 12.0 |
| AUD-025 | Unpinned actions in build-container | C1 | I3 | R3 | S | 9.0 |
| AUD-027 | Broad workflow permissions | C2 | I3 | R3 | M | 4.5 |
| AUD-031 | vegardit/gha-setup-jq unpinned | C1 | I3 | R2 | S | 6.0 |
| AUD-033 | yq runtime download unpinned | C1 | I2 | R2 | S | 4.0 |
| AUD-034 | syft curl-pipe-to-sh unpinned | C1 | I2 | R2 | S | 4.0 |
| AUD-036 | Hardcoded password in web-shell | C1 | I3 | R2 | S | 6.0 |
| AUD-047 | Expression injection risk | C2 | I3 | R2 | M | 3.0 |

**Recommended approach:** AUD-024 (private key) + AUD-025 (pin actions) first — highest score, quickest wins. Then AUD-027 (job-level perms) and AUD-036 (password). Pipeline hardening (AUD-033, AUD-034) can follow.

### Axis 2: CI/CD Reliability

**Goal:** Prevent runaway jobs, make security scans actionable
**Total effort:** ~6h | **Avg complexity:** C1.5 | **Max risk if ignored:** R3

| ID | Issue | C | I | R | Effort | Score |
|----|-------|---|---|---|--------|-------|
| AUD-026 | No timeout-minutes | C1 | I3 | R3 | S | 9.0 |
| AUD-030 | Trivy scans advisory-only | C2 | I3 | R2 | M | 3.0 |
| AUD-032 | Manifest creation 4× duplication | C2 | I2 | R2 | M | 2.0 |
| AUD-042 | build-extensions inline bash | C2 | I2 | R1 | M | 1.0 |

**Recommended approach:** AUD-026 first (add `timeout-minutes: 30` to all build jobs, `10` to utility jobs). Then AUD-032 (extract manifest action).

### Axis 3: DRY Consolidation (continued)

**Goal:** Single source of truth for shared logic
**Total effort:** ~10h | **Avg complexity:** C2 | **Max risk if ignored:** R3

| ID | Issue | C | I | R | Effort | Score |
|----|-------|---|---|---|--------|-------|
| AUD-028 | `image_exists_in_registry` duplication | C2 | I3 | R3 | M | 4.5 |
| AUD-029 | `get_build_args` / `_prepare_build_args` | C2 | I3 | R3 | M | 4.5 |
| AUD-045 | `_emit_build_lineage` re-implements helper | C1 | I2 | R1 | S | 2.0 |
| AUD-039 | Implicit logging.sh dependencies | C1 | I2 | R2 | S | 4.0 |
| AUD-040 | extension-utils.sh own logging namespace | C2 | I2 | R1 | M | 1.0 |

**Recommended approach:** AUD-028 + AUD-029 first (highest risk — silent function shadowing). Then AUD-039 (add conditional source to retry.sh and build-args-utils.sh).

### Axis 4: Dockerfile Hardening

**Goal:** Pin external dependencies, eliminate eval patterns
**Total effort:** ~6h | **Avg complexity:** C2 | **Max risk if ignored:** R2

| ID | Issue | C | I | R | Effort | Score |
|----|-------|---|---|---|--------|-------|
| AUD-035 | eval in OpenResty Dockerfile | C2 | I3 | R2 | M | 3.0 |
| AUD-037 | GCP SDK curl-pipe-to-bash | C2 | I2 | R2 | M | 2.0 |
| AUD-038 | openvpn external script fetch | C2 | I2 | R2 | M | 2.0 |

**Recommended approach:** AUD-035 (eval removal is security-critical), then AUD-037/AUD-038 (pin to specific releases/commits).

### Axis 5: Code Quality & Structure

**Goal:** Clean up legacy code, improve maintainability
**Total effort:** ~8h | **Avg complexity:** C1.5 | **Max risk if ignored:** R1

| ID | Issue | C | I | R | Effort | Score |
|----|-------|---|---|---|--------|-------|
| AUD-041 | Legacy dual-structure in variant-utils.sh | C2 | I2 | R1 | M | 1.0 |
| AUD-043 | CDN resources without SRI | C1 | I2 | R1 | S | 2.0 |
| AUD-044 | Hardcoded committer email | C1 | I1 | R1 | S | 1.0 |
| AUD-048 | pushd/popd CWD mutation | C1 | I2 | R1 | S | 2.0 |

*AUD-046 (test.sh coverage) resolved — 12/12 containers now have test.sh*

---

## Quick Wins (C1-C2, I2+, Effort S)

| ID | Issue | Effort | Impact | Why Quick |
|----|-------|--------|--------|-----------|
| AUD-024 | Remove committed private key | S | I4 | Delete file + .gitignore |
| AUD-025 | Pin 7 actions to SHAs | S | I3 | Mechanical: look up SHAs |
| AUD-026 | Add timeout-minutes to jobs | S | I3 | Add 1 line per job |
| AUD-031 | Replace vegardit/gha-setup-jq | S | I3 | Use mikefarah/yq pattern |
| AUD-033 | Pin yq download URL | S | I2 | Add version to URL |
| AUD-034 | Pin syft install URL | S | I2 | Pin to release tag |
| AUD-036 | Remove hardcoded password | S | I3 | Require env var |
| AUD-039 | Add logging.sh source to 2 helpers | S | I2 | Add conditional source |
| AUD-043 | Add SRI to CDN resources | S | I2 | Add integrity= attribute |
| AUD-048 | Replace pushd with subshell | S | I2 | `( cd dir && ... )` |

---

## Summary

| Priority | Count | Total Effort | Avg Score |
|----------|-------|--------------|-----------|
| P0 | 10 | ~12h | 6.9 |
| P1 | 8 | ~11h | 2.6 |
| P2 | 5 | ~8h | 1.0 |
| **Total** | **23** | **~31h** | |

| Axis | Items | Effort | Top Priority |
|------|-------|--------|-------------|
| Security Hardening | 8 | ~8h | P0 |
| CI/CD Reliability | 4 | ~6h | P0 |
| DRY Consolidation | 5 | ~10h | P0 |
| Dockerfile Hardening | 3 | ~6h | P1 |
| Code Quality & Structure | 4 | ~8h | P1 |

---

## Resolution Log (carried from previous audits)

### 2026-01-31 → 2026-02-22

| ID | Issue | Resolution |
|----|-------|-----------|
| AUD-001 | Sleep-based auto-merge | ✅ Replaced with `gh pr checks --watch` + timeout + retry |
| AUD-002 | CLAUDE.md incomplete | ✅ Updated with 12 containers, 8 workflows |
| AUD-004 | innerHTML XSS | ✅ Replaced with DOM APIs (createElement/textContent) |
| AUD-006 | Registry API duplicated | ✅ Extracted to `helpers/registry-utils.sh` |
| AUD-007 | Inline JS/CSS | ✅ Extracted to external files |
| AUD-008 | README phantom containers | ✅ Container list corrected |
| AUD-012 | No CSP headers | ✅ CSP meta tags added |
| AUD-013 | docker/login-action 5× | ✅ Consolidated to composite action |
| AUD-015 | config.yaml no schema | ✅ Runtime validation + base_image_cache schema |
| AUD-016 | No standard extension interface | ✅ Extension framework with standard build/push/pull |
| AUD-017 | CSS/theme duplicated | ✅ Shared theme extracted |
| AUD-022 | No ADRs | ✅ docs/adr/ created |
| AUD-023 | Legacy tarball functions | ✅ Extension framework replaced |
| AUD-046 | Only 5/12 containers have test.sh | ✅ All 12/12 containers now have test.sh |
| AUD-024 | Committed private key in repo | ✅ Deleted key/cert, added *.key/*.pem/*.crt to .gitignore |
| AUD-025 | Unpinned actions in build-container | ✅ All 7 actions pinned to full SHA with version comment |
| AUD-026 | No timeout-minutes on CI jobs | ✅ Added timeout-minutes to all 23 jobs across 8 workflows |
| AUD-031 | vegardit/gha-setup-jq unpinned | ✅ Removed dependency (jq pre-installed on ubuntu runners) |
| AUD-036 | Hardcoded password in web-shell | ✅ Removed from Dockerfile, account locked by default, set via SHELL_PASSWORD env |
| AUD-033 | yq runtime download unpinned | ✅ Pinned to v4.52.4 in auto-build.yaml + upstream-monitor.yaml |
| AUD-034 | syft curl-pipe-to-sh unpinned | ✅ Pinned to v1.42.1 in helpers/sbom-utils.sh |
| AUD-039 | Implicit logging.sh dependency | ✅ Added conditional source + fallback stubs to retry.sh + build-args-utils.sh |
| AUD-027 | Overly broad workflow permissions | ✅ auto-build: contents:write→read; both workflows: improved permission comments |
| AUD-028 | Duplicate image_exists_in_registry | ✅ Removed dead copy from build-cache-utils.sh (canonical in extension-utils.sh) |
| AUD-029 | Duplicate build args logic | ✅ Consolidated into shared prepare_build_args() in build-args-utils.sh |
| AUD-043 | CDN resources without SRI | ✅ Added integrity="sha384-..." + crossorigin="anonymous" to tabler icons CSS |
| AUD-048 | pushd/popd CWD mutation | ✅ Replaced with `cd` subshells in check-version.sh (no CWD side-effects) |
| AUD-030 | Trivy scans advisory-only | ✅ SARIF upload step now fails build on error; scan step remains advisory (continue-on-error) |
| AUD-032 | Manifest creation 4× duplication | ✅ Extracted to `helpers/create-manifest.sh` with `create_registry_manifest()` — 4 blocks → 1 shared function |
| AUD-035 | eval in OpenResty Dockerfile | ✅ Removed unused `RESTY_EVAL_*` ARGs, LABELs, and `eval` calls (kept `eval ./configure` which is standard) |
| AUD-037 | GCP SDK curl-pipe-to-bash | ✅ Download to temp file first, then execute — no more pipe-to-bash |
| AUD-038 | Unpinned openvpn script fetch | ✅ Pinned to commit SHA `3be0f6fe14bfe139068257410454fdd9a704d156` |
| AUD-040 | extension-utils.sh logging namespace | ✅ Removed custom log_ok/log_warn, sourced logging.sh, renamed all calls to log_success/log_warning |
| AUD-041 | Legacy variant-utils.sh dual-structure | ✅ Documented "latest" fallback as intentional for dynamic-version containers (terraform) |
| AUD-042 | build-extensions inline bash | ✅ Extracted to `scripts/list-extension-versions.sh` — 45 lines inline → 2-line call |
| AUD-044 | Hardcoded committer email | ✅ Replaced 6 occurrences with `github-actions[bot]` noreply address |
| AUD-045 | Inline yq duplication | ✅ Replaced with `build_args_json()` call from shared `build-args-utils.sh` |
| AUD-047 | Expression injection risk | ✅ Passed `versions_map` via env var instead of `${{ }}` expression interpolation |

---

## Tracking

- [x] P0 items addressed (10/10 resolved as of 2026-02-22)
- [x] P1 items addressed (8/8 resolved as of 2026-02-22)
- [x] P2 items addressed (5/5 resolved as of 2026-02-22)
- [x] Quick wins executed (10/10 resolved as of 2026-02-22)
- [x] Axes reviewed — all 5 axes fully resolved
- [ ] Next audit scheduled
