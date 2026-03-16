# Project Backlog

## In Progress

(None)

## Completed (recent)

- [x] ✅ [Runner] Build github-runner container — 6 variants (3 OS × 2 flavors), Linux+Windows, semi-ephemeral (2026-03-15)

## Pending

- [ ] 💡 [Runner] Add ubuntu-2204 + debian-bookworm distros — Priority: M (from /adversarial, deferred: MVP scope reduction)
- [ ] 💡 [Runner] Docker-in-Docker (DinD) support — Priority: M (from /adversarial, deferred: security implications)
- [ ] 💡 [Runner] Extract shared generate-dockerfile.sh logic to helpers/ — Priority: L (from /adversarial, deferred: wait for 3+ containers using pattern)
- [ ] 💡 [Runner] SIGKILL orphan runner cleanup script/cron — Priority: L (from /adversarial, deferred: GitHub auto-cleans after 14 days)
- [ ] 💡 [Runner] Windows Pester tests on CI — Priority: M (requires windows-latest runner)
- [ ] 💡 [CI] Rationalize build inputs: replace force_rebuild+scope_flavors with `rebuild` (none/changed/all/force) + `scope` (variant/os/arch filter) — Priority: M
- [ ] 💡 [CI] Cache runner agent tarball in GH Actions cache (key by version, ~200MB saving per build) — Priority: L
- [-] ⏭️ [Testing] Integrate test-harness into CI pipeline (auto-build.yaml) — Priority: L (deferred: low value vs complexity of docker load/pull in CI, local tests suffice)

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
