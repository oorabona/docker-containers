# ADR-013: Dependency-ordered container builds

**Status:** Proposed
**Date:** 2026-06-05
**Issues:** #628 (origin: `github-runner:debian-trixie` and `web-shell:debian` failed on arm64 because a consumer built in parallel with its base and raced the base's transient single-arch tag)
**Supersedes:** None
**Siblings:** ADR-010 (chained-on-own & digest drift), ADR-011 (cascade-aware drift detection), ADR-006 (multi-distro template)

## Context

The image fleet is not flat. Three repo-internal chains exist (depth 2):

```
debian → github-runner:debian-trixie
debian → web-shell:debian
php    → wordpress
```

A dependency graph already exists and is well-tested: `helpers/dependency-graph.sh` exposes `_depgraph_get_deps`, `_depgraph_get_deps_transitive` (leaves-first transitive closure of one container — **not** a global layering), `_depgraph_get_consumers` (reverse lookup), and `_depgraph_validate_no_cycles`; 64 bats. It is sourced by exactly one caller: `scripts/detect-base-digest-drift.sh` (the daily drift job). **The build pipeline never uses it.**

`auto-build.yaml` treats containers as independent: `detect-containers` maps changed files 1:1 to containers (no consumer expansion); `build-and-push` is a single flat matrix (`build × arch`, `max-parallel: 10`, no inter-cell ordering); `create-manifest` is a global barrier after all build legs.

Empirically confirmed by run `26976283697`: a carry-all rebuilt all 13 containers; `debian` and its consumers built as concurrent cells; `github-runner:debian-trixie` + `web-shell:debian` failed on arm64 while everything else went green; the checkpoint correctly isolated `failed_containers: ["github-runner", "web-shell"]`.

## Problem

Three interacting defects, not two:

**Gap A — expansion.** A change to `debian/` queues only `debian`, never its consumers.

**Gap B — ordering + transient single-arch tag.** The `Create early tag alias` step (`build-container/action.yaml:737-788`) writes the bare canonical tag single-arch after each per-arch leg; the multi-arch manifest is assembled only later by `create-manifest`. A consumer building in the same flat parallel matrix does `FROM debian:trixie` during the single-arch window → `no match for platform` on arm64.

**Gap C — non-strict manifest + mutable-tag identity.** Even with ordering, two holes remain:
- `helpers/create-manifest.sh` has single-arch **fallback** paths. For a rolling-tagged internal base like `debian:trixie` (non-numeric), `_compute_version_specific_tag_args` resolves the version-specific anchor to the rolling tag itself, so on partial-arch failure the fallback **publishes a single-arch `debian:trixie` and returns success** — a consumer in the next layer then builds against a structurally single-arch base and fails anyway.
- Consumers reference a **mutable rolling tag** (`FROM debian:trixie`), so ordering guarantees *a* manifest exists but not that the consumer pulled the *exact* index this run produced (cross-run retarget, rerun, local clobber #624).

And one amplifier:

**Gap D — smart-skip defeats expansion.** `SKIP_EXISTING_BUILDS` + a source/config-based build digest (`helpers/build-cache-utils.sh`) that does **not** include the resolved base manifest digest means a `debian/` change can queue `web-shell`, but `web-shell` then **skips** because its own Dockerfile/config didn't change. Expansion alone does not guarantee the consumer rebuilds.

Critically: **fixing Gap A without B+C fires the race on every base change.** Expansion, ordering, manifest-strictness, identity, and skip-semantics must be designed together.

## Considered options

**A — Layering + runtime digest handoff + strict manifest (chosen).** Order via bounded static GHA layer jobs driven by the graph; hand the base's freshly-assembled manifest **digest** to consumers in-pipeline; make canonical-tag publication strict. Detail in Decision.

**B — `docker buildx bake` with `target:` contexts (the cleaner end-state; deferred, not dismissed).** BuildKit builds the DAG in one invocation and passes each built image to its dependents *in memory*, with no registry round-trip — so the manifest-list race vanishes by construction. This is compatible with native multi-arch (ADR-001): run `bake` once per arch on the matching native runner (`--set *.platform=linux/<arch>`), where base→child is ordered in memory for that arch, then assemble per-container manifests. It does **not** make the post-build steps redundant — Trivy, SBOM/attestation, flatten, multi-registry push, and lineage are orthogonal and still run on bake's outputs; bake replaces only the build+order step.

Deferred from v1 purely for blast radius and incrementalism, **not** correctness or feasibility: it replaces the `(container × arch)` matrix with per-arch bake jobs (changing the parallelism granularity and the per-container build-result attribution the coverage checkpoint relies on), requires re-homing the entire post-build pipeline around bake outputs, and requires generating the bake HCL from `variants.yaml` while covering the template-generator pattern (web-shell/github-runner generate their Dockerfiles), retained versions, and the postgres extension sub-pipeline. The layered approach (Option A) reuses every existing per-container step and only reorders them, so it is the lower-risk v1. Option B is the strongest long-term consolidation and should be its own ADR.

**C — static digest pins committed in Dockerfiles/config** (`FROM debian@sha256:…` checked in). Rejected: requires a commit+push to every consumer on every base bump (Renovate-style churn). The **runtime** digest handoff in Option A gives the same hermetic-identity guarantee with zero per-update commits.

**D — externalize bases / adopt Dagger·Earthly·Bazel.** Rejected: disproportionate for a depth-2 graph.

## Decision

Three coordinated mechanisms — order, identity, safety — plus skip and rollout discipline.

### 1. Expansion (Gap A) — shadow first
`detect-containers` sources `dependency-graph.sh` (config-only path; `_DEPGRAPH_LINEAGE_DIR` pinned empty to avoid the fail-closed `./make list-builds` fan-out) and expands each changed container with `_depgraph_get_consumers` (transitive) into the impacted set. **Phase 1 emits this and the layer outputs as SHADOW outputs only** — the live `builds`/`containers` behaviour is unchanged until Phase 2, so expansion never reaches the flat matrix (which would trigger the race).

### 2. Topological layering (Gap B — order)
A **new** partition step (this is genuinely new code; the helper gives per-container transitive deps, not a global level map) assigns each impacted build a layer index = longest internal-dep path within the **impacted induced subgraph**, **densely renumbered** (if only `wordpress` changes it is `layer0`, not `layer1`). It emits one build matrix per layer (`layer0..layer{LAYER_MAX}`, initial `LAYER_MAX=3`), **failing closed** if real depth exceeds the cap. Layer unit = **container** (coarsest safe granularity): all of a multi-distro container's cells (incl. its external-base distros and its windows/arm64-excluded rows) ride in its container's layer — accepting over-serialization of independent distros in exchange for simplicity and safety. Diamonds (a container consumed by two bases) resolve to one layer (max of the two).

The workflow declares a fixed chain `build-layer0 → manifest-layer0 → build-layer1 → manifest-layer1 → …`: `manifest-layerN needs build-layerN`; `build-layer{N+1} needs manifest-layerN`. Each job guards `if: needs.detect-containers.outputs.layerN != '[]'`. The `strategy.matrix` (arch list + windows-arm64 `exclude` + `max-parallel`) is **replicated identically per layer** (an actionlint/bats check asserts the blocks stay in sync). All downstream jobs (`summary`, `publish-coverage-checkpoint`, `cache-lineage`, `sync-registries`) are rewired to depend on every layer/manifest job with `always()`/`!cancelled()` + explicit `needs.*.result` checks.

### 3. Runtime digest handoff (Gap C — identity)
When `manifest-layerN` assembles a base's multi-arch index, capture its **manifest-list digest** and pass it to that base's consumers in `build-layer{N+1}` via their **existing base build-arg**: `DEBIAN_TRIXIE_BASE=ghcr.io/oorabona/debian@sha256:<digest>`, etc. The consumer is then hermetic to the exact index built this run — eliminating both the transient single-arch window and cross-run mutable-tag drift. github-runner already takes a full-ref build-arg (free); web-shell's generated `FROM` takes a tag and needs the ref form; **wordpress needs a one-time refactor** of `FROM ${REMOTE_CR}/php:${PHP_TAG}` to accept a full `repo@sha256` ref. These are one-time plumbing changes, **not** committed static digests.

### 4. Strict canonical-tag publication (Gap C — safety)
`create-manifest` must **never** publish a canonical/rolling tag for an **internal base** unless the full required platform set exists. Remove the single-arch fallback for internal-base rolling tags: on partial-arch failure the manifest job **fails** (which blocks the dependent layer) instead of publishing a single-arch rolling tag and returning success. The layer→layer edge additionally verifies the base manifest is multi-arch (`imagetools inspect` asserting both platforms), not merely that the job's exit code was 0.

### 5. Base-aware smart-skip (Gap D)
A dependency-triggered consumer must not be skipped when its base changed. Either force-rebuild dependency-expanded consumers, or — preferred — fold the resolved base manifest digest into the build-cache digest (`build-cache-utils.sh`) so a base change naturally busts the consumer's skip.

## Out of scope (v1)

- **Silent staleness on non-file-change base rebuilds** (CVE rebase with no `debian/` diff): still owned by the daily drift cron + ADR-011 cascade.
- **Migration to buildx bake** (Option B) — future ADR.
- **Graphs deeper than `LAYER_MAX`** — fail-closed guard, not dynamic layer creation (GHA cannot create `needs:` edges at runtime).
- **Local-build clobber of canonical tags** — that is #624 (push guard), independent.

## Consequences

### Positive
- A base change rebuilds its consumers, in correct order, hermetically pinned to the exact base index — the build finally uses the graph it owns.
- The multi-arch race becomes genuinely impossible (not just timing-closed): order + digest identity + strict manifest together.
- Reuses the tested topo helper; no new build tool; no committed static digests / no per-update churn.

### Negative / Limitations
- **Phase 2 is a core pipeline rewrite**, not a YAML tweak: layer topology, manifest strictness, base-aware skip, downstream result aggregation, and digest handoff plumbing. The 30/20/50 framing under-weights this — treat Phase 2 as the project.
- **More wall-clock**: layers serialize; a slow base (e.g. debian's arm64 leg, the #628 culprit) head-of-line-blocks all consumers; the windows variant of github-runner (~60-120 min) now waits behind debian's manifest despite not depending on it (the cost of container-granular layering).
- **`LAYER_MAX` ceiling**: deeper graph needs a new layer stanza; the guard makes overflow loud, not silent.
- **wordpress `FROM` refactor** is a real (one-time) change; web-shell generator tweak likewise.
- **Blast radius**: every container's build path + all downstream reporting jobs change; roll out incrementally with live multi-arch validation and a Windows-tag post-run check (the early-alias comment claiming the manifest job skips Windows is stale — create-manifest does handle Windows; removal is safe but must be verified).
