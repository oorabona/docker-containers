# ADR-014: Dependency Tracking & Supply-Chain Strategy

- **Status:** Accepted
- **Date:** 2026-06-20
- **Tracking:** [#801](https://github.com/oorabona/docker-containers/issues/801)
- **Supersedes/relates:** complements ADR-002 (smart rebuild detection), ADR-010/011 (base-image digest lineage), ADR-013 (bake migration)

## Context

Issue #801 started as a dependency-coverage audit: *are all application dependencies (direct and transitive) tracked so updates are triggered when needed?* The audit confirmed direct dependencies are well covered by the bespoke `upstream-monitor` system (per-container `version.sh` + `config.yaml::dependency_sources`), and surfaced two open questions:

1. **Transitive dependencies** (pip/gem/cargo packages pulled in by direct deps) are not individually monitored — should we adopt lockfiles + Dependabot/Renovate to track and remediate them?
2. **Reproducibility / supply-chain provenance** is rising in importance (Nix, SLSA, Sigstore) — is there a gain (e.g. base-image digest pinning) that justifies the cost?

Rather than refactor first, we investigated how the ecosystem solves these (multi-source research + an empirical backtest), explicitly to avoid a refactor whose ROI is negative.

## Decision

### 1. Keep `upstream-monitor`; do **not** replace it with Renovate/Dependabot

A capability map of `upstream-monitor` found ~10 domain-specific layers a generic bot has no model for: multi-version retained builds with sliding-window rotation, the timescaledb version-set resolver (derived from a *foreign* image's tags) with self-healing Dockerfile generation, base-image **digest-drift detection on mutable tags** with topology-aware cascade ordering, coupled-atomic `updates_with`/`tracks_with` dependency pairs (a version bump and its companion checksum must change together or the build breaks), the lifecycle taxonomy (`stable-pin` with expiry, `eol-migrate`, liveness-URL checks), failure-attribution issue lifecycle, and the `REMOTE_CR` rate-limit-aware GHCR mirror. A generic bot could only replace the simple single-version bumps — which `upstream-monitor` already does well.

Renovate **is** fully open-source (AGPL-3.0, no crippling of self-hosted advanced features), so licensing is not the blocker. Replacement is rejected on **ROI**: it would shed the bespoke layers that are the system's reason for existing.

### 2. Do **not** introduce transitive-dependency lockfiles (Gemfile.lock / requirements.txt) for monitoring

An empirical backtest (old jekyll baseline → `bundle lock` + `bundle-audit` + `bundle outdated`) showed: because we do **not** commit a lockfile, `gem install`/`bundle install` resolves transitives **fresh at every build** → they are always current → there is no transitive staleness to monitor. A committed lock would **freeze** transitives, *introducing* the staleness a bot then has to fix. The only CVE the backtest surfaced was in a **direct** dep (`webrick`), which `upstream-monitor` already tracks. Combined with detection already provided by **syft SBOM + Trivy**, the transitive-lockfile gap is largely illusory for our rebuild-from-source model, and the literature shows transitive-CVE PR streams are the noisiest / lowest-signal part of dependency automation.

### 3. Do **not** pin base-image digests in Dockerfiles

All major curated-image publishers (Docker Official Images, Chainguard, Bitnami, linuxserver.io) use **mutable base tags** in source; provenance is handled at the **output** (attestation), not the **input** (Dockerfile pin). SLSA does not require source-pinning at any level (`resolvedDependencies` recorded at build time satisfies L1–L3). For a project that already has **digest-drift detection + rebuild**, source-pinning is redundant churn (our drift detection triggering a rebuild is functionally equivalent to a digest-update PR, but automated and source-churn-free). This preserves the deliberate design choice: the GHCR mirror does the rate-limit/availability work once, the repo stays "always latest" with no per-update source commits.

### 4. Close the genuine direct-dependency gaps in the existing system

Add to `dependency_sources` / `version.sh` (not a new tool):
- **postgres/paradedb Rust toolchain** — `rustup` currently installs *whatever* stable Rust exists at build time (`postgres/extensions/build/paradedb.Dockerfile`); pin `RUST_VERSION` and track it. **Highest priority** (a stable Rust release can silently break the pgrx build).
- **cargo-pgrx** — pinned from ParadeDB's `Cargo.toml` but invisible to monitoring; surface it.
- **github-runner VS Build Tools** — downloaded from the floating `aka.ms/vs/17/release` URL; pin/track if feasible.

### 5. Add a **signed build-provenance attestation** (the one supply-chain upgrade)

Current posture: SBOM is **Sigstore-signed** (`actions/attest-sbom`), but build **provenance is absent/unsigned** and the `base_image_digest` lives only in an **unsigned** `.build-lineage/*.json` + an OCI label. Add `actions/attest-build-provenance` after push on both the flat-matrix and bake paths, using the already-computed `oci_subject_digest` as subject and including `base_image_digest` as a predicate (the action does not capture it automatically; note `crane flatten` destroys BuildKit's native attestation layer, so the standalone attest action — which records to the GitHub attestation API + Rekor — is the right mechanism). This captures, in a cryptographically signed, **churn-free** attestation, the data we already record unsigned — lifting us to a clean SLSA Build L2/L3.

### 6. (Optional, threat-model-gated) Verify base digests at the mirror-seed boundary

The only thing source-pinning does that attestation does not is **prevent** (not just detect) a poisoned mutable-tag pull (the Trivy/KICS 2026 attacks). Our GHCR mirror largely neutralizes this; the residual window is the seed job pulling from Docker Hub. If this threat is in scope, verify/pin the digest **at the mirror-seed step** (a single choke point) rather than in N Dockerfiles — prevention without Dockerfile churn.

## Alternatives considered

| Alternative | Verdict | Why |
|---|---|---|
| Lockfiles + Dependabot/Renovate for transitives | Rejected | Backtest: fresh resolution already keeps transitives current; a lock introduces the staleness; detection already in SBOM+Trivy; high PR-noise / low signal |
| Replace `upstream-monitor` with Renovate | Rejected | ROI<0: ~10 bespoke layers Renovate cannot model (mechanism, not licensing — Renovate is fully OSS) |
| Pin base-image digests in Dockerfiles | Rejected | Net-negative churn; redundant with drift-detection; not required by SLSA; industry leaders use mutable tags |
| Bit-for-bit reproducible builds (Nix/SOURCE_DATE_EPOCH) | Rejected | High effort; ~2.7% of Dockerfiles achieve it industry-wide; marginal value over SBOM+attestation for our threat model |
| Signed build-provenance attestation | **Accepted** | Churn-free; closes the unsigned-lineage gap; SLSA L2/L3; we already have ~80% of the stack |

## Consequences

- **No architectural change.** `upstream-monitor`, the variant-matrix retained builds, base-digest-drift, and the GHCR mirror remain as-is — validated as the recognized best-practice pattern for curated multi-version images.
- **Additive CI work** (tracked in #801): the signed build-provenance step (both build paths) and the three direct-dep additions.
- **Meta-lesson:** the step-back research repeatedly concluded that what was already built is the SOTA pattern; the durable value of this ADR is preventing re-litigation of "should we adopt lockfiles / Renovate / digest-pinning" in future.

## References

- SLSA v1.2 spec (`resolvedDependencies` best-effort through Build L3; hermetic/pinning deferred).
- Chainguard reproducible-image-builds (attestation over source-pinning); Docker Official Images, Bitnami, linuxserver.io (mutable tags in source).
- Dependabot/Renovate transitive behavior + the "other ecosystems can't bump a transitive needing a parent" limitation.
- Empirical backtest (this investigation): old jekyll baseline, `bundle-audit`/`bundle outdated`.
- Detailed reasoning and source lists are retained in the project's memory notes for #801.
