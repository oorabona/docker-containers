# Architectural Decisions

Lightweight decision log for changes that don't warrant a full ADR.
Cross-reference: `docs/adr/` for major structural decisions.

---

## #530 — Per-variant base_image truth pipeline

### Design

Five atomic fixes address base_image_ref leaking `${...}` placeholders into lineage files:

- **A1** (`scripts/build-container.sh::_resolve_base_image` ~line 191): Extended the substitution pipeline with a `_BUILD_ARGS_RESOLVED` pass (Step 2.5). After CUSTOM_BUILD_ARGS overrides are applied, iterates the associative array populated by `_prepare_build_args` — up to 10 passes to resolve cross-arg chains (A→B→C). Covers ARGs from `config.yaml::build_args` that are invisible to both CUSTOM_BUILD_ARGS and Dockerfile ARG defaults.

- **A2** (`scripts/build-container.sh::_resolve_base_image` ~line 131, `build_container` caller ~line 456): `_resolve_base_image` is now called post-template-generation with `from_generated=1` (4th positional parameter). For template containers (web-shell, github-runner), the generated per-flavor Dockerfile's `FROM` line is the authoritative base image source. Calling before template generation reads the default-distro value from `config.yaml`, not the per-flavor value.

- **B** (`generate-dashboard.sh::resolve_lineage_file`): Lineage file lookup now uses the container's default variant (via an inline yq query equivalent to `default_variant()`) when no flavor-specific file is found, rather than falling back to unversioned or network-fetched data.

- **C** (`scripts/build-container.sh::_emit_build_lineage`): `jq -n` with `--arg` / `--argjson` replaces inline JSON string construction, eliminating shell-metacharacter injection and quoting hazards in the emitted lineage JSON.

- **D** (`scripts/build-container.sh::_resolve_base_image` ~line 260): `printf -v` replaces `eval` for appending the base digest to `label_args`. Removes the eval-based injection vector with no behavioral change.

- **E** (`scripts/build-container.sh::_emit_build_lineage`, `generate-dashboard.sh::resolve_lineage_file`): Lineage files now carry `lineage_schema_version: 2`. Dashboard read sanitizes v1 files (strips any surviving `${...}` placeholders, replaces with empty string) before surfacing to the UI.

### Rejected alternatives

**(a) Backfill corrupted lineage files in-repo.** Not viable: `.gitignore` lines 70-71 exclude the `.build-lineage/` directory from version control. Lineage files are build artifacts, not source. Patching them at rest would require a CI-run trigger per affected container anyway — identical cost to letting the next build self-heal.

**(b) Dashboard-side substitution (resolve `${...}` at regen time).** Rejected because `generate-dashboard.sh` does not have access to the build-time ARG values. The dashboard reads already-written lineage files; it cannot reconstruct the `_prepare_build_args` resolved set from `config.yaml` without re-implementing the entire build pipeline. The bug is a write-time omission — the fix belongs at write time (A1/A2).

**(c) Per-distro `yq` read at build time (alternative to A2 relocation).** Equivalent in outcome to relocating `_resolve_base_image` post-template-generation, but requires threading `flavor` as a new parameter through the call chain and adding a yq lookup that duplicates what `generate-dockerfile.sh` already does. The A2 relocation uses the generated Dockerfile as the single authoritative source, which is simpler and less coupled.

### lineage_schema_version: 2 — consumer audit

`lineage_schema_version: 2` is new as of #530. Audit of all `.build-lineage/*.json` consumers (scripts/, helpers/, .github/):

| Consumer | Fields read | Handles schema v2? |
|----------|-------------|-------------------|
| `generate-dashboard.sh` | all fields incl. `base_image_ref`, `lineage_schema_version` | Yes — primary consumer; sanitize-at-read keyed on placeholder presence, not version field |
| `scripts/enrich-lineage.sh` | `.container`, `.tag`, `.multi_arch_index_digest` | Yes — uses `// empty` guards; ignores unknown fields |
| `helpers/extension-duration-utils.sh` | `.duration_seconds` | Yes — uses `// 0` guard; ignores unknown fields |
| `.github/actions/build-container/action.yaml` | file existence check only (no jq field reads) | Yes — additive fields are transparent |

Schema v2 currently has only the dashboard as a semantic consumer of the new fields. Future tools that read `base_image_ref` or `lineage_schema_version` must handle the field with a `// default` guard for backward compatibility with v1 files still present in the GHA cache.

### Post-merge expectation

Affected containers (sslh, web-shell, wordpress) currently have v1 lineage files with `${...}` placeholders. Until their next CI rebuild writes a v2 file, the dashboard sanitize-at-read path (Fix E) will surface an empty `base_image_ref` rather than a raw placeholder. Each container self-heals on its next triggered build with no manual intervention required.

### Integration smoke origin

`tests/unit/dashboard-integration-smoke.bats` was added per `feedback_perf_integration_smoke_test.md`: a layer-shifting refactor (base_image written at build time, read at dashboard-regen time) requires an end-to-end mutation guard. Unit tests of each individual function are insufficient because the bug manifests at the seam between the write phase and the read phase. The smoke's SMOKE-01 and SMOKE-07 tests guard Fix A1 specifically: disabling the `_BUILD_ARGS_RESOLVED` substitution loop causes `base_image_ref` to read `${OS_IMAGE_BASE}:${OS_IMAGE_TAG}` in the written lineage file, which SMOKE-01 catches via a concrete-value assertion.

## #532 — Universal base-image digest drift detection cron

**Issue:** #532. Completes the 3-issue architectural series (#530 → #531 → #532).

### Problem

After #530 began recording `base_image_digest` in lineage files, there was no automated mechanism to detect when a container's base image had been updated upstream without the container being rebuilt. Stale base images accumulate security patches silently.

### Decision

Daily cron (via `upstream-monitor.yaml`) compares each container/variant's `base_image_digest` from the GHA lineage cache against the current registry digest via `docker buildx imagetools inspect --format '{{json .Manifest}}' | jq -r '.digest'` (canonical multi-arch image-index digest — order-independent, single source of truth matching `scripts/build-container.sh`). Drift opens one PR per drifted container listing all affected variants. Merging the PR updates `LAST_REBUILD.md` → `auto-build.yaml` path filter triggers rebuild → new lineage written → next-day cron sees match → no further PR.

### Key design choices

**Tri-state output** (`drift` / `unchanged` / `error` / `legacy`): probe failures are not collapsed to drift to avoid false-positive rebuilds. `legacy` status handles pre-#530 lineage without `base_image_digest`.

**Per-container grouping**: output is `[{container, variants[]}]` rather than one record per variant. This enables one PR per container (not one per variant), reducing PR noise.

**`is_lineage_sidecar()` helper** (`helpers/lineage-utils.sh`): single source of truth for identifying `.sbom.json`, `.changelog.json`, `.history.json`, `ext-*.json` files that should not be treated as container lineage. Eliminates regex scatter across consumers.

**`LAST_REBUILD.md` reuse**: the existing `<container>/LAST_REBUILD.md` pattern (written by upstream-monitor for version updates, watched by auto-build path filter) is reused with a distinct `## base-digest-drift (YYYY-MM-DD)` section header. No new marker file needed.

**Branch-upsert dedup** (`update/base-digest-<container>` — no date suffix): peter-evans/create-pull-request upserts the branch on re-run. N cron firings produce 1 open PR with the latest digest delta, not N PRs.

**`--baseline-only` flag**: suppresses real drift records, emits only `legacy` entries. Operator runs ONCE after #532 merge to baseline pre-#530 lineage files without flooding CI with drift PRs.

**Multi-arch index digest**: `docker buildx imagetools inspect --format '{{json .Manifest}}' <ref> | jq -r '.digest'` — same extraction as `scripts/build-container.sh`. Returns the image-index manifest digest, not a per-arch digest.

### Cascade pattern (chained-on-own)

If container A's base is container B (also project-produced), and both drift, two PRs open. Merging B's PR first avoids a 2-day cascade. PR body documents this. The `parent_lineage_digest` field for cascade-suppression is deferred to a follow-up issue.

### Rejected alternatives

**(a) Per-variant PRs.** Rejected: N variants per container would open N PRs, most for minor digest-only refreshes. Per-container grouping keeps PR volume manageable.

**(b) Auto-merge for digest-only drifts.** Deferred: requires explicit policy decision about risk tolerance for unreviewed base image changes.

**(c) Event-driven detection (registry webhooks).** Deferred: webhook infrastructure cost exceeds benefit at current project scale; daily cron is sufficient.
