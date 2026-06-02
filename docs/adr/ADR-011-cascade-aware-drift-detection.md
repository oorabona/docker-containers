# ADR-011: Cascade-aware drift detection

**Status:** Accepted
**Date:** 2026-05-28
**Issues:** #532 follow-up (deferred cascade ordering)
**Supersedes:** None
**Siblings:** ADR-010 (drift detection), ADR-004 (build lineage tracking)

## Context

After ADR-010 / PR #532, the daily drift detection cron opens rebuild PRs when a container's
recorded base digest diverges from the current registry digest. However, project-internal
container dependencies create cascade ordering requirements:

- `wordpress` depends on our `php` container (base image `ghcr.io/oorabona/php:latest`)
- `web-shell` depends on our `debian` container
- `github-runner` depends on our `debian` container

When both `php` and `wordpress` drift on the same day, the cron opens two PRs. If `wordpress`'s
PR merges before `php`'s rebuild completes, the `wordpress` rebuild captures the **stale** `php`
digest. The next-day cron re-detects the same drift on `wordpress` — a 2-day cascade loop.

## Problem

Downstream containers rebuilding before their upstream rebuild completes causes:
1. Stale digest captured in new lineage entry
2. Next-day cron re-detects drift on the downstream container
3. Repeat indefinitely until they happen to merge in the right order

## Considered Options

**A: Declarative `depends_on` field in `variants.yaml`**
- Explicit, easy to query
- Maintenance burden: every new container must declare its dependencies
- Risk of stale metadata when a container's base image changes

**B: Infer DAG from lineage `base_image_ref` (CHOSEN)**
- Zero metadata maintenance — lineage already exists from build process
- Self-updating: next build automatically reflects new base image
- Validated against `./make list` (canonical container set) to exclude external upstream refs

**C: Open all PRs, keep current first-come-first-merged order**
- Already the current state — accepted as insufficient (produces cascade loops)

**D: Skip PR creation for downstream containers until upstream merges**
- Hides drift visibility — downstream operators cannot see that drift is queued
- Harder to implement (requires sequential job dependencies across runs)

**E: Open PRs + gate auto-merge on parent PR state (CHOSEN)**
- Visibility preserved: all drift PRs are opened immediately
- Cascades handled by the merge gate and the cascade-resolver workflow
- Downstream operator can see the full drift queue and manually unblock if needed

## Decision

### B — Infer DAG from lineage

`helpers/dependency-graph.sh` reads `.build-lineage/<container>-*.json` files and extracts
`base_image_ref` values that match one of:
- `ghcr.io/<owner>/<X>:tag` — GHCR-hosted project container
- `${REMOTE_CR}/<X>:tag` — CI variable form of the above
- `hub.docker.io/<owner>/<X>:tag` — Docker Hub project mirror

The extracted `<X>` is validated against `./make list` (the canonical container set). External
upstream refs (`library/alpine`, `hashicorp/terraform`, `mcr.microsoft.com/...`) match none of
the above patterns and are correctly excluded.

Fallback for containers with no lineage yet: parse `config.yaml` `build_args` values for the
same patterns. This ensures new containers (not yet built) are correctly included in the DAG.

Public API:
- `_depgraph_get_deps <container>` — direct project-internal deps (space-sep)
- `_depgraph_get_deps_transitive <container>` — transitive closure, leaves first
- `_depgraph_get_consumers <container>` — reverse lookup (who depends on X)
- `_depgraph_validate_no_cycles` — DFS-based cycle detection, exits 1 if cycle found

### E — Open PRs + gate auto-merge on parent PR state

**In `upstream-monitor.yaml` (two-job split)**:
1. `detect-digest-drift` emits `drift_matrix_leaves` (no internal deps) and `drift_matrix_consumers` (have internal deps)
2. `open-drift-prs-leaves` (job 1): processes leaf containers — no cascade gating needed, auto-merge immediately
3. `open-drift-prs-consumers` (job 2): `needs: [open-drift-prs-leaves]` — every leaf (parent) PR is created before any consumer matrix item starts
4. Within job 2, `_eval_parent_state` classifies each project-internal parent; if not `ready` → add `cascade:waiting-for-<parent>` label

**Parent-readiness — `_eval_parent_state` (fail-closed state machine)**: each internal parent of a drifting consumer is evaluated in order, defaulting to `in_flux` (wait) whenever the answer is uncertain:
- **State A — open drift PR?** `gh pr list --head update/base-digest-<parent> --label base-digest-drift --base master --state open` (fork PRs excluded). An open parent PR ⇒ `in_flux`. A `gh` failure ⇒ fail-closed (`return 2`; the cascade loop exits non-zero) — it must never silently fall through to State B.
- **State B0 — parent probe errored this run?** parent ∈ `CURRENT_ERROR_SET` ⇒ `in_flux` (unknown state).
- **State B — parent in the drift set?** parent ∉ `CURRENT_DRIFT_SET` (and no open PR, no probe error) ⇒ it was cleanly rebuilt in a prior run and GHCR holds the stable image ⇒ `ready`. parent ∈ `CURRENT_DRIFT_SET` but no open PR yet ⇒ conservative `in_flux`. `CURRENT_DRIFT_SET` is **repo-wide / unfiltered** (Defect E fix), so a scoped `workflow_dispatch` cannot false-negative a still-drifting parent into `ready`.
- **State C — no drift snapshot** (`CURRENT_DRIFT_SET` unset) ⇒ conservative `in_flux`.

A GHCR package-freshness probe was attempted (r26) and **reverted (r27, Defect O)**: `gh api users/<owner>/packages/container/<parent>/versions` returns the most-recently-*created* version regardless of tag, so a concurrent push of an unrelated tag (`php:8.4` while a child consumes `php:8.3`) yields a false-ready that could auto-merge a child against a stale parent. State B's drift-set membership is the safe substitute, regression-locked in `cascade-resolver.bats` (the function body must not call `packages/container`).

**Ordering across dependency depth**: the `needs: [open-drift-prs-leaves]` barrier guarantees leaf parents' PRs exist before consumers run, but `internal_deps` is **direct** parents only — so a consumer-of-consumer (A→B→C, with B and C both in the consumers job) is **not** ordered by the job split. Depth ≥ 2 is made safe by State B (C finds B in the repo-wide drift set → `in_flux` → `cascade:waiting-for-B`) plus the cascade-resolver unblocking C after B's image actually publishes — not by topological job ordering.

**In `cascade-resolver.yaml` (workflow)**:
- Trigger: `workflow_run` of "Auto Build & Push" on `master`, `conclusion == success` — fires only after the parent image is actually pushed to GHCR. (The earlier `pull_request.closed` trigger fired before the image existed, so a child rebuild could still pull the stale parent digest.)
- Identifies the parent from the triggering commit via `gh api commits/<sha>/pulls`: a PR whose head branch is `update/base-digest-<container>`, carries the `base-digest-drift` label, and has `merged_at` set (PR metadata, not the spoofable commit subject).
- Removes ONLY that parent's `cascade:waiting-for-<parent>` label from each waiting child, then **re-reads the child's labels live** and enables auto-merge only when no `cascade:waiting-for-*` labels remain (multi-parent gating, last-finisher race-safe).

### CLI validation: `./make list-deps <container>`

Local diagnostic command for operators and onboarding. Shows direct deps and transitive closure.
Reads from `.build-lineage/` (same data source as CI). Useful for:
- Verifying DAG before a merge
- Debugging why a PR has `cascade:waiting-for-X` label
- Onboarding new containers

## Architecture

```
.build-lineage/<container>-*.json
         │ base_image_ref
         ▼
helpers/dependency-graph.sh          ←── single source of truth
    _depgraph_get_deps()
    _depgraph_get_deps_transitive()
    _depgraph_validate_no_cycles()
         │
         ├── ./make list-deps <container>              (CLI DX)
         ├── detect-base-digest-drift.sh               (enriches JSON: internal_deps[])
         └── upstream-monitor.yaml
                   │
                   ├── detect-digest-drift              (emits drift_matrix_leaves + drift_matrix_consumers)
                   ├── open-drift-prs-leaves            (leaves: no internal deps; auto-merge immediately)
                   │     ▲ needs: [detect-digest-drift]
                   ├── open-drift-prs-consumers         (consumers: have internal deps)
                   │     ▲ needs: [detect-digest-drift, open-drift-prs-leaves]
                   │     │  → leaf parents' PRs exist before consumers run (depth ≥ 2 via State B + resolver)
                   │     └── _eval_parent_state (A: open PR → B0: probe error → B: drift-set → C: no snapshot; fail-closed)
                   │
                   └── cascade-resolver.yaml            (workflow_run on master build success → unblocks children once parent image publishes)
```

## Failure Modes

| Scenario | Behavior |
|----------|----------|
| Cycle in dep graph | `_depgraph_validate_no_cycles` exits 1; CI surface fails early |
| Parent PR abandoned (closed without merge) | Child retains `cascade:waiting-for-X` label; operator removes manually or re-runs cron |
| Parent drift never detected (registry outage) | Child auto-merges immediately (no open parent PR to block on) |
| New container with no lineage | Config.yaml fallback; `list-deps` and detector work correctly |
| `cascade:waiting-for-X` label missing from repo | `gh pr edit --add-label` creates it on-the-fly |

## Known Limitations

### Stale `cascade:waiting-for-<parent>` label on rare race window

A consumer drift PR can be opened with a `cascade:waiting-for-<parent>` label even when the
parent's rebuild has ALREADY landed, in the following narrow window:

1. Parent's drift PR was merged AND its master rebuild completed between `detect-digest-drift`'s
   snapshot and the consumer's evaluation in the same monitor run.
2. Consumer evaluator's State A sees no open PR (correct: PR was merged) but State B sees the
   parent in the stale `CURRENT_DRIFT_SET` snapshot (incorrect: parent is now rebuilt).
3. Consumer PR is created with `cascade:waiting-for-<parent>`.
4. `cascade-resolver` already fired for the parent's master rebuild before the consumer existed,
   so it never fires for this consumer.

The stranded label is cleared on the next monitor run OR by operator action
(`gh pr edit <N> --remove-label cascade:waiting-for-<parent>`).

A tag-specific cascade label scheme (`cascade:waiting-for-<parent>-<tag>`) combined with
per-tag GHCR queries would eliminate this race window. That requires:
- `detect-base-digest-drift` emitting per-variant drift records with `(container, tag)` granularity
- Consumer label application using the parent's specific tag (resolved from child's lineage
  `base_image_ref`)
- `_eval_parent_state` querying GHCR for `<parent>:<tag>` directly

A package-wide GHCR check was attempted (r26, Defect O) and reverted (r27): the
`/packages/container/<parent>/versions` API returns the most-recently-CREATED version
regardless of tag. A concurrent push of an unrelated tag (e.g. `php:8.4` while the child
consumes `php:8.3`) makes `.[0].updated_at > RUN_STARTED_AT` return true, yielding a
false-ready that allows the child to auto-merge against a stale parent image.

The per-tag label scheme is tracked as a future improvement (open an issue if this race
window produces repeated operator pain in practice).

### Stranded label on double `gh` failure in the resolver's live recheck

When a parent's master rebuild unblocks a child, `cascade-resolver` removes that parent's
wait label and then **re-reads the child's labels live** to decide whether all parents are
resolved. If that live re-read fails, it falls back to the pre-removal snapshot minus the
just-removed parent. In the narrow case where two parents finish near-simultaneously AND
both runs' live re-reads fail, each falls back to a snapshot that still shows the sibling's
label → neither enables auto-merge → the child is stranded. The direction is conservative
(never a premature merge against a stale parent), but because both parents have already
completed, no further `workflow_run` fires to self-heal this child — it clears on the next
monitor cron run or by operator action (`gh pr edit <N> --remove-label cascade:waiting-for-<parent>`),
same as the snapshot-race limitation above.

## Test Strategy

- `tests/unit/dependency-graph.bats` (14 tests): DAG inference, transitive closure, cycle detection,
  sidecar filtering, dedup, REMOTE_CR pattern, external namespace exclusion
- `tests/unit/make-list-deps.bats` (6 tests): CLI output format, validation, no-deps case, order
- `tests/unit/detect-base-digest-drift.bats` (+4 tests for internal_deps, +3 tests for matrix split):
  `internal_deps` field presence, empty for external-only, multi-dep arrays, unchanged container
  still has field; two-phase split (leaves/consumers jq selectors), backwards-compat csv aggregation
- `tests/unit/cascade-resolver.bats`: parent identification via PR metadata (branch +
  `base-digest-drift` label + `merged_at`; fork / non-merged / api-failure all fail-closed);
  `_eval_parent_state` States A/B0/B/C, including the **r27 regression-locks** asserting the
  `packages/container` GHCR API is NOT called; multi-parent live-recheck race (last-finisher
  enables auto-merge; recheck failure falls back to the snapshot decision); trust boundaries
  (fork `isCrossRepository` exclusion, label filter); Defect B/C/D/E/F/P/R fail-closed locks
- Manual validation: `./make list-deps <container>` for all 13 containers

## Current DAG (as of 2026-05-28)

| Container | Direct deps | Via |
|-----------|-------------|-----|
| wordpress | php | ghcr.io/oorabona/php:latest |
| web-shell | debian | ghcr.io/oorabona/debian:trixie (from lineage) |
| github-runner | debian | ghcr.io/oorabona/debian:trixie (from config.yaml) |
| all others | (none) | external upstream only |
