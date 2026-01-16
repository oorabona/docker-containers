# Project Backlog

## In Progress

_No tasks currently in progress_

## Pending

### High Priority

_No high priority tasks remaining_

### Medium Priority

- [ ] Improve CI build caching - persistent BuildKit cache, registry layer cache
- [ ] Build notifications - Slack/Discord/email alerts on failures, daily digest
- [ ] Improve test coverage for build scripts
- [ ] Document container configuration options

### Low Priority

- [ ] Registry cleanup automation - remove old tags, keep N latest versions
- [ ] E2E container tests - start container, verify service, stop
- [ ] Consolidate duplicate shell functions
- [ ] Add container size optimization

## Completed

- [x] ✅ Add container health checks - added HEALTHCHECK to sslh, verified 9/9 containers (2026-01-16)
- [x] ✅ Auto-PR for upstream updates - already implemented in upstream-monitor.yaml (2026-01-16)
- [x] ✅ Review and stabilize upstream-monitor workflow - fix checkout@v6 bug, fix jq interpolation (2026-01-16)
- [x] ✅ Fix multi-arch manifest creation - explicit BUILD_PLATFORM export in composite action (2026-01-16)
- [x] ✅ Resilient multi-registry push (GHCR primary, Docker Hub secondary) (2026-01-16)
- [x] ✅ Security scanning with Trivy - CVE scanning, blocks on CRITICAL, SARIF reports (2026-01-16)
- [x] ✅ Project initialized with /project-init (2026-01-16)
- [x] ✅ Remove deprecated buildx install option (2026-01-16)

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
