# Project Backlog

## In Progress

_No tasks currently in progress_

## Pending

### High Priority

_All DASH tasks resolved — see Completed section_

## Completed

- [x] ✅ Add container size optimization - docs + ./make sizes command (2026-01-16)
- [x] ✅ Consolidate duplicate shell functions - helpers/retry.sh + logging.sh reuse (2026-01-16)
- [x] ✅ E2E container tests - refactored with ./make build + test.sh scripts (2026-01-16)
- [x] ✅ Registry cleanup automation - GHCR monthly cleanup workflow (2026-01-16)
- [x] ✅ Build notifications - GitHub default email notifications on failures (2026-01-16)
- [x] ✅ Improve test coverage for build scripts - 63 unit tests via bats-core (2026-01-16)
- [x] ✅ Document container configuration options - CONTAINER_CONFIG.md created (2026-01-16)
- [x] ✅ Improve CI build caching - registry cache via GHCR buildcache tag (2026-01-16)
- [x] ✅ Add container health checks - added HEALTHCHECK to sslh, verified 9/9 containers (2026-01-16)
- [x] ✅ Auto-PR for upstream updates - already implemented in upstream-monitor.yaml (2026-01-16)
- [x] ✅ Review and stabilize upstream-monitor workflow - fix checkout@v6 bug, fix jq interpolation (2026-01-16)
- [x] ✅ Fix multi-arch manifest creation - explicit BUILD_PLATFORM export in composite action (2026-01-16)
- [x] ✅ Resilient multi-registry push (GHCR primary, Docker Hub secondary) (2026-01-16)
- [x] ✅ Security scanning with Trivy - CVE scanning, blocks on CRITICAL, SARIF reports (2026-01-16)
- [x] ✅ Project initialized with /project-init (2026-01-16)
- [x] ✅ Remove deprecated buildx install option (2026-01-16)
- [x] ✅ gh-pages: Responsive design + WCAG 2.2 compliance (2026-01-29)
- [x] ✅ terraform: Implement flavors (base, aws, azure, gcp, full) - 84% size reduction for base (2026-01-29)
- [x] ✅ CI: Refactor composite action to use ./make build — fixes openresty CI failure, eliminates build logic divergence (2026-01-30)
- [x] ✅ CI: Add shellcheck validation to CI pipeline — .github/workflows/shellcheck.yaml (2026-01-30)
- [x] ✅ CI: Standardize all containers with build scripts — audit confirmed already done (openresty+terraform have custom scripts, rest use standard make flow) (2026-01-30)
- [x] ✅ CI: Pin base image SHA digests — resolve FROM variables via config.json/build args, label with org.opencontainers.image.base.digest (2026-01-30)
- [x] ✅ CI: Evaluate skopeo copy — implemented in push-container.sh, GHCR→DockerHub copy without rebuild, fallback to buildx (2026-01-30)
- [x] ✅ CI: Lineage JSON output — .build-lineage/<container>.json emitted per build, ./make lineage command added (2026-01-30)
- [x] ✅ CI: Dashboard integration for build lineage — build_digest + base_image fields in containers.yml (2026-01-30)
- [x] ✅ gh-pages: Add aria-live regions for dynamic feedback — status announcements for filters, copy, theme, registry (2026-01-30)
- [x] ✅ gh-pages: Refactor inline onclick to addEventListener — event delegation in dashboard.html + container-card.html (2026-01-30)
- [x] ✅ gh-pages: Wrap JS in IIFE/module pattern — dashboard.html + container.html scripts wrapped (2026-01-30)
- [x] ✅ Config harmonization — unified config.yaml for all 10 containers, replaces config.json/jq with config.yaml/yq, base_image templates, lineage from config.yaml (2026-01-31)
- [x] ✅ gh-pages: Increase mobile touch targets to 44px — theme toggle, filter/registry buttons, variant tags, copy button (2026-01-30)
- [x] ✅ AUD-P0: Fix 3 P0 audit items — DRY build-args-utils.sh, CI-aware auto-merge with timeout, remove AUTO_MERGE_TOKEN (2026-01-31)
- [x] ✅ AUD-006: Extract shared registry API utility — helpers/registry-utils.sh eliminates duplication between ./make and generate-dashboard.sh (2026-01-31)
- [x] ✅ AUD-007: Extract inline JS/CSS from layouts — 4 external files, 86% layout reduction, removed unsafe-inline from script-src CSP (2026-01-31)
- [x] ✅ AUD-009: Split generate_data() — extracted github_api_get, calculate_build_success_rate, fetch_recent_activity, write_stats_file (2026-01-31)
- [x] ✅ AUD-011: Add test.sh for 6 containers — ansible, debian, jekyll, openvpn, terraform, wordpress (2026-01-31)
- [x] ✅ AUD-014: Fix schedule documentation — corrected cron from twice-daily to daily in GITHUB_ACTIONS.md (2026-01-31)
- [x] ✅ AUD-013: DRY docker/login-action — composite action replaces 5 duplicated login steps in auto-build.yaml (2026-01-31)
- [x] ✅ AUD-017: Extract shared CSS theme — theme.css with ~230 shared lines, dashboard.css and container-detail.css deduplicated (2026-01-31)
- [x] ✅ AUD-018: Extract version detection helper — helpers/version-utils.sh replaces 3× duplicated registry pattern logic (2026-01-31)
- [x] ✅ AUD-010: Split build_container() — 252→87 lines, extracted 5 focused helpers (_resolve_platforms, _configure_cache, etc.) (2026-01-31)
- [x] ✅ AUD-015: Rewrite WORKFLOW_ARCHITECTURE.md — 456→235 lines, reflects actual CI/CD architecture (2026-01-31)
- [x] ✅ AUD-022: Create ADRs — 4 Architecture Decision Records (native runners, smart rebuild, variant system, lineage) (2026-01-31)
- [x] ✅ DASH-001: Per-variant build_args for non-versioned variants — fixed in DASH-003 refactor, unified collect_variant_json() handles both paths (2026-01-31)
- [x] ✅ DASH-002: Per-variant build_digest "unknown" — root cause: missing lineage data (not code bug), same as DASH-004 (2026-01-31)
- [x] ✅ DASH-003: Refactor generate-dashboard.sh YAML generation — 924→743 lines, echo/heredoc replaced with jq+yq pipeline, variant data collected once (2026-01-31)
- [x] ✅ DASH-004: Postgres PG17/PG16 lineage files — investigated, not a code bug, lineage emission is per-variant correct, PG17/PG16 simply never built locally (2026-01-31)
- [x] ✅ DASH-005: Version mismatch check for non-versioned variants — fixed in DASH-003 refactor, resolve_variant_lineage_json() handles all paths (2026-01-31)

## Blocked / Deferred

_None_

---

## Scope-Specific Backlogs

_As scopes grow, create dedicated TODO_<SCOPE>.md files:_
- `TODO_CONTAINERS.md` - Container-specific tasks
- `TODO_GITHUB_ACTIONS.md` - CI/CD workflow improvements
- `TODO_TESTING.md` - Test infrastructure

---

## Task Status Legend

| Marker | Status |
|--------|--------|
| `🟡` | In Progress |
| `✅` | Done (with date) |
| `⏸️` | Blocked (with reason) |
| `⏭️` | Skipped |
| `➡️` | Moved to another backlog |
| `🔗` | Duplicate of another task |
