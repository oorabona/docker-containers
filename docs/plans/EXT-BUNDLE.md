---
doc-meta:
  status: canonical
  scope: build
  type: specification
  created: 2026-02-02
  updated: 2026-02-02
  complexity: COMPLEX
---

# Specification: Extension Pipeline Refactoring

## 0. Quick Reference

| Item | Value |
|------|-------|
| Scope | postgres extension build pipeline |
| Complexity | COMPLEX |
| Blocks | 4 |
| Risk level | MEDIUM (existing CI pipeline change) |

## 1. Problem Statement

The current extension pipeline builds N individual Docker images (one per extension) and
pushes them to GHCR. The main `postgres/Dockerfile` used unconditional `FROM ext-*` stages
to pull each image. When an extension is incompatible with a PG version (e.g., Citus + PG 18),
the `FROM` fails because the image doesn't exist — even if the flavor doesn't need that extension.

This refactoring makes the Dockerfile a **template** that is dynamically generated at build time
to include only the extensions compatible with the target flavor and PostgreSQL version.

## 2. User Stories

AS A maintainer of docker-containers
I WANT extension FROM/COPY stages generated per flavor+PG version
SO THAT incompatible extensions don't block unrelated flavor builds.

AS A CI pipeline
I WANT the build system to automatically exclude incompatible extensions
SO THAT PG 18 builds succeed without manual intervention.

## 3. Architecture

### 3.1 Previous Architecture

```
config.yaml → build-extensions.sh → N individual Dockerfiles → N images
                                                                  ↓
postgres/Dockerfile ← FROM ext-pgvector ← FROM ext-citus ← ... (all unconditional)
                   ↓
              COPY --from=ext-* /output/ → /tmp/ext/
              case $FLAVOR → install_ext ...
```

### 3.2 Current Architecture (implemented)

```
config.yaml (flavors section) ──────────────────────────────┐
                                                            ↓
build-extensions.sh → N individual images (unchanged)    generate_dockerfile()
                              ↓                              ↓
postgres/Dockerfile.template ← @@EXTENSION_STAGES@@    (filtered FROM/COPY)
                             ← @@EXTENSION_COPIES@@
                   ↓
build_container() detects markers → generates temp Dockerfile → docker build
                   ↓
              case $FLAVOR → install_ext ... (unchanged, defensive)
```

### 3.3 Template-Based Dockerfile Generation

The main `postgres/Dockerfile` contains markers:
- `@@EXTENSION_STAGES@@` — replaced by `FROM ext-image AS ext-name` lines
- `@@EXTENSION_COPIES@@` — replaced by `COPY --from=ext-name` lines

At build time, `build_container()` in `scripts/build-container.sh`:
1. Detects markers via `grep -q '@@EXTENSION_STAGES@@'`
2. Calls `generate_dockerfile()` from `helpers/extension-utils.sh`
3. Generates a temp Dockerfile with only compatible extensions
4. Builds from the temp Dockerfile, then cleans up

### 3.4 Key Design Decisions

1. **Keep individual extension images** — Extension images (`ext-pgvector`, `ext-citus`, etc.)
   remain as individual images published to GHCR. No bundle images needed.

2. **Template Dockerfile** — Docker has no conditional COPY; templating the Dockerfile with
   markers is the cleanest solution for a shell-based project.

3. **Config.yaml as source of truth** — The `flavors:` section maps flavor → extension list.
   Extensions are filtered at generation time by `max_pg_version` and `disabled` status.

4. **Transparent generation** — `build_container()` handles detection and generation
   automatically. Non-postgres containers (no markers) pass through unchanged. CI needs
   minimal changes (just `yq` availability).

5. **Defensive install_ext** — The `case $FLAVOR` install logic in the Dockerfile is kept
   unchanged. `install_ext` checks `if [ -d "/tmp/ext/${ext}/extension" ]` and silently
   skips missing extensions. This provides a safety net for any filtering edge cases.

### 3.5 Flavor-Extension Mapping (config.yaml)

```yaml
flavors:
  base: []
  vector: [pgvector]
  analytics: [pg_partman, hypopg, pg_qualstats]
  timeseries: [timescaledb, pg_partman]
  distributed: [citus]
  full: [pgvector, pg_partman, hypopg, pg_qualstats, citus, timescaledb]
```

**Note:** This mapping must stay in sync with the `install_ext` case statement in
`postgres/Dockerfile`. Both locations have cross-reference comments.

## 4. Implementation Plan

### Block 1: Config + generation logic

**Files:**
- `postgres/extensions/config.yaml` — added `flavors:` section
- `helpers/extension-utils.sh` — added `get_flavor_extensions()`, `generate_dockerfile()`
- `postgres/Dockerfile` — converted to template with `@@EXTENSION_STAGES@@` and `@@EXTENSION_COPIES@@` markers

### Block 2: Build integration

**Files:**
- `scripts/build-container.sh` — sources `extension-utils.sh`, auto-generates Dockerfile when markers detected, with error handling and temp file cleanup

### Block 3: CI workflow update

**Files:**
- `.github/workflows/auto-build.yaml` — `yq` installation in `build-and-push` job, paths triggers for `config.yaml` and `extension-utils.sh`

### Block 4: Cleanup + docs

**Files:**
- `docs/DEVELOPMENT.md` — updated extension system documentation
- Shellcheck validation, end-to-end testing of all flavor×PG combinations

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Generated Dockerfile syntax error | CI fails | Validate generated Dockerfile locally; error check in build_container() |
| Flavor mapping drift (config.yaml vs Dockerfile) | Wrong extensions installed | Cross-reference comments in both files |
| Missing yq in CI runner | Build fails | yq installed via pinned action in build-and-push job |
| Missing config.yaml for template | Invalid Dockerfile | build_container() returns error if config missing |

## 6. Definition of Done

- [x] All blocks implemented
- [x] PG 18 builds succeed (base, vector, analytics, timeseries)
- [x] PG 17 all flavors succeed (including distributed, full)
- [x] PG 18 full correctly excludes Citus (5 extensions instead of 6)
- [x] shellcheck passes
- [x] /review clean (no blocking findings)
- [x] Documentation updated
