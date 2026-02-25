# Project Backlog

## In Progress

- [x] ✅ [Infra] Architecture review improvements (COPY --chmod, OCI labels, cache mounts, JS dedup, logging tests) (2026-02-25)

## Pending

- [-] ⏭️ [Testing] Integrate test-harness into CI pipeline (auto-build.yaml) — Priority: L (deferred: low value vs complexity of docker load/pull in CI, local tests suffice)

## Completed

- [x] ✅ [Security] Purge sslh/nginx-selfsigned.key from git history (git filter-repo) (2026-02-23)
- [x] ✅ [Security] Add sha256sum verification for yq binary downloads in CI workflows (2026-02-23)
- [x] ✅ [Testing] Add README.md for test-harness/ (usage examples, API reference) (2026-02-23)

## Blocked / Deferred

- [-] ⏭️ [Security] Jekyll non-root user — breaking change risk (volume permissions), needs migration plan — Priority: L
- [-] ⏭️ [Infra] apk/apt BuildKit cache mounts — marginal benefit vs complexity — Priority: L
- [ ] 🔧 [Infra] Add `org.opencontainers.image.licenses` to all Dockerfile LABEL blocks — Priority: M (from /review F-004)
- [ ] 🔧 [Dashboard] Consider `window.ThemeManager` namespace for theme.js globals if third-party scripts are added — Priority: M (from /review F-006)

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
