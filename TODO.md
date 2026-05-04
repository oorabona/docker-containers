# Project Backlog

## In Progress

(None)

## Backlog

- [ ] 🔧 [terraform] Make cloud CLI version validation conditional on FLAVOR — Priority: M
- [ ] 🐛 [Dashboard] `Capture OCI subject digest` step has `continue-on-error: true` → silently publishes digest-less lineage on flatten/inspect failure. Fail-closed OR gate `auto-build.yaml:645` upload on capture success — Priority: L
- [ ] 🔧 [Dashboard] Extract the SBOM processing block (compare + history + cache replace) from `auto-build.yaml` and `recreate-manifests.yaml` into a `process_sbom_artifacts` function in `helpers/sbom-utils.sh`. Both workflows currently maintain ~45-LOC duplicates that drift over time (every PR2a fix had to be applied twice). Single point of change for SBOM logic — Priority: M
- [ ] 🔧 [Dashboard] Wire `attestation_url` and `trivy_summary` from `containers.yml` into `docs/site/_includes/container-card.html` for `has_variants: false` containers. The data pipeline now emits these fields at container level, but `docs/site/index.html` only forwards a fixed subset to the include. Without this wiring, vector/web-shell/wordpress cards continue to render empty trust-strip badges even though the data exists. Belongs in the trust-strip components PR (PR2b) — Priority: M

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
- [x] ✅ [Runner] Fix Pester tests — ENTRYPOINT_TESTING guard + opt-in via run_tests input (2026-03-17)
- [x] ✅ [CI] `rebuild=sync` mode — skopeo copy GHCR→DockerHub (2026-03-17)
- [x] ✅ [CI] Create `latest-*` rolling tags for Windows variants (2026-03-17)
- [x] ✅ [CI] Decouple manifests — early tag alias per-build + manifest job upgrades (2026-03-17)
- [ ] 🔧 [Runner] Remove double deregistration — runner agent cleans up, then PowerShell.Exiting tries again — Priority: L
- [x] ✅ [CI] SBOM generation for Windows — syft in manifest job on Linux (2026-03-17)

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
