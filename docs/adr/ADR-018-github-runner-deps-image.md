# ADR-018: Decouple the github-runner OS-package layer into a project-built deps image

**Status:** Proposed
**Date:** 2026-11-20
**Issues:** #2338 (origin: `github-runner` build-gate failure caused by a 60-minute job timeout during `apt-get install`)
**Supersedes:** None
**Siblings:** ADR-005 (github-runner container), ADR-006 (multi-distro template), ADR-010 (chained-on-own & digest drift), ADR-011 (cascade-aware drift), ADR-013 (dependency-ordered builds / bake)
**Not to be confused with:** #2063 (Bake-cell finalisation after a sibling failure). Different problem, different layer; see "Relationship to #2063".

## Context

### The incident

Run `44475644611` (push of `adf7ab37`, a `base-digest-drift(github-runner)` rebuild) failed its `build-gate`. 51 of 52 non-skipped jobs were green. The one that was not was
`Build github-runner:ubuntu-2404-dev (amd64)` for the retained tag `2.338.0-dev`. It was cancelled at the 60-minute job limit
(`auto-build.yaml`, `timeout-minutes: ${{ matrix.build.os == 'windows' && 120 || 60 }}`), after 3 561 s.

The job log shows where the time went:

| BuildKit step | Duration | Note |
|---|---|---|
| `[stage-0 3/13]` dev-flavor `apt-get install` (build-essential, libgtk-3-dev, libwebkit2gtk-4.1-dev, …) | **1 651.9 s** | download-bound |
| `[stage-0 4/13]` `apt-get install tini sudo` | 99.7 s | 1 225 kB fetched in 1 min 6 s (18.6 kB/s) |
| `[stage-0 10/13]` `installdependencies.sh` | in progress at cancel | runs `apt-get update` + install again |

`archive.ubuntu.com` was slow from the runner (≈18 kB/s on a 1.2 MB fetch; 1 070 kB/s on the index fetch). The sibling leg (`2.338.1-dev`, same variant) finished at 56 min 38 s, 83 s under the limit.

### Per-leg durations in the same run (Linux legs only)

| Leg | Duration |
|---|---|
| `ubuntu-2404-base` amd64 (two retained tags) | 50 min 12 s, 37 min 36 s |
| `ubuntu-2404-dev` amd64 (two retained tags) | cancelled at 60 min, 56 min 38 s |
| `ubuntu-2404-*` arm64 | 3–5 min |
| `debian-trixie-base` amd64 | 4–5 min |
| `debian-trixie-dev` amd64 | 8–10 min |

The `base` flavor installs five tiny packages (`git curl jq unzip ca-certificates`) and still took 37–50 min on Ubuntu amd64. So the problem is **not** the size of the dev package set; it is that every Ubuntu amd64 leg depends on a slow `archive.ubuntu.com` path, and **each leg repeats the same download**. Source for the table: job `started_at`/`completed_at` of run `44475644611`. I did not read the logs of the legs other than the two dev ones.

### Why the existing caches did not help (corrected)

An earlier revision of this section blamed the base digest drift. **That was wrong for the failing leg.** `adf7ab37` (`github-runner/LAST_REBUILD.md`) records drift only for `ghcr.io/oorabona/debian:trixie` (variants `2.338.0/2.338.1-debian-trixie[-dev]`). The `ubuntu-2404` base (`library/ubuntu:24.04`) did not drift in that commit, so the Ubuntu apt layers were valid cache candidates and still ran for 1 652 s. The drift only explains why the Debian legs rebuilt; those were fast (4-10 min) because their mirror was fast.

What the code shows instead:

- **Flat-matrix legs share one cache ref.** `scripts/build-container.sh:464` passes `ghcr.io/<owner>/github-runner:buildcache` to `_configure_cache`, with `--cache-to ...,mode=max`. That single ref is used by every variant, every retained version and both architectures. Concurrent jobs exporting to the same registry ref replace each other's cache manifest (last writer wins), so any one leg's layers are only in the cache until the next leg finishes.
- **Bake cells use a per-tag, per-arch ref.** `scripts/generate-bake-hcl.sh:1586` uses `${remote_cr}/${container}:buildcache-${tag}${ARCH_SUFFIX}`. No two cells write the same ref. This is consistent with the Bake cell for `2.338.2` completing all variants in 1-3 minutes in the same run while the flat legs for retained versions took up to an hour.
- `generate-dockerfile.sh` emits `--mount=type=cache` for `/var/cache/apt` and `/var/lib/apt/lists`, but CI runners are ephemeral so these start empty on each job.
- The apt layers are identical across versions (`runner.tar.gz` is copied after them) and, in the flat matrix, are built by each retained-version leg on its own runner at the same time.

**Step 0 findings (run `44475644611`, logs of the `ubuntu-2404-base` amd64 and `debian-trixie-dev` amd64 flat legs):**

- Both legs print `Using registry cache: ghcr.io/<owner>/github-runner:buildcache` and import the cache manifest in about 0.5 s, yet **no step is marked `CACHED`**: every `RUN` executed.
- On `ubuntu-2404-base` amd64, each of the three `apt-get update && install` steps took about 1 230 s (1 231 s, 1 234 s, and 283 s for `installdependencies.sh`) for a handful of tiny packages. The same steps took 3 s and 14 s on Debian. Time is dominated by repeated `apt-get update` index downloads (about 34 MB each) from a slow mirror, and `Dockerfile.linux` runs `apt-get update` four times per image.
- The cache ref being shared explains missing layers, but a second candidate is not excluded: `ARG VERSION` is declared **before** the apt layers, and BuildKit passes declared build args to every following `RUN`, so a different runner version may change the cache key of those layers. To be tested (needs a builder; none was available in the analysis session). If true, every new runner release re-runs the apt layers for every variant, whatever the cache ref. The cheap fix would be to declare `ARG VERSION` after the OS-package layers.

**Status of the shared-ref explanation:** the code paths and the timing agree, but I have not been able to observe the registry cache contents or a `CACHED` marker for these steps (no registry access from the analysis session). Step 0 (partly done, see findings above) is to verify it.

## Problem

1. **Duplicated, version-independent work.** The OS-package layer does not depend on the runner version, yet it is rebuilt per version.
2. **Cache ref shared across unrelated legs (flat matrix).** One `:buildcache` ref for all variants, versions and arches, so a leg's apt layer rarely survives to the next run.
3. **No isolation from mirror slowness.** The timeout is a symptom: the underlying exposure is the number of times we download the same packages from a mirror we do not control.
4. **Blunt failure mode.** A timeout is reported as a build failure of the whole container (`build-gate`), producing a "Build failed" issue with no detail (separate defect, addressed outside this ADR).

## Priorities (governing the choice)

1. **Reproducibility / determinism**, in line with ADR-013. The final image must be built against an identifiable deps image, not a mutable tag.
2. **CI is the product.** Native amd64/arm64 runners, no QEMU (ADR-001).
3. **Reuse the existing machinery** (dependency graph, bake `target:` contexts, drift detection, cascade) rather than adding a parallel mechanism.
4. **Keep security patching latency** at least as good as today (daily drift, Trivy).

## Considered options

**A. Retries and timeouts on apt only** (`Acquire::Retries`, `Acquire::http::Timeout`, optional faster mirror). Cheap and worth doing regardless, but it does not reduce the number of downloads. Rejected as the *only* fix.

**B. Raise `timeout-minutes` for Linux legs.** Rejected by the maintainer: it hides the cause and a slower mirror day still fails.

**C. Persist BuildKit apt cache mounts across jobs** (`actions/cache` + `buildkit-cache-dance`). Would let a base change reuse downloaded `.deb` files. Requires removing Ubuntu's `docker-clean` hook, adds a third-party action, consumes the 10 GB Actions cache quota across 4 variants × 2 arches, and still repeats the *install* work per version. Does not fix the duplication across versions. Rejected as primary.

**D. Single multi-stage Dockerfile with a registry-exported cache of the apt stage.** The layer cache is invalidated by the base change (see above). Rejected.

**E. A `github-runner-deps` image, built once per (distro, flavor, arch) and consumed by the runner image through `FROM` (proposed).** Detailed below.

**G. Build the retained versions through Bake as well, then re-evaluate E.** Bake cells have per-tag, per-arch cache refs, order dependencies in memory, and BuildKit deduplicates identical build steps inside one invocation. Blocked today by `bake_latest_only` because all variants share one `runner.tar.gz` in the container directory; needs per-version build contexts. Likely removes most of the observed cost on its own, at lower blast radius than E. Proposed as the **first** step; E remains justified only if measurement after G still shows meaningful repeated apt downloads.

**F. Stop rebuilding retained versions on drift.** Would remove the duplication but also stop patching retained images, which is a security-policy change, not a build optimisation. Out of scope; noted as an open question.

## Proposed decision (revised)

Stage the work. **Step 1 is option G** (retained versions through Bake with per-version contexts). **Option E below is the follow-up**, adopted only if measurement after step 1 still shows repeated version-independent apt downloads or a need to decouple package patching from runner releases. The design of E is kept here so the decision does not have to be re-derived.

Introduce an **internal, project-built container `github-runner-deps`** that holds everything in the Linux Dockerfile up to the runner agent:

- the base image, `apt-get install` of the base flavor packages, the dev-flavor packages (dev variants only), `tini`, `sudo`, `gosu`;
- the `runner` user, the `docker` group, and the sudoers entry.

The runner Dockerfile (`Dockerfile.linux`) becomes: `FROM <deps image>` + `COPY runner.tar.gz` + `installdependencies.sh` + entrypoint. Windows variants are unchanged.

### Shape

| Aspect | Decision |
|---|---|
| Variants of the deps container | `ubuntu-2404`, `ubuntu-2404-dev`, `debian-trixie`, `debian-trixie-dev` (same distro × flavor matrix as today; the dev deps image extends the base one so the base packages are not duplicated) |
| Generation | Same template + generator pattern (ADR-006): the package-related markers (`@@INSTALL_PACKAGES@@`, `@@DEV_PACKAGES@@`, `@@CREATE_USER@@`, tini/sudo/gosu) move into a deps template driven by the **existing** `distros:` and `flavors:` blocks of `config.yaml`, so package lists stay declared in one place |
| Versioning | Not tied to the runner version. Tag identifies content: distro, flavor and a content stamp derived from the generated Dockerfile + package lists (the build digest of ADR-006 already hashes the generated output) |
| Graph | `github-runner` declares the deps image as a project-internal base. `helpers/dependency-graph.sh` already unions `config.yaml` reference-bearing fields (`.base_image`, `.build_args.*`, `.distros.*.base_image`), so no new graph code is expected; to be verified |
| Build order | Bake `target:` context handoff (ADR-013) for the latest version: deps is built first, in memory, per arch |
| Drift | The base digest drift (ADR-010/011) now fires on `github-runner-deps`. The cascade rebuilds `github-runner`, whose layers are small (tarball + entrypoint), instead of re-downloading packages per version |
| Trivy / SBOM | The deps image is a published image like any other and goes through the existing scan/attestation path |

### What improves

- The apt download happens **once per (distro, flavor, arch)** per base or package change, not per retained version. In the run above, each Linux variant had two flat-matrix legs (retained `2.338.1` and `2.338.0`) plus one Bake cell (`2.338.2`); the Bake cell is the only one that benefits from the registry cache today. The deps image would reduce that to one apt build per variant and arch.
- A runner version bump no longer touches apt at all.
- Package changes become a reviewable change to one container with its own build, scan and lineage record.
- It follows an existing pattern (`debian → github-runner:debian-trixie`, `php → wordpress`).

### What does not improve

- The one download that remains still depends on the mirror. Option A (retries, timeouts) should be kept in the deps template for that reason.

## Open questions for option E (re-examined after Step 2)

1. **Retained versions and ordering.** The retained versions are built by the flat matrix, which ADR-013 identifies as having no inter-cell ordering and a mutable-tag handoff (Gaps B and C). A retained-version leg consuming the deps image from the registry could race the Bake job that publishes it. Candidate answers: (a) a dedicated job that builds and publishes the deps image (with a verified multi-arch manifest) before both engines start, and retained legs reference it by `@sha256:` digest; (b) move retained github-runner versions to Bake (the `bake_latest_only` comment says this needs per-version build contexts). Needs a decision; (a) is smaller, (b) removes a whole class of problem.
2. **Digest pinning for reproducibility.** Should the runner image record the deps digest in its lineage (as `sibling_target` / `base_image_digest` do today)? Proposed: yes, same schema.
3. **`installdependencies.sh`.** It runs `apt-get update` + install from the runner tarball and is version-dependent, so it stays in the final stage. Could the deps image pre-run it from the current runner to make that step a near no-op? Needs a measurement of what it actually installs on top of the deps image.
4. **Dev deps image shape.** Extend the base deps image (smaller, but dev depends on base) or standalone (simpler graph, duplicates base packages). Proposed: extend.
5. **Patching cadence.** Daily drift only fires when the *base* digest moves. Packages installed from the distro archives can receive updates without a base change. Is a periodic forced rebuild of the deps image (e.g. weekly) needed? This is the same staleness window as today, which also only rebuilds on drift or a template change; the ADR should state it rather than hide it.
6. **Naming and registry layout.** `github-runner-deps` as a separate repository under `ghcr.io/oorabona`, versus a tag namespace of `github-runner`. Affects `cleanup-registry` retention rules and the Docker Hub mirror (ADR-009).
7. **Policy for retained versions (Option F).** Independent of this ADR, but the answer changes how much the deps image saves.

## Relationship to #2063

#2063 is about finalising Bake cells independently when a sibling target fails, reusing per-arch images already pushed, while preserving publication invariants (multi-arch manifest, tags, receipt). It does not concern the contents of a layer. Its stated triggers (repeated measurable cost from aborted siblings, long recovery delays, a recurring failing target cancelling siblings) are not met by this incident: the failing leg was a flat-matrix timeout, not an aborted Bake cell, and #2063 says not to change flat-matrix recovery semantics. This ADR neither implements nor depends on #2063. If #2063 is implemented later, a deps image would simply be one more Bake target.

## Consequences

### Positive
- Removes the duplicated version-independent download that made the incident possible.
- Shrinks `github-runner` rebuilds after a base drift to the small final layers.
- Uses the dependency graph, bake handoff and cascade logic the repository already owns.
- One place to change OS packages, with its own scan and lineage.

### Negative / limitations
- New container to build, publish, scan, mirror and retain: more registry objects, more CI cells.
- A new link in the chain: a failed deps build blocks every `github-runner` Linux variant (the cascade is one level deeper).
- Open question 1 must be settled; the retained-version path is the riskiest part.
- Generator and template refactor (ADR-006 markers move between two templates); `variants.yaml` and bake HCL generation must learn the new container.
- Does not remove dependence on the Ubuntu mirror; it only reduces how often it is used.

## Rollout (once Accepted)

**Step 0 — verify the diagnosis and measure.** Check in the logs of recent flat-matrix github-runner legs whether the apt steps show `CACHED`, and read the manifest of `ghcr.io/<owner>/github-runner:buildcache` (what it currently contains). Record apt-layer time per variant and arch over the last N runs (the discipline #2063 asks for). If the shared-ref explanation does not hold, revisit this ADR before any code change.

**Step 1 — independent, low risk (own PR).** apt `Acquire::Retries` / `Acquire::http::Timeout` in the generator; make `scripts/open-dep-failure-issue.sh` report `cancelled`/timeout and job duration instead of "failure detail not provided".

**Step 2 — option G: retained versions through Bake.**
- Per-version runner context: stage `runner.tar.gz` per version (for example a bake named context per version, consumed with `COPY --from=`), instead of the single `github-runner/runner.tar.gz`. The "Prepare build contexts" loop in `auto-build.yaml` (amd64 and arm64) currently writes the same file once per version and would clobber it.
- Remove `build.bake_latest_only` for github-runner (`variants.yaml`, `helpers/bake-managed.sh`, `scripts/generate-bake-hcl.sh`) and update the bake bats suites that assert the retained cell stays in the matrix (`tests/unit/bake-managed.bats`, `tests/unit/bake-buildresult.bats`).
- Windows variants stay on the flat matrix (they use `runner.zip`, one version at a time).
- Check the bake job timeout against a cold run (all versions × variants in one job per arch).
- Validate on a forced drift: `bake --print`, then compare apt time per variant with Step 0.

**Step 3 — re-measure; decide on option E.** Adopt E only if repeated version-independent apt downloads or patch-cadence coupling remain material. If adopted: one deps cell per (distro, flavor, arch) as a Bake target, handed to the runner cells with `target:` contexts (ADR-013).

**Step 4 — documentation.** `README.md` container table (only if E adds a container), `docs/DOCUMENTATION_INDEX.md`, ADR-005/006 cross-references.

## Validation

- `docker buildx bake --print` shows `github-runner` targets with a `target:` context on the deps target.
- On a forced base drift, the number of apt downloads in the run equals the number of (distro, flavor, arch) deps cells, not that number × retained versions.
- Lineage for a runner image names the deps image digest.
- Unit tests (bats) for the generator split and the graph edge; mutation guard on the marker move.
