# ADR-002: Smart Rebuild Detection via Build Digest Labels

**Status:** Accepted
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
