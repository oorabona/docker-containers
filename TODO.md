# Project Backlog

## In Progress

(None)

## Completed (recent)

- [x] ✅ [Runner] Build github-runner container — 6 variants (3 OS × 2 flavors), Linux+Windows, semi-ephemeral (2026-03-15)

## Pending

- [x] ✅ [Infra] Extract `has_dockerfile()` + `list_containers()` helpers (2026-03-16)
- [x] ✅ [CI] Rationalize build inputs — `rebuild` + `scope` inputs (2026-03-16)
- [x] ✅ [CI] Cache runner agent tarball in GH Actions cache (2026-03-16)
- [x] ✅ [Runner] Windows Pester + Linux bats tests in CI (2026-03-16)
- [x] ✅ [Runner] Orphan runner cleanup script (2026-03-16)
- [x] ✅ [Infra] Extract shared generate-utils.sh for template generators (2026-03-16)
- [-] ⏭️ [Runner] Add ubuntu-2204 + debian-bookworm distros (deferred: MVP sufficient)
- [-] ⏭️ [Runner] Docker-in-Docker (DinD) support (deferred: DooD covers most use cases)
- [-] ⏭️ [Testing] Integrate test-harness into CI pipeline (deferred: low value vs complexity)
- [ ] 🔧 [Runner] Windows: create non-admin runner user — Priority: M (ContainerAdministrator = admin, security concern)
- [ ] 🐛 [Runner] Fix Pester tests for CI context — 28/28 fail (mocking context differs from local) — Priority: L
- [ ] 💡 [CI] `rebuild=sync` mode — skopeo copy between registries without rebuilding — Priority: L

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
