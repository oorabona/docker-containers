# Project Backlog

## In Progress

(none)

## Pending

(none)

## Blocked / Deferred

- [x] ✅ [Build] PG 18 distributed/full flavors — Citus 14.0.0 released, variants added, build success (2026-02-21)
- [ ] 🐛 [CI] Docker Hub manifest creation fails silently — `docker buildx imagetools create` on Docker Hub sources returns error, GHCR manifests work fine. Docker Hub has arch-specific tags but no multi-arch manifest lists. Non-blocking (continue-on-error).
- [-] ⏭️ [Build] _has_build_args_include() only checks first variant (head -1) — low risk, all current containers have consistent structure
- [-] ⏭️ [Dashboard] Build history — show last N builds per variant (wait for SBOM data accumulation + format stabilization)
- [-] ⏭️ [Dashboard] Changelog inter-versions — diff extensions/tools between builds (leverage SBOM attestations via sbomdiff/docker scout compare)

## Completed

- [x] ✅ [CI] Fix merge race condition in upstream monitor — max-parallel + retry logic (2026-02-07)
- [x] ✅ [Container] web-shell — browser-based terminal on Debian base with ttyd (2026-02-06)
- [x] ✅ [Container] vector — observability pipeline with musl binary on Alpine (2026-02-06)
- [x] ✅ [Dashboard] Fix badge lines causing YAML array parse in description extraction (2026-02-06)
- [x] ✅ [Docs] Standardize README.md across all 10 containers (2026-02-06)
- [x] ✅ [Dashboard] Dependency Health section on container detail pages (2026-02-06)
- [x] ✅ [CI] 3rd party dependency version monitoring — DEP-MONITOR (2026-02-06)
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
