# ADR-012: Version drift guard — declared-vs-published version monitoring

**Status:** Accepted
**Date:** 2026-06-02
**Issues:** #558 (origin: postgis declared but not published), #563
**Supersedes:** None
**Siblings:** ADR-010 (base-image digest drift), ADR-011 (cascade-aware drift detection)

## Context

PR #502 introduced scope-aware builds: the CI matrix defaults to building only
`is_latest_version=true` entries rather than all retained versions. This is correct
for normal operation but creates a blind spot: a version can be declared in
`variants.yaml` (or `postgres/extensions/config.yaml`) yet never published to GHCR
because it was outside the build scope at the time of the bump.

Origin case: PR #558 added a new postgis version. The extension was correctly declared
in config.yaml, but the CI build was scoped to postgres only — postgis was skipped.
The declared version remained unpublished silently.

This pattern recurs whenever:
- A dep bump updates a declared version but the triggered build is scoped narrowly.
- A build fails mid-matrix after some versions have been pushed but not others.
- A manual scope filter (`scope_versions`, `scope_flavors`, `scope_extensions`) excludes
  a newly-bumped version.

## Problem

No existing mechanism detects the gap between "declared in config" and "published to
GHCR" for version tags. The digest-drift guard (ADR-010/ADR-011) only detects when a
*published* image's base digest changes — it cannot see unpublished versions at all.

## Decision

### The guard: `scripts/check-version-drift.sh`

A dedicated script compares declared versions (from `variants.yaml` and
`postgres/extensions/config.yaml`) against GHCR-published multi-arch manifests.

Output rows per version: `kind`, `name`, `declared`, `published`, `status`.

Status values:
- `in_sync` — declared version is published.
- `drift` — declared version absent from GHCR and outside the grace window.
- `in_flight` — declared version absent but bumped within the grace window (build in progress).
- `window_ok` — timescaledb version_set resolver: ceiling version is published.
- `window_empty` — timescaledb resolver failed or returned empty window.
- `error` — GHCR probe failed (fail-closed: treated as unknown, not clean).

Exit codes: 0 (clean), 1 (drift), 2 (probe error).

### Grace window (6 hours default)

A version bumped within the last 6 hours is classified `in_flight`, not `drift`.
This prevents false positives from the normal build pipeline latency (bump PR merged
→ auto-build triggered → image pushed can take 30–90 minutes for multi-arch builds
including postgres extensions).

The 6-hour window is intentionally generous: it covers retry scenarios, queued runners,
and slow extension compilations. It can be overridden per-run with `--grace-hours N`.

### Timescaledb resolver-window handling

The `timescaledb` extension uses a version_set resolver that produces a sliding window
of versions per PG major (not a single pinned version). The guard checks the ceiling
version (latest in the window) against GHCR. A missing ceiling → `drift` (or
`in_flight` within grace). An empty/failed resolver → `window_empty` (surfaced as a
warning, not drift, since the resolver failure itself is the actionable signal).

### Wiring 1: Post-build advisory assertion in `auto-build.yaml`

A step named "Check version drift (advisory)" is added to the `summary` job. It runs
after the existing build-failure issue step, for each container in the detected build
matrix.

- `continue-on-error: true` — never blocks master or marks the workflow run failed.
- On `drift` rows: calls `open_version_drift_issue` (added to
  `scripts/open-dep-failure-issue.sh`) to open or refresh a dedup'd GitHub issue.
- On `error` rows (probe failure): emits `::warning::` and skips that container.
- Container name passed via `$CONTAINER` env var (never `${{ matrix.* }}` in the
  shell body — GHA injection prevention).

### Wiring 2: Scheduled sweep in `.github/workflows/version-drift.yaml`

A daily workflow (`cron: '0 9 * * *'`, 9 AM UTC) runs `check-version-drift.sh
--mode sweep` across all containers and extensions.

- Scheduled at 9 AM UTC — after upstream-monitor (06:xx) completes so a version bump
  and its triggered build both land before the sweep runs.
- Also triggerable via `workflow_dispatch` with an optional `grace_hours` input.
- On `drift` rows: opens/refreshes a `version-drift,automation` issue via
  `open_version_drift_issue`.
- On probe `error` (exit 2): the sweep job **fails loudly** (non-zero exit). This is
  intentional — a broken probe means the guard has no visibility, so the operator
  must notice. The cron keeps running on subsequent days (GHA does not disable a
  workflow for a single failure).
- Permissions: `contents: read`, `issues: write`, `packages: read`.
- Uploads the raw drift JSON as a workflow artifact (7-day retention) for audit.

### Advisory-not-hard-fail decision

Version drift is surfaced as a GitHub issue rather than a build failure. Rationale:

1. The build itself succeeded — blocking master because a previously-declared retained
   version is missing would conflate two separate concerns.
2. The drift may be intentional (operator scoped a build narrowly on purpose).
3. The issue is actionable: operator can trigger a targeted rebuild or close the issue
   as intentional.
4. Probe errors (GHCR connectivity issues) must not gate master deploys.

The only exception is probe error in the **sweep** job (exit 2): that job failing loudly
is correct because its sole purpose is drift detection — a probe failure means the
sweep cannot do its job at all.

### Issue dedup (`open_version_drift_issue`)

New function in `scripts/open-dep-failure-issue.sh`. Deduplicates on labels
`version-drift,automation[,dep:<container>]`. Repeated runs post a comment on the
existing open issue rather than opening a duplicate. The `version-drift` label is
created on-the-fly if missing. Values flowing into `::` workflow commands are escaped
via `_escape_gha_command` (already in `check-version-drift.sh`).

## Out of scope (v1)

- **Reproducibility / cold-rebuild check**: verifying that a published image can be
  rebuilt from scratch with the current declared versions is not addressed here. That
  requires running an actual build, not just a registry probe.
- **Auto-trigger rebuild on drift**: the guard opens an issue; it does not auto-create
  a PR or trigger a rebuild. Intentional — the operator decides whether to rebuild or
  accept the gap.
- **Per-variant granularity**: the post-build step checks one tag per version (the
  default/base variant). Variant-level coverage (e.g., `full` flavor missing but `base`
  present) is deferred.

## Consequences

### Positive

- Closes the silent-miss gap introduced by #502 scoped builds.
- Advisory wiring means zero build-blocking risk for false positives.
- Sweep runs independently of the build pipeline, catching drift that post-build checks
  miss (e.g., drift introduced by a failed build from a previous week).
- Grace window prevents alert fatigue from normal build pipeline latency.
- Dedup prevents issue spam on repeated sweep runs.

### Negative / Limitations

- Post-build step adds ~10–30 seconds to the summary job per container (GHCR probe
  per version tag).
- First sweep after #563 merges may surface pre-existing drift for retained versions
  that were never built under the new scope-aware matrix. Operator should triage and
  close as intentional or trigger targeted rebuilds.
- The `COMMIT_SUBJECT` env var in both wiring steps is set to a stub value
  (`advisory-drift-check` / `scheduled-drift-sweep`) to satisfy source-time guards in
  `open-dep-failure-issue.sh` that are irrelevant to `open_version_drift_issue`.
  This is a known coupling artifact; a future refactor could split the file.
