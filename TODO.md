# Project Backlog

## In Progress

_No tasks currently in progress_

## Pending

### High Priority

_No high priority tasks remaining_

### Medium Priority

- [ ] CI: Add shellcheck validation to CI pipeline (F-003 from CI-MAKE-BUILD review)
- [ ] CI: Standardize all containers with `build` scripts (Phase 2)
- [ ] CI: Pin base image SHA digests for reproducible builds (Phase 2)
- [ ] CI: Evaluate `skopeo copy` for Docker Hub push (Phase 2)
- [ ] CI: Lineage JSON output from ./make build (Phase 3)
- [ ] CI: Dashboard integration for build lineage (Phase 3)

### Low Priority

- [ ] gh-pages: Add aria-live regions for dynamic feedback (F-005)
- [ ] gh-pages: Refactor inline onclick to addEventListener (F-006)
- [ ] gh-pages: Wrap JS in IIFE/module pattern (F-007)
- [ ] gh-pages: Increase mobile touch targets to 44px (F-011)

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
