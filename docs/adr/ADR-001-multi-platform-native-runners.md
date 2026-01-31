# ADR-001: Native Multi-Platform Builds via Separate Runners

**Status:** Accepted
**Date:** 2026-01-31

## Context

Docker containers need to support both `linux/amd64` and `linux/arm64`. Two approaches exist:

1. **QEMU emulation** — Single runner builds both architectures via `docker buildx` with QEMU binfmt
2. **Native runners** — Separate amd64 and arm64 runners build natively, then a manifest list merges them

QEMU builds for arm64 on amd64 are 5-10x slower and occasionally produce incorrect binaries for complex compilation (e.g., PostgreSQL extensions with Rust/C code).

## Decision

Use separate native runners per platform. Each container is built in a matrix of `(container, platform)`. A final `create-manifest` job creates multi-arch manifest lists after all platform builds complete.

## Consequences

- **Build speed**: 3-5 minutes per container instead of 15-30 minutes with QEMU
- **Reliability**: No QEMU-related build failures or binary corruption
- **Cost**: Requires arm64 runner availability (GitHub-hosted or self-hosted)
- **Complexity**: Matrix strategy and manifest creation job add workflow complexity
- **Cache**: Each platform has its own registry cache key
