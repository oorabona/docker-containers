# Project Backlog

## In Progress

- [x] ✅ [Infra] Architecture review improvements (COPY --chmod, OCI labels, cache mounts, JS dedup, logging tests) (2026-02-25)

## Pending

- [ ] 🔧 [CI] Standardize actions/cache version (v4 in build-container vs v5 in workflows) — Priority: M
- [ ] 🔧 [CI] Update anchore/sbom-action from v0.22.2 to v0.24.0 — Priority: L
- [ ] 💡 [Dashboard] Build trend visualization — capture duration_seconds + status in history, add Chart.js charts on detail pages — Priority: M
- [-] ⏭️ [Testing] Integrate test-harness into CI pipeline (auto-build.yaml) — Priority: L (deferred: low value vs complexity of docker load/pull in CI, local tests suffice)

## Completed

- [x] ✅ [Security] Purge sslh/nginx-selfsigned.key from git history (git filter-repo) (2026-02-23)
- [x] ✅ [Security] Add sha256sum verification for yq binary downloads in CI workflows (2026-02-23)
- [x] ✅ [Testing] Add README.md for test-harness/ (usage examples, API reference) (2026-02-23)

## Blocked / Deferred

- [-] ⏭️ [Security] Jekyll non-root user — breaking change risk (volume permissions), needs migration plan — Priority: L
- [-] ⏭️ [Infra] apk/apt BuildKit cache mounts — marginal benefit vs complexity — Priority: L
- [x] ✅ [Infra] Add `org.opencontainers.image.licenses` to all Dockerfile LABEL blocks (2026-02-25)
- [x] ✅ [Dashboard] `window.ThemeManager` namespace for theme.js globals (2026-02-25)

## Completed (older)

(Archived → docs/historic/done-2026-02.md)

---

## Task Status Legend

| Marker | Status |
|--------|--------|
| `🟡` | In Progress |
| `✅` | Done (with date) |
| `⏸️` | Blocked (with reason) |
| `⏭️` | Deferred |
| `➡️` | Moved to another backlog |
| `🔗` | Duplicate of another task |
