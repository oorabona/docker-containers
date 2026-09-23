# ADR-002: Smart Rebuild Detection via Build Digest Labels

**Status:** Superseded (2026-09-23)
**Date:** 2026-01-31

## Context

CI rebuilds all detected containers on every push, even when only documentation or unrelated files changed. Full rebuilds of all containers take 20-40 minutes and waste compute resources.

## Decision

Compute a content-based digest from the build inputs (Dockerfile, variants.yaml, flavor) and store it as an OCI label (`build.digest`) on the published image. Before building, compare the computed digest against the published image's label. Skip the build if digests match.

Implementation in `helpers/build-cache-utils.sh`:
- `compute_build_digest()` — SHA256 of Dockerfile + variants.yaml + flavor string
- `should_skip_build()` — Compare local digest vs registry label

## Consequences

- **Savings**: Skips 60-80% of builds on typical pushes
- **Correctness**: Only skips when inputs are byte-identical; any Dockerfile change triggers rebuild
- **Limitation**: Does not detect base image updates (handled by upstream-monitor instead)
- **Label overhead**: Adds ~100 bytes per image manifest

## Superseded by #1588

#1588 removed the registry comparison and the resulting build skip. In sampled
master runs from 2026-09-18 through 2026-09-23, the skip never fired: roughly
20 build cells reported no digest label because the lookup examined a manifest
list while the label is on its per-architecture child. The digest also does not
cover every copied build-context file, so a changed file selected by container
detection could have been skipped. The digest remains a descriptive OCI image
label and build-lineage field; it is never compared with registry state to
skip, reuse, or reject an image, and a failed or empty computation still
refuses the build.
