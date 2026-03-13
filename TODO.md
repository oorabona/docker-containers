# Project Backlog

## In Progress

(None)

## Completed (recent)

- [x] ✅ [CI] Fix sslh build — 3 layered fixes: `image_loaded` output, versions-only variant fallback, cache tag verification (2026-03-06)
- [x] ✅ [Infra] DRY_RUN mode — `$DOCKER`/`$SKOPEO` variable substitution, CI `dry_run` input, 6 bats tests (2026-03-06)
- [x] ✅ [CI] Fix GHCR cache tag doubling — never include tag in build-args, all Dockerfiles use Two-ARG pattern (2026-03-06)
- [x] ✅ [Code-Health] Removed dead code: `extract_package_list` + `extract_sbom_packages` from `helpers/sbom-utils.sh` — 0 callers (2026-03-06)
- [x] ✅ [Code-Health] Refactored `main()` in `scripts/build-extensions.sh` — extracted 3 helpers, 211→77 lines (2026-03-06)

## Pending

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
