# Project Backlog

## In Progress

- [x] ✅ [Testing] Build standalone test harness with TAP/table/JSON reporters — Priority: M (2026-02-23)

## Pending

- [ ] 🔧 [Security] Purge sslh/nginx-selfsigned.key from git history (git filter-repo) — Priority: L (from /review F-001, dev-only self-signed cert)
- [ ] 🔧 [Security] Add sha256sum verification for yq binary downloads in CI workflows — Priority: L (from /review F-002, pre-existing)

- [x] ✅ [Postgres] runtime_deps field in extensions/config.yaml is declared but never consumed by build tooling — Priority: M (from /review F-001) (2026-02-23)
- [x] ✅ [Docs] Update README.md flavor table to reflect new extensions and spatial flavor — Priority: M (from /review F-004) (2026-02-23)
- [x] ✅ [Postgres] ParadeDB builder image is ~11.4 GB — consider multi-stage with scratch output stage — Priority: L (from /review F-005) (2026-02-23)
- [x] ✅ [Postgres] Fix Citus --without-libcurl build flag causing runtime symbol resolution failure — Priority: H (2026-02-23)
- [x] ✅ [Postgres] Fix ARG MAJOR_VERSION scoping in 9 extension Dockerfiles (empty metadata) — Priority: L (2026-02-23)
- [x] ✅ [Postgres] Update test.sh with pg_cron, pg_ivm, postgis tests and spatial flavor — Priority: M (2026-02-23)

- [ ] 💡 [Testing] Add README.md for test-harness/ (usage examples, API reference) — Priority: L (from plan checkpoint)
- [ ] 💡 [Testing] Integrate test-harness into CI pipeline (auto-build.yaml) — Priority: L (from plan checkpoint)

## Blocked / Deferred

(none)

## Completed

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
