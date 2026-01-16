# Project Backlog

## In Progress

- [ ] 🟡 Resilient multi-registry push (GHCR primary, Docker Hub secondary) — platform suffix bug in progress

## Pending

### High Priority

- [ ] Security scanning with Trivy - scan images for CVE vulnerabilities, block critical issues
- [ ] Auto-PR for upstream updates - create PR automatically when new versions detected
- [ ] Fix multi-arch manifest creation - platform suffix tags not being created correctly
- [ ] Review and stabilize upstream-monitor workflow
- [ ] Add container health checks to all images (HEALTHCHECK in Dockerfiles)

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

- [x] ✅ Project initialized with /project-init (2026-01-16)
- [x] ✅ Resilient push infrastructure - separate GHCR/Docker Hub functions (2026-01-16)
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
