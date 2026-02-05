# Project Backlog

## In Progress

(none)

## Pending

(none)

## Blocked / Deferred

- [ ] ⏸️ [Build] PG 18 distributed/full flavors — blocked on Citus PG 18 compatibility (upstream)
- [-] ⏭️ [Build] _has_build_args_include() only checks first variant (head -1) — low risk, all current containers have consistent structure
- [-] ⏭️ [Dashboard] Build history — show last N builds per variant (wait for SBOM data accumulation + format stabilization)
- [-] ⏭️ [Dashboard] Changelog inter-versions — diff extensions/tools between builds (leverage SBOM attestations via sbomdiff/docker scout compare)

## Completed

- [x] ✅ [CI] Per-container failure tracking via GitHub API in dashboard (2026-02-05)
- [x] ✅ [CI] Build failure alerts — auto-create GitHub issue on failure (2026-02-05)
- [x] ✅ [Build] EXT-BUNDLE — template-based Dockerfile generation for per-flavor extension filtering (2026-02-02)
- [x] ✅ [Build] Align built-in extensions in 00-init-extensions.sql + eliminate config.yaml mismatch (2026-02-03)
- [x] ✅ [Test] Add bats tests for dashboard helpers and variant-utils (33 tests) (2026-02-02)
- [x] ✅ [Dashboard] Fix version mismatch check for rolling tags — major version comparison instead of prefix match (2026-02-02)
- [x] ✅ [CI] Fix `[[ ]] &&` false failure pattern in build scripts (2026-02-05)
- [x] ✅ [CI] Add dashboard + auto-build triggers to upstream-monitor (2026-02-05)

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
