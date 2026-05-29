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
3. `open-drift-prs-consumers` (job 2): `needs: [open-drift-prs-leaves]` — by construction, all parent PRs are already created before any consumer matrix item starts
4. Within job 2, `_eval_parent_state` checks parent PR state (State 1) and GHCR image freshness (State 2); if in_flux → add `cascade:waiting-for-<parent>` label

**GHCR as source of truth (r20 simplification)**: the original implementation chained two GitHub API queries (`gh api commits?path=...` + `gh api actions/runs?head_sha=...`) to indirectly answer "is the parent's rebuild done?". This introduced two failure classes:
- **M2 aged-out deadlock**: Actions runs vanish after 90-day retention → no run found → conservative `in_flux` → permanent cascade label.
- **M1 multi-level matrix race**: matrix order is not a topological sort, so consumer-of-consumer scenarios (A→B→C) had ordering races where C evaluated B's state before B's run finished.

The fix: GHCR IS the source of truth. `gh api users/<owner>/packages/container/<parent>/versions` returns the most-recent version's `updated_at` timestamp. Compared lexicographically against `GITHUB_RUN_STARTED_AT` (ISO 8601 sorts correctly as a string): newer → ready, older → in_flux. Both M1 and M2 dissolve because the signal is external (GHCR) and not coupled to matrix execution timing or Actions retention. Net: ~55 LOC removed, 5-state evaluation collapsed to 2 states, 1 API query per parent instead of 2.

**Topological ordering by construction**: the `needs:` chain replaces the former post-hoc cleanup approach (State 0 loop + reconciliation job). No race window exists — job 2 cannot start until job 1 finishes.

**In `cascade-resolver.yaml` (workflow)**:
- Trigger: `pull_request.closed` on master, filtered to `base-digest-drift` PRs
- Extracts `container:<name>` label from merged parent PR
- Finds all open PRs with `cascade:waiting-for-<name>` label
- Enables auto-merge + removes cascade label + posts comment

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
                   │     │  → topological invariant true by construction
                   │     └── _eval_parent_state (State 1: open PR / State 2: GHCR timestamp)
                   │
                   └── cascade-resolver.yaml            (unblocks children when parent merges)
```

## Failure Modes

| Scenario | Behavior |
|----------|----------|
| Cycle in dep graph | `_depgraph_validate_no_cycles` exits 1; CI surface fails early |
| Parent PR abandoned (closed without merge) | Child retains `cascade:waiting-for-X` label; operator removes manually or re-runs cron |
| Parent drift never detected (registry outage) | Child auto-merges immediately (no open parent PR to block on) |
| New container with no lineage | Config.yaml fallback; `list-deps` and detector work correctly |
| `cascade:waiting-for-X` label missing from repo | `gh pr edit --add-label` creates it on-the-fly |

## Test Strategy

- `tests/unit/dependency-graph.bats` (14 tests): DAG inference, transitive closure, cycle detection,
  sidecar filtering, dedup, REMOTE_CR pattern, external namespace exclusion
- `tests/unit/make-list-deps.bats` (6 tests): CLI output format, validation, no-deps case, order
- `tests/unit/detect-base-digest-drift.bats` (+4 tests for internal_deps, +3 tests for matrix split):
  `internal_deps` field presence, empty for external-only, multi-dep arrays, unchanged container
  still has field; two-phase split (leaves/consumers jq selectors), backwards-compat csv aggregation
- `tests/unit/cascade-resolver.bats` (r20 GHCR-based tests): State 1 (open PR), State 2 (GHCR
  fresh/stale/absent/api-error), trust boundaries (fork exclusion, label filter), multi-level DAG
  simulation (matrix-order independence), packages/container API called (not commits/runs APIs),
  two-phase structural invariants (no `CURRENT_DRIFT_SET` loop, State 1 via gh pr list)
- Manual validation: `./make list-deps <container>` for all 13 containers

## Current DAG (as of 2026-05-28)

| Container | Direct deps | Via |
|-----------|-------------|-----|
| wordpress | php | ghcr.io/oorabona/php:latest |
| web-shell | debian | ghcr.io/oorabona/debian:trixie (from lineage) |
| github-runner | debian | ghcr.io/oorabona/debian:trixie (from config.yaml) |
| all others | (none) | external upstream only |
