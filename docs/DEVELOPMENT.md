# Development Guide

Internal documentation for building and maintaining container images. For user-facing documentation, see the container-specific README files.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         ./make                                   │
│  (Main entry point - orchestrates all build operations)         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐    ┌──────────────────────────────────┐  │
│  │  build-extensions │    │  build <container> <version>     │  │
│  │                   │    │                                   │  │
│  │  Builds extension │    │  Builds container variants       │  │
│  │  images and pushes│    │  using COPY --from= extensions   │  │
│  │  to registry      │    │                                   │  │
│  └────────┬──────────┘    └────────────────┬──────────────────┘  │
│           │                                 │                     │
│           ▼                                 ▼                     │
│  scripts/build-extensions.sh      scripts/build-container.sh    │
│           │                                 │                     │
│           ▼                                 ▼                     │
│  helpers/extension-utils.sh        helpers/variant-utils.sh     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Reference

### Local Development

```bash
# Build extensions for a version (builds + pushes to registry)
./make build-extensions postgres 17

# Build extensions locally only (no push)
./make build-extensions postgres 17 --local-only

# Build all container variants
./make build postgres 17

# Full workflow for a new PostgreSQL version
./make build-extensions postgres 16        # Step 1: Build & push extensions
./make build postgres 16                   # Step 2: Build all variants
```

### GitHub Actions

The `auto-build.yaml` workflow handles everything automatically:

1. Detects containers needing builds
2. Builds & pushes extensions (if container has `extensions/config.yaml`)
3. Builds all variants for each architecture
4. Creates multi-arch manifests

Trigger manually:
```bash
gh workflow run auto-build.yaml
```

## Extension System

### How Extensions Work

Extensions are pre-compiled PostgreSQL modules stored as individual container images in the registry. The main Dockerfile is a **template** with markers (`@@EXTENSION_STAGES@@` and `@@EXTENSION_COPIES@@`) that are replaced at build time with only the extensions compatible with the target flavor and PostgreSQL version.

```dockerfile
# Template markers in postgres/Dockerfile (replaced at build time):
# @@EXTENSION_STAGES@@   → FROM ext-image AS ext-name (one per extension)
# @@EXTENSION_COPIES@@   → COPY --from=ext-name lines (two per extension)

# Example: generated output for flavor=vector, pg=17
FROM ghcr.io/oorabona/ext-pgvector:pg17-0.8.1 AS ext-pgvector
# ...
COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/
COPY --from=ext-pgvector /output/lib/ /tmp/ext/pgvector/lib/
```

The generation uses a two-layer system:
1. **Generic template engine** (`helpers/template-utils.sh`): `expand_template()` replaces `@@MARKER@@` lines in any Dockerfile template with generated content. `has_template_markers()` detects templates.
2. **Postgres generator** (`generate_dockerfile()` in `helpers/extension-utils.sh`): computes extension-specific content (FROM stages, COPY instructions, runtime deps) and calls `expand_template()`.

`build_container()` dispatches automatically: if `extensions/config.yaml` exists, it uses the postgres generator. Other containers can provide a `generate-dockerfile.sh` script in their directory. The flavor→extension mapping is defined in `postgres/extensions/config.yaml` under the `flavors:` key.

### Extension Image Naming

```
ghcr.io/<owner>/ext-<name>:pg<major>-<version>

Examples:
  ghcr.io/oorabona/ext-pgvector:pg17-0.8.1
  ghcr.io/oorabona/ext-citus:pg16-13.2.0
  ghcr.io/oorabona/ext-timescaledb:pg17-2.24.0
```

### Adding a New Extension

1. **Create Dockerfile** in `<container>/extensions/dockerfiles/`:
   ```dockerfile
   # extensions/dockerfiles/Dockerfile.myext
   FROM postgres:${MAJOR_VERSION}-alpine
   ARG EXT_VERSION
   ARG EXT_REPO=org/myext

   RUN apk add --no-cache build-base git ...
   RUN git clone --branch v${EXT_VERSION} https://github.com/${EXT_REPO}.git
   RUN cd myext && make && make install DESTDIR=/install

   # Copy to standard output location
   RUN mkdir -p /output/extension /output/lib && \
       cp /install/usr/local/share/postgresql/extension/* /output/extension/ && \
       cp /install/usr/local/lib/postgresql/*.so /output/lib/
   ```

2. **Add to config.yaml**:
   ```yaml
   # extensions/config.yaml
   extensions:
     myext:
       version: "1.0.0"
       repo: "org/myext"
       priority: 50
       shared_preload: false  # true if needs shared_preload_libraries
   ```

3. **Add to flavors** in `config.yaml` — extensions are only included in flavors that list them:
   ```yaml
   flavors:
     full:
       - myext  # Add to relevant flavors
   ```

4. **Build and test**:
   ```bash
   ./make build-extensions postgres 17 --local-only
   ./make build postgres 17
   ```

### Disabling an Extension

Add `disabled: true` to the extension config:

```yaml
extensions:
  paradedb:
    version: "0.15.1"
    disabled: true  # Won't be built
    requires_glibc: true  # Note: Alpine uses musl
```

### Building an extension container through bake

An extension container's **final image** (the multi-stage build that consumes the
pre-built `ext-*` images via `FROM` / `COPY --from=`) builds through `docker buildx
bake` like the rest of the Linux fleet. The extension **compilation** stays its own
pipeline (`build-extensions` → `merge-extension-manifests`); only the final image
build is on bake. See `docs/adr/ADR-015-postgres-final-build-to-bake.md`.

This is a **reusable framework**, not a postgres special case. The pieces:

| Piece | What it does |
|-------|--------------|
| `<container>/extensions/config.yaml` | Marks the container as an *extension container* (drives the `extension_builds` detect output → gates the compilation jobs). |
| `build.bake_final_build: true` in `variants.yaml` | Marks the final image as bake-buildable. Combined with the activation flag, it admits the container into the bake graph (drives the `bake_final_builds` detect output). |
| `--include-final-build` (generator flag) | Per-run activation. The whole-fleet smoke and the normal fleet build never pass it, so the capability is **dormant** until a bake job opts in — a new extension container cannot perturb existing builds. |
| `<container>/generate-dockerfile.sh` | Thin bridge so the generic bake materializer can expand the `@@…@@` template via `generate_dockerfile()`. |
| `build.always_all_versions: true` | Routes every major (not just the latest) to bake, so the container does not split across the bake and matrix engines. |
| `base_suffix` in `variants.yaml` | The bake `VERSION` build arg carries it (e.g. `18` → `18-alpine`), matching the base image the Dockerfile pulls. |

The CI wiring keys off `extensions/config.yaml` presence and the `bake_final_build`
flag (via the `extension_builds` / `bake_final_builds` detect-containers outputs) —
**not** off the container name. The shared bake scan / attest / multi-arch-merge jobs
are generic over the build set, so a new extension container is covered with no
per-container jobs.

**Checklist — add a new extension container to bake:**

1. Give it `extensions/config.yaml` + per-extension Dockerfiles/resolvers (see *Adding a New Extension* above).
2. Add a `<container>/generate-dockerfile.sh` wrapper that sources `helpers/extension-utils.sh` and calls `generate_dockerfile <config> <template> <flavor> <major>` (mirror `postgres/generate-dockerfile.sh`).
3. In `variants.yaml`: set `build.bake_final_build: true` (and `build.always_all_versions: true` if every major must build), and `base_suffix` if the upstream base is suffixed (e.g. `-alpine`).
4. Add the container name to `bake_managed_containers` in `helpers/bake-managed.sh`.
5. No workflow edits: the extension-pipeline and bake jobs pick it up via the generic signals.

> Scope note: the extension image tag scheme is PostgreSQL-shaped (`ext-<name>:pg<major>`, `pg_major_version()`). Reusable as-is for a PostgreSQL-family container; a genuinely different engine would need that vocabulary parameterized (deferred — only postgres exists today).

## Variant System

### How Variants Work

Variants are defined in `variants.yaml` and allow building multiple flavors of a container from a single Dockerfile.

```yaml
# postgres/variants.yaml
base_suffix: "-alpine"  # Added to base image tag

versions:
  - tag: "17"
    variants:
      - name: base
        suffix: ""
        flavor: base
      - name: vector
        suffix: "-vector"
        flavor: vector
      - name: full
        suffix: "-full"
        flavor: full
```

### Output Tags

```
<major_version><variant_suffix><base_suffix>

Examples:
  17-alpine           (base variant)
  17-vector-alpine    (vector variant)
  17-full-alpine      (full variant)
```

### Adding a New Variant

1. **Add to variants.yaml**:
   ```yaml
   - name: myvariant
     suffix: "-myvariant"
     flavor: myvariant
     description: "My custom variant"
   ```

2. **Update Dockerfile** to handle the new flavor in the install script.

## Build Behavior

### Local vs CI

| Aspect | Local | GitHub Actions |
|--------|-------|----------------|
| Extension push | Yes (without `--local-only`) | Always |
| Extension tagging | Always (ghcr.io name for `COPY --from=`) | Always |
| Image pull | `--pull=never` (uses local) | Pulls from registry |
| Multi-arch | Single platform | amd64 + arm64 |
| Registry auth | Via `gh auth token` | Via `GITHUB_TOKEN` |

### Local-Only Mode

When using `--local-only`, extensions are:
1. **Built** as `localhost/ext-builder-<name>:pg<version>`
2. **Tagged** as `ghcr.io/<owner>/ext-<name>:pg<version>-<ext_version>`
3. **NOT pushed** to the registry

This allows the postgres build to find extensions via `COPY --from=ghcr.io/...` without requiring registry access.

A local `timeseries` or `full` postgres build resolves the retained TimescaleDB version set via skopeo (the documented local requirement, see `postgres/README.md`) or consumes a CI-produced version-set artifact. When the resolver is unavailable locally, the build does **not** silently produce a reduced-retention image — it fails fast asking for skopeo or the artifact. Install skopeo (`apt install skopeo` / `brew install skopeo`) and run the extension build before the postgres build.

### Required Permissions

For pushing to GHCR locally:
```bash
# Add write:packages scope
gh auth refresh -h github.com -s write:packages

# Login to registry
gh auth token | docker login ghcr.io -u <username> --password-stdin
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `./make` | Main entry point |
| `scripts/build-extensions.sh` | Build & push extension images |
| `scripts/build-container.sh` | Build container variants |
| `scripts/push-container.sh` | Push to registries |
| `scripts/check-version.sh` | Version discovery |
| `helpers/extension-utils.sh` | Extension image utilities |
| `helpers/variant-utils.sh` | Variant parsing utilities |
| `helpers/logging.sh` | Logging functions |

## Troubleshooting

### Extension build fails

```bash
# Check extension config
yq '.extensions.<name>' postgres/extensions/config.yaml

# Build with verbose output
./scripts/build-extensions.sh postgres --extension <name> --major-version 17
```

### Container build can't find extension

```bash
# Verify extension exists in registry
docker manifest inspect ghcr.io/oorabona/ext-<name>:pg17-<version>

# Or build locally first
./make build-extensions postgres 17 --local-only
```

### Permission denied on push

```bash
# Check current scopes
gh auth status

# Add write:packages scope
gh auth refresh -h github.com -s write:packages
```

### Build uses wrong extension version

Extension versions are defined in `extensions/config.yaml`. The Dockerfile template is generated with the correct versions at build time:

```bash
# Check what version will be used
yq '.extensions.<name>.version' postgres/extensions/config.yaml
```

## CI/CD Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `auto-build.yaml` | Push, PR, manual | Build & push containers |
| `upstream-monitor.yaml` | Schedule | Check for upstream updates |
| `update-dashboard.yaml` | Schedule, manual | Regenerate status dashboard |
| `cleanup-registry.yaml` | Manual | Clean old images |

### Manual Workflow Trigger

```bash
# Trigger auto-build
gh workflow run auto-build.yaml

# With specific inputs (if supported)
gh workflow run auto-build.yaml -f container=postgres
```
