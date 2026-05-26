# ADR-010: Chained-on-own marker (#531) and base-image digest drift detection (#532)

**Status:** Accepted
**Date:** 2026-05-27
**Issues:** #531, #532
**Supersedes:** None
**Siblings:** ADR-004 (build lineage tracking)

## Context

This ADR covers the final two pieces of the architectural series started in #530:

- **#530** established the "truth pipeline" — `base_image_ref` and `base_image_digest` are now written to lineage files at build time with correct concrete values (no `${...}` placeholders).
- **#531** introduced the `chained-on-own` concept: a marker file pattern for recording that a container is downstream of another project-built image.
- **#532** closes the loop: daily cron detects when the recorded base digest diverges from the current registry digest and opens PRs to trigger rebuilds.

## Problem

After #530, every lineage file records the exact base image digest used at build time. However, there was no mechanism to detect when the upstream base image was updated (security patches, point releases) without the downstream container being rebuilt. This creates a window where containers run with stale base images silently.

## Decision

### #531 — Chained-on-own marker

Containers built on top of other project-produced images (e.g., `wordpress` on `php`) write a `chained-on-own: true` flag in their lineage files. The drift detection cron uses this flag in PR bodies to document the cascade recommendation: merge upstream PR first.

### #532 — Digest drift detection cron

**Daily cron** (`upstream-monitor.yaml` `detect-digest-drift` job) runs after the existing dep-monitor jobs:

1. Restores the GHA lineage cache (`.build-lineage/` is gitignored; cache is the authoritative store).
2. Walks all non-sidecar `*.json` files via `is_lineage_sidecar()` helper (single source of truth in `helpers/lineage-utils.sh`).
3. For each entry, probes current digest via `docker manifest inspect <base_image_ref>` using the same extraction as the writer (`build-container.sh:272`).
4. Emits tri-state per variant: `drift` / `unchanged` / `error` / `legacy`.
5. Groups by container name; matrix-fans out to `open-drift-prs` job.

**One PR per drifted container** (not per variant): all drifted variants for a container appear in the same PR body. Branch name `update/base-digest-<container>` (no date suffix) → peter-evans upserts on re-run → idempotent.

**`LAST_REBUILD.md` reuse**: PR writes a `## base-digest-drift (YYYY-MM-DD)` section to the existing `<container>/LAST_REBUILD.md`. `auto-build.yaml` path filter (line 89) already watches this file — no new path-filter rule needed.

## Consequences

### Positive

- Stale base images are surfaced automatically within 24 hours of upstream publication.
- No new infrastructure required beyond existing GHA lineage cache.
- Loop closes correctly: drift → PR merged → rebuild → new lineage → next cron sees match → no PR.
- `is_lineage_sidecar()` helper eliminates regex scatter; all consumers agree on which files are sidecars.

### Negative / Limitations

- Cache miss on first run: if the lineage cache expired or was never populated (new repo setup), the cron emits a warning and opens no PRs. Self-heals on next build.
- 2-day cascade for chained-on-own containers: if A depends on B and both drift, two cron runs are needed to fully propagate. Mitigated by documenting in PR bodies.
- `--baseline-only` operator action required once after #532 merge to baseline pre-#530 legacy lineage files.

### Deferred

- `parent_lineage_digest` field for cascade-suppression (suppress A's drift PR when B's drift PR is open).
- Auto-merge for digest-only minor drifts (requires explicit policy).
- Per-arch digest tracking (current: image-index manifest digest, same as writer).

## Alternatives Considered

**A. Poll GHCR directly (without lineage cache).** Rejected: requires registry credentials in cron, complex auth, and doesn't correlate with what was actually built.

**B. Event-driven via registry webhooks.** Deferred: webhook infrastructure exceeds benefit at project scale; daily cron is sufficient for security-patch latency requirements.

**C. Embed drift check in auto-build.yaml.** Rejected: drift detection is independent of build events; adding it to auto-build would conflate concerns and run drift checks on every PR.

## Implementation

| File | Role |
|------|------|
| `helpers/lineage-utils.sh` | `is_lineage_sidecar()` — canonical sidecar predicate |
| `scripts/detect-base-digest-drift.sh` | Lineage walker, digest prober, tri-state emitter |
| `scripts/update-last-rebuild.sh` | Appends `## base-digest-drift` section to `LAST_REBUILD.md` |
| `.github/workflows/upstream-monitor.yaml` | `detect-digest-drift` + `open-drift-prs` jobs |
| `tests/unit/lineage-utils.bats` | Unit tests for `is_lineage_sidecar()` |
| `tests/unit/detect-base-digest-drift.bats` | BDD tests including mutation guards |
| `tests/fixtures/digest-drift/` | Captured manifest inspect responses + synthetic lineage |
