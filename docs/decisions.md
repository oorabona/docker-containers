# Architectural Decisions

Lightweight decision log for changes that don't warrant a full ADR.
Cross-reference: `docs/adr/` for major structural decisions.

---

## #530 — Per-variant base_image truth pipeline

### Design

Five atomic fixes address base_image_ref leaking `${...}` placeholders into lineage files:

- **A1** (`scripts/build-container.sh::_resolve_base_image` ~line 191): Extended the substitution pipeline with a `_BUILD_ARGS_RESOLVED` pass (Step 2.5). After CUSTOM_BUILD_ARGS overrides are applied, iterates the associative array populated by `_prepare_build_args` — up to 10 passes to resolve cross-arg chains (A→B→C). Covers ARGs from `config.yaml::build_args` that are invisible to both CUSTOM_BUILD_ARGS and Dockerfile ARG defaults.

- **A2** (`scripts/build-container.sh::_resolve_base_image` ~line 131, `build_container` caller ~line 456): `_resolve_base_image` is now called post-template-generation when `_RESOLVE_FROM_GENERATED=1`. For template containers (web-shell, github-runner), the generated per-flavor Dockerfile's `FROM` line is the authoritative base image source. Calling before template generation reads the default-distro value from `config.yaml`, not the per-flavor value.

- **B** (`generate-dashboard.sh::resolve_lineage_file`): Lineage file lookup now uses the container's default variant (via `variant_property default_variant`) when no flavor-specific file is found, rather than falling back to unversioned or network-fetched data.

- **C** (`scripts/build-container.sh::_emit_build_lineage`): `jq -n` with `--arg` / `--argjson` replaces inline JSON string construction, eliminating shell-metacharacter injection and quoting hazards in the emitted lineage JSON.

- **D** (`scripts/build-container.sh::_resolve_base_image` ~line 260): `printf -v` replaces `eval` for appending the base digest to `label_args`. Removes the eval-based injection vector with no behavioral change.

- **E** (`scripts/build-container.sh::_emit_build_lineage`, `generate-dashboard.sh::resolve_lineage_file`): Lineage files now carry `lineage_schema_version: 2`. Dashboard read sanitizes v1 files (strips any surviving `${...}` placeholders, replaces with empty string) before surfacing to the UI.

### Rejected alternatives

**(a) Backfill corrupted lineage files in-repo.** Not viable: `.gitignore` lines 70-71 exclude the `.build-lineage/` directory from version control. Lineage files are build artifacts, not source. Patching them at rest would require a CI-run trigger per affected container anyway — identical cost to letting the next build self-heal.

**(b) Dashboard-side substitution (resolve `${...}` at regen time).** Rejected because `generate-dashboard.sh` does not have access to the build-time ARG values. The dashboard reads already-written lineage files; it cannot reconstruct the `_prepare_build_args` resolved set from `config.yaml` without re-implementing the entire build pipeline. The bug is a write-time omission — the fix belongs at write time (A1/A2).

**(c) Per-distro `yq` read at build time (alternative to A2 relocation).** Equivalent in outcome to relocating `_resolve_base_image` post-template-generation, but requires threading `flavor` as a new parameter through the call chain and adding a yq lookup that duplicates what `generate-dockerfile.sh` already does. The A2 relocation uses the generated Dockerfile as the single authoritative source, which is simpler and less coupled.

### Post-merge expectation

Affected containers (sslh, web-shell, wordpress) currently have v1 lineage files with `${...}` placeholders. Until their next CI rebuild writes a v2 file, the dashboard sanitize-at-read path (Fix E) will surface an empty `base_image_ref` rather than a raw placeholder. Each container self-heals on its next triggered build with no manual intervention required.

### Integration smoke origin

`tests/unit/dashboard-integration-smoke.bats` was added per `feedback_perf_integration_smoke_test.md`: a layer-shifting refactor (base_image written at build time, read at dashboard-regen time) requires an end-to-end mutation guard. Unit tests of each individual function are insufficient because the bug manifests at the seam between the write phase and the read phase. The smoke's SMOKE-01 and SMOKE-07 tests guard Fix A1 specifically: disabling the `_BUILD_ARGS_RESOLVED` substitution loop causes `base_image_ref` to read `${OS_IMAGE_BASE}:${OS_IMAGE_TAG}` in the written lineage file, which SMOKE-01 catches via a concrete-value assertion.
