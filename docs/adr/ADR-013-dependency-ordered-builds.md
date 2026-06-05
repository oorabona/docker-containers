# ADR-013: Dependency-ordered container builds

**Status:** Accepted
**Date:** 2026-06-05
**Issues:** #628 (origin: `github-runner:debian-trixie` and `web-shell:debian` failed on arm64 because a consumer built in parallel with its base and raced the base's transient single-arch tag)
**Supersedes:** None
**Siblings:** ADR-001 (native multi-arch runners), ADR-010 (chained-on-own & digest drift), ADR-011 (cascade-aware drift detection), ADR-006 (multi-distro template)

## Context

The image fleet is not flat. Three repo-internal chains exist (depth 2):

```
debian → github-runner:debian-trixie
debian → web-shell:debian
php    → wordpress
```

A dependency graph already exists and is well-tested: `helpers/dependency-graph.sh` (`_depgraph_get_deps`, `_depgraph_get_deps_transitive`, `_depgraph_get_consumers`, `_depgraph_validate_no_cycles`; 64 bats). It is sourced by exactly one caller — `scripts/detect-base-digest-drift.sh` (the daily drift job). **The build pipeline never uses it.**

`auto-build.yaml` treats containers as independent: `detect-containers` maps changed files 1:1 to containers (no consumer expansion); `build-and-push` is a single flat matrix (`build × arch`, no inter-cell ordering); `create-manifest` is a global barrier after all build legs.

Empirically confirmed by run `26976283697`: a carry-all rebuilt all 13 containers; `debian` and its consumers built as concurrent cells; `github-runner:debian-trixie` + `web-shell:debian` failed on arm64 while everything else went green; the checkpoint correctly isolated `failed_containers: ["github-runner", "web-shell"]`.

**Priority order for this decision** (governs the option choice):
1. **Reproducibility / determinism** — the same inputs produce the same build, every time.
2. **Remote (CI) operation is the product** — the GitHub Actions pipeline is what must work; native multi-arch on the respective native runners (amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`) is a **hard requirement** (ADR-001). QEMU emulation of arm64 on amd64 runners is explicitly **not** acceptable for CI.
3. **Local debuggability is a force-multiplier, not the goal** — being able to reproduce/debug the ordering on a laptop, with zero GitHub round-trips, is worth a lot, but it serves the remote goal; it is not "local-first" for its own sake.

## Problem

Four interacting defects:

**Gap A — expansion.** A change to `debian/` queues only `debian`, never its consumers.

**Gap B — ordering + transient single-arch tag.** The `Create early tag alias` step (`build-container/action.yaml`) writes the bare canonical tag single-arch after each per-arch leg; the multi-arch manifest is assembled only later by `create-manifest`. A consumer building in the same flat parallel matrix does `FROM debian:trixie` during the single-arch window → `no match for platform` on arm64.

**Gap C — non-strict manifest + mutable-tag identity.** Even with ordering: `create-manifest`'s single-arch fallback can still publish a single-arch rolling tag for an internal base on partial-arch failure; and consumers reference a **mutable rolling tag**, so ordering guarantees *a* manifest exists but not the *exact* index this run produced (cross-run retarget, rerun, local clobber #624).

**Gap D — smart-skip defeats expansion.** `SKIP_EXISTING_BUILDS` keys on a source/config build digest that excludes the base manifest digest, so a `debian/` change can queue `web-shell` yet `web-shell` then **skips** (its own files unchanged).

The defects are coupled: the flat parallel matrix is the root — it has no notion that one container's build depends on another's. Any fix must make the build itself dependency-aware.

## Considered options

**B — `docker buildx bake` with `target:` contexts (chosen).** BuildKit builds the dependency graph in a single invocation and passes each built image to its dependents **in memory**, with no registry round-trip — so the base→child race cannot occur by construction. It is compatible with native multi-arch on separate runners (see Decision) and is **reproducible and debuggable locally** (`docker buildx bake --print` shows the resolved DAG; an actual `bake` builds the chain on a laptop). **Validated e2e locally** (see Validation).

**A — bounded static GHA layer jobs + runtime digest handoff + strict manifest.** Order via a fixed chain of `(build-layerN → manifest-layerN)` jobs driven by the graph; hand the base's freshly-assembled manifest digest to consumers; make canonical-tag publication strict. Rejected as the primary: it only *timing-closes* the race (the base is still consumed through a mutable registry tag, requiring strict-manifest + digest-handoff bolt-ons to be safe), its **ordering lives in GHA job orchestration and is therefore only testable in CI** — it reproduces the very "visible-only-in-CI" failure mode this project keeps paying for. It remains a viable fallback if Option B's pipeline rewrite proves too costly.

**C — static digest pins committed in Dockerfiles** (`FROM debian@sha256:…`). Rejected: a commit+push to every consumer on every base bump (Renovate-style churn). Bake's in-memory handoff gives the same hermetic identity with zero per-update commits.

**D — externalize bases / adopt Dagger·Earthly·Bazel.** Rejected: disproportionate adoption cost for a depth-2 graph; bake is BuildKit-native and the repo already uses buildx.

## Validation (e2e, local)

On a developer laptop (x86_64, podman + brew `docker-buildx` v0.34.1 + rootless `buildkitd` 0.30.0), with a hand-written bake file modelling `debian → {github-runner:debian-trixie, web-shell:debian}`:

- `docker buildx bake --print` resolves the DAG and shows each consumer's `contexts` pointing at `target:debian` — the dependency edge.
- An actual `bake` of `github-runner-debian-trixie-base` built `debian` **first**, then built github-runner on top of it **in memory**: the build log shows debian's stages running inside the consumer target, the `FROM …/debian:trixie` resolved to the local target (no registry pull, no `no match for platform`), and the build proceeded through the consumer's own stages. It stopped only at `COPY runner.tar.gz` — a missing build-context artifact the CI normally pre-fetches, **not** an ordering/race failure.

Conclusion: the base→child ordering and in-memory handoff work, the multi-arch race is structurally impossible, and the whole thing is reproducible on a laptop with no CI round-trip.

## Decision

Make the build dependency-aware by adopting **`docker buildx bake`** as the build engine, driven by the existing dependency graph, with **native per-arch builds on respective runners + manifest merge**.

### 1. Build order — BuildKit, not GHA
A generated `docker-bake.hcl` declares every image as a `target`, with each consumer's base reference remapped to the producing target:
```hcl
contexts = { "ghcr.io/oorabona/debian:trixie" = "target:debian" }
```
BuildKit then builds bases before consumers, deduplicates shared bases, and hands the base image to consumers **in memory**. This subsumes Gap B (ordering) and the timing race entirely, and Gap C's identity problem within a run (the consumer builds against the exact base produced this run, not a mutable registry tag). The HCL is generated from `variants.yaml` so it covers the template-generator containers, retained versions, and the postgres extension sub-pipeline.

### 2. Native multi-arch on respective runners + merge (Gap B across arches; no QEMU)
QEMU on amd64 runners is rejected. Instead, run **one per-arch bake on each native runner**, then merge:
```
job build-amd64 (ubuntu-latest):     bake --set "*.platform=linux/amd64" --push   → <img>:<tag>-amd64
job build-arm64 (ubuntu-24.04-arm):  bake --set "*.platform=linux/arm64" --push   → <img>:<tag>-arm64
job manifest    (needs both):        imagetools create <img>:<tag> <img>:<tag>-{amd64,arm64}
```
Within each per-arch bake, the consumer consumes the **correct-arch** base in memory (bake builds `debian-<arch>` then `github-runner-<arch>` from it) — native, ordered, no QEMU, no per-arch registry round-trip. The only cross-runner artifact is the final manifest list. (An advanced alternative — a multi-node buildx builder spanning both runners with a single `bake --platform amd64,arm64` — is possible but needs cross-runner buildkit networking; the two-job + merge form is simpler and matches ADR-001.)

### 3. Expansion — the graph decides *what* to build (Gap A)
`detect-containers` sources `dependency-graph.sh` and expands changed→consumers (transitive) so the per-arch bake targets the impacted set (changed ∪ consumers). The graph chooses *which* targets; BuildKit orders them. This also removes the bespoke `SKIP_EXISTING_BUILDS` correctness hole (Gap D): build skipping becomes BuildKit's content-addressed cache, which already accounts for the (in-memory) base.

### 4. Strict published manifest (Gap C — across runners)
The `manifest` job publishes the canonical/rolling tag **only** when the full required platform set was pushed; never a single-arch fallback for an internal base. The old `create-manifest` single-arch fallback for internal-base rolling tags is removed.

### 5. Context-artifact pre-fetch
Targets that need build-context artifacts (e.g. `github-runner`'s `runner.tar.gz`, `web-shell`'s `ttyd`) get a pre-fetch step before bake (or a bake-managed remote context / secret). This is the integration surface the local e2e surfaced.

## Out of scope (v1)

- **Replacing the coverage-checkpoint / failure-attribution machinery** — it adapts to the new job shape (per-arch bake jobs + manifest) but its logic (#595) is unchanged in intent.
- **Silent staleness on non-file-change base rebuilds** — still owned by the daily drift cron + ADR-011 cascade.
- **Local multi-arch** — QEMU is a *local convenience only* (rootful binfmt), never a CI mechanism; the host-arch build is enough to validate ordering locally.
- **Local-build clobber of canonical tags** — #624 (push guard), independent.

## Consequences

### Positive
- **Native multi-arch with no QEMU in CI** — arm64 builds on the arm64 runner, its arm64 base built in the same in-memory bake. Directly satisfies ADR-001 + the reproducibility priority.
- **The base→child race is impossible by construction** (in-memory context; no registry round-trip, no transient single-arch tag, no mutable-tag dependence within a run).
- **Reproducible and debuggable locally** — `bake --print` and a laptop build reproduce the ordering with zero GitHub round-trips (the property that would have prevented this whole class of incident).
- The dependency graph the repo already owns is finally used by the build (for expansion); BuildKit owns ordering.

### Negative / Limitations
- **A from-the-studs pipeline rewrite**: per-arch bake jobs replace the `(container × arch)` flat matrix; the post-build steps (Trivy, SBOM/attestation, flatten, multi-registry push, lineage) must be re-homed around bake's outputs; the HCL must be generated from `variants.yaml` covering the template-generator, retained-version, and extension patterns; context-artifact pre-fetch must be wired. Highest blast radius of any option.
- **Per-container build-result attribution** (coverage checkpoint, #595) must be re-derived from the new job shape.
- **Local multi-arch needs rootful QEMU** (a one-time host setup), but this is dev-convenience only; CI uses native runners.
- **Rollout must be incremental and gated**, with live native multi-arch validation (amd64 runner + arm64 runner + merge) and a Windows-tag post-run check.
