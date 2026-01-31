# ADR-004: Build Lineage Tracking

**Status:** Accepted
**Date:** 2026-01-31

## Context

When debugging container issues or verifying reproducibility, it's difficult to determine:
- Which base image version was used
- What build arguments were applied
- When the image was built
- Whether the image matches the current Dockerfile

## Decision

Every build emits a `.build-lineage/<container>.json` file containing full build metadata: version, tag, base image reference and digest, build arguments, platform, timestamps, and image ID.

These files are committed to the repository by the `commit-lineage` job in `auto-build.yaml`.

## Consequences

- **Traceability**: Full provenance chain from source to published image
- **Dashboard integration**: `generate-dashboard.sh` reads lineage for version mismatch detection
- **Git history**: Lineage changes create commits, providing a timeline of builds
- **Storage**: ~500 bytes per container per build, negligible
