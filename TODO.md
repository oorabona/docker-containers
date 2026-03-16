# Project Backlog

## In Progress

(None)

## Completed (recent)

- [x] ✅ [Runner] Build github-runner container — 6 variants (3 OS × 2 flavors), Linux+Windows, semi-ephemeral (2026-03-15)

## Pending

- [ ] 🔧 [Infra] P1: Extract `has_dockerfile()` helper — 3 places hardcode `Dockerfile` check (make, detect-containers, generate-dashboard.sh)
- [ ] 💡 [CI] P2: Rationalize build inputs — `rebuild` (none/changed/all/force) + `scope` (variant/os/arch filter)
- [ ] 💡 [CI] P3: Cache runner agent tarball in GH Actions cache (key by version, ~200MB saving per build)
- [ ] 💡 [Runner] P5: Windows Pester tests on CI (requires windows-latest runner)
- [ ] 💡 [Runner] P7: SIGKILL orphan runner cleanup script/cron (GitHub auto-cleans after 14 days)
- [ ] 💡 [Runner] P8: Extract shared generate-dockerfile.sh logic to helpers/
- [-] ⏭️ [Runner] Add ubuntu-2204 + debian-bookworm distros (deferred: MVP sufficient)
- [-] ⏭️ [Runner] Docker-in-Docker (DinD) support (deferred: DooD covers most use cases)
- [-] ⏭️ [Testing] Integrate test-harness into CI pipeline (deferred: low value vs complexity)

## Completed

- [x] ✅ [Web-Shell] Multi-distro variants — template+generator, debian/alpine/ubuntu/rocky (2026-02-26)

## Review Findings (non-blocking)

- [x] ✅ [Web-Shell] compute_build_digest now runs after template expansion — captures config.yaml data (2026-02-27, F-004)
- [x] ✅ [Web-Shell] Removed unused flavor_arg from all variants.yaml + dead flavor_arg_name() function (2026-02-27, F-005)

## Blocked / Deferred

- [-] ⏭️ [Infra] Extract reusable yq helpers from generate-dockerfile.sh if a 2nd container adopts template pattern — Priority: L (from /adversarial)

- [-] ⏭️ [Security] Jekyll non-root user — breaking change risk (volume permissions), needs migration plan — Priority: L
- [-] ⏭️ [Infra] apk/apt BuildKit cache mounts — marginal benefit vs complexity — Priority: L

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
