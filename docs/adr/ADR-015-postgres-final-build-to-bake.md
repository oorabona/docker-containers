# ADR-015: Move the postgres final image build onto bake (reusable extension-container framework)

**Status:** Accepted
**Date:** 2026-06-10
**Issues:** #666 (consolidate the build pipeline toward bake)
**Amends:** ADR-014 (which listed `postgres → bake` as out of scope)
**Siblings:** ADR-013 (dependency-ordered builds / bake engine), ADR-014 (post-build supply-chain convergence)

## Context

ADR-014 declared `postgres → bake` out of scope: "the extension build model is genuinely
different; no base→consumer race to motivate it." That reasoning conflated two distinct
builds:

- **Extension compilation** — `build-extensions` compiles each extension (pgvector,
  timescaledb, …) into its own `ext-<name>:pg<major>` image, per architecture, with
  per-extension version resolvers. This genuinely does not fit the generic bake model.
- **The final image build** — a normal multi-stage Dockerfile that consumes the
  already-published `ext-*` images via `FROM` / `COPY --from=`. There is nothing
  extension-specific about *this* step: it is a plain build that BuildKit can do.

Leaving the final build on the flat matrix is the last thing keeping the matrix from
being Windows-only (the ADR-014 end state). It also keeps postgres on the inline,
locally-loaded supply chain that ADR-014 set out to retire.

## Decision

**Move the postgres final image build onto bake. Keep extension compilation as its own
pipeline.** Build it as a *reusable framework* so a future multi-major,
extension-compiling container is a configuration change, not a workflow rewrite.

### Mechanism (opt-in, dormant by default)

| Element | Role |
|---------|------|
| `<container>/extensions/config.yaml` (presence) | Identifies an *extension container*. Drives the `extension_builds` detect-containers output that gates the compilation jobs. |
| `build.bake_final_build: true` (in `variants.yaml`) | Capability marker: this container's final image is bake-buildable. |
| `--include-final-build` (generator flag) | Per-run *activation*. Only the bake build/merge jobs pass it (after downloading the extension lineage). The whole-fleet `bake --print` smoke and the normal fleet build never do, so the capability stays dormant — a flag-marked container cannot perturb existing builds until a job explicitly activates it. |
| `<container>/generate-dockerfile.sh` | Bridges the generic bake Dockerfile materializer to `generate_dockerfile()` (expands the `@@EXTENSION_STAGES@@` / `@@EXTENSION_COPIES@@` / `@@RUNTIME_DEPS@@` markers). |
| `build.always_all_versions: true` | `partition_builds` routes every major to bake, so the container does not split across the bake and matrix engines. |
| `base_suffix` | The bake `VERSION` build arg carries it (`18` → `18-alpine`), so the Dockerfile's `FROM …:${VERSION}` resolves to the correct base. |

The CI keys off the generic signals (`extension_builds`, `bake_final_builds`, both derived
from `extensions/config.yaml` presence + the flag) — **never off the container name**.
The shared `bake-trivy` / `bake-attest` / `bake-merge` jobs are generic over the build
set, so a new extension container is covered with no per-container jobs.

### Ordering

A postgres bake build consumes `ext-*` images, so it must run after the extension
pipeline. The bake build jobs gain `needs: [build-extensions, merge-extension-manifests]`
with `if: result == 'success' || 'skipped'` — identical to the old matrix path. Because
the extension pipeline is itself gated on an extension container being in the changed set,
this dependency is **free** on every build that does not touch postgres (the jobs skip and
the bake build proceeds with no delay).

## Consequences

**Positive:**
- The matrix builds zero postgres cells on a normal push — the last step toward a
  Windows-only matrix (ADR-014 end state).
- postgres inherits the published-artifact supply chain (ADR-014): scan/attest run in
  separate jobs against the pushed ref, not inline against a locally-loaded multi-GB image.
- The framework is reusable: a future postgres-like container is `extensions/config.yaml`
  + resolvers + a `generate-dockerfile.sh` wrapper + two `variants.yaml` flags + one line
  in `bake_managed_containers`. No workflow edits.

**Negative / risks:**
- The bake build/merge enumeration carries conditional final-build wiring (download +
  flag), gated on the generic signals. Localized; a dedicated postgres bake job was
  considered and judged unwarranted for a single container.
- High blast radius (`auto-build.yaml`): validated by a controlled `workflow_dispatch`
  building all 21 postgres cells multi-arch before cutover.

**Genericity boundary (honest scope):**
- Reusable as-is for a **PostgreSQL-family** container.
- The extension tag vocabulary is PostgreSQL-shaped (`ext-<name>:pg<major>`,
  `pg_major_version()`). A genuinely different engine would need that parameterized —
  **deferred** (YAGNI: only postgres exists today).
- Per-extension version resolvers (`scripts/resolvers/`) are written per extension, as
  expected — not a framework gap.

## Phasing

| Phase | Item |
|-------|------|
| P1 | Generator capability + the `bake_final_build` flag + `--include-final-build` activation + `base_suffix` in `VERSION`. No routing change (postgres stays on the matrix). |
| P2 | Route postgres to bake (`bake_managed` + `always_all_versions` routing + extension-lineage download + the generic `extension_builds` / `bake_final_builds` signals). |
| P3 | Delete the now-dead matrix-side postgres jobs (`postgres-trivy` / `postgres-attest`, which auto-skip once postgres leaves the matrix). |
