# ADR-014: Converge the post-build supply chain onto the published-artifact model

**Status:** Accepted
**Date:** 2026-06-08
**Issues:** #666 (consolidate the build pipeline toward bake), #572 (heavy postgres builds flake ~20% in the post-build phase)
**Supersedes:** None
**Siblings:** ADR-013 (dependency-ordered builds / bake engine), ADR-008 (Trivy severity policy)

## Context

After the bake cutover (ADR-013, #628), the fleet runs **two divergent post-build chains**:

- **bake path** (all 12 Linux containers' latest version): `bake-build-<arch>` builds and **pushes** per-arch refs to GHCR, then dedicated jobs `bake-trivy` / `bake-attest` operate on the **published** `:<tag>-<arch>` ref. The build job does no local image load.
- **matrix path** (`build-container/action.yaml` + `build-and-push`): builds with `--load` into the local daemon, then runs Trivy + SBOM + attest **inline, in the build job, against the locally-loaded image**, then pushes. This still serves: Windows variants, the postgres extension pipeline, retained (non-latest) Linux versions, and scoped / pull_request / run_tests cells.

The matrix path's inline, locally-scanned supply chain is the root cause of #572: the heavy `postgres:full` / `postgres:distributed` builds flake ~20% of master runs in the post-build phase. The build + pushes succeed; a later network-dependent advisory step (syft pulling the multi-GB image, SBOM upload, Sigstore attestation, SARIF upload) fails and — because those steps run *inside the build job* — fails the whole build. The current mitigation (full-rebuild retry) re-incurs every post-build network step, so a transient hiccup can fail both attempts.

Loading the image locally is not free either: it costs runner minutes and disk, and the `--load` itself is a network/IO operation that can fail. Maintaining two supply-chain implementations (inline-matrix vs dedicated-bake) is duplicate surface that drifts.

**Priority order for this decision:** correctness (no advisory step may fail a build) > DRY (one supply-chain method) > runner cost > diff size.

## Decision

**Converge every path onto the bake model: build → push → run the supply chain (Trivy / SBOM / attest) in separate jobs against the published per-arch ref. No path loads the image locally to scan it.**

This is delivered incrementally through the #666 consolidation, plus one path-specific restructure for postgres (which never moves to bake — its extension build model is genuinely different, per ADR-013 and #666's documented out-of-scope list).

### Target end state

- **bake** for all Linux containers (latest **and** retained), including their PR / run_tests / scoped cells.
- A minimal **Windows-only** flat matrix (no Linux BuildKit container driver on Windows runners).
- The **postgres** extension pipeline stays, but its post-build supply chain is restructured to the published-artifact model (build + push, then separate `postgres-trivy` / SBOM / attest jobs) — so postgres also stops loading-and-scanning locally and stops failing builds on advisory flakes.

### Phasing (each item is its own reviewed, validated PR)

| Phase | Item | Notes |
|-------|------|-------|
| 0a | Close A1/A2 | Investigation finding: there is **no** explicit flat-matrix ordering/expansion-for-ordering hack to remove (the matrix runs flat/parallel; ordering relied on the registry + one-container-per-dispatch; the bake DAG is the ordering mechanism). The internal base→consumer handoff is fallback-only post-bake; the wordpress probe already dropped in #676. A1/A2 are moot — close with evidence, no code. |
| 0b | postgres post-build → published-artifact model | Build + push, then separate scan/SBOM/attest jobs against `postgres:<tag>-<arch>`; drop the inline local-load scan for postgres. Highest immediate #572 value (worst offender, never on bake). Independent of all other phases. |
| 1 | B1 — retained → bake | Pivot. Needs a `partition_builds` / `detect-containers` schema change to route retained bake-managed cells into `bake_builds` (the generator's `--all-retained` already exists but is never passed). **Risks:** github-runner has `bake_latest_only: true` (single shared `runner.tar.gz`) → its retained cells stay matrix; chained containers (wordpress→php, github-runner→debian) need context→target mapping validated across version combinations. |
| 2 | B3 (PR→bake), B2 (run_tests→bake), B4 (scoped→bake) | Independent of each other; after B1. B4 needs new generator scope-filter capability (~30–50 LOC). B2 needs a `bake-test` job (pull per-arch ref, run bats/Pester). Each removes its term from the `force_matrix` condition. |
| 3 | C1/C2/C3 | Slim `build-and-push` / `create-manifest` to Windows-only; delete the now-dead Linux supply-chain code in `build-container/action.yaml` (~200 LOC); decouple the slow Windows build from the run critical path. Depends on B1 (and B2/B3/B4 for full `force_matrix` removal). |

## Consequences

**Positive:**
- #572 flake removed at the root: advisory post-build steps run in separate jobs and can never fail a build; the heavy registry pull (syft) and Trivy operate on the published ref with their own retry/timeout (see #683 for the shared-helper hardening already shipped).
- Single supply-chain method (DRY): the inline-matrix Trivy/SBOM/attest implementation is deleted; only the bake-model jobs remain (plus the postgres variant of them).
- Scan-what-you-publish fidelity: every scan targets the exact published artifact consumers pull, not a pre-push local image.
- Lower runner cost: no `--load` of multi-GB images.

**Negative / risks:**
- High blast radius: `build-container/action.yaml` and `auto-build.yaml` are touched by nearly every build. Each phase ships and is validated independently (the PR's own CI builds the affected containers; master flake rate is the real signal over several runs).
- B1 is not a one-liner (schema change + github-runner retained caveat + chained-container version mapping) — it is the gating risk of the program.
- Separate scan jobs add job-scheduling overhead and a small wall-clock cost vs inline scanning; acceptable given the correctness/DRY win.

**Out of scope (unchanged from #666):**
- postgres → bake (extension build model differs; no base→consumer race).
- Windows → bake (no Linux BuildKit container driver on Windows runners).
- External base-cache mirror decommission (permanent docker.io rate-limit mitigation, consumed by both paths).
