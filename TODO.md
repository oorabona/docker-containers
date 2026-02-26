# Project Backlog

## In Progress

(None)

## Pending

- [-] ⏭️ [Testing] Integrate test-harness into CI pipeline (auto-build.yaml) — Priority: L (deferred: low value vs complexity of docker load/pull in CI, local tests suffice)

## Completed

- [x] ✅ [Web-Shell] Multi-distro variants — template+generator, debian/alpine/ubuntu/rocky (2026-02-26)

## Review Findings (non-blocking)

- [ ] 🔧 [Web-Shell] compute_build_digest should include config.yaml (not just Dockerfile.template) — Priority: M (from /review F-004)
- [ ] 🔧 [Web-Shell] flavor_arg DISTRO in variants.yaml may be unused by build system — verify or remove — Priority: M (from /review F-005)

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
