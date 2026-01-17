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

Extensions are pre-compiled PostgreSQL modules stored as container images in the registry. The main Dockerfile uses `COPY --from=` to pull extension files.

```dockerfile
# Extension images are referenced in the Dockerfile
FROM ghcr.io/oorabona/ext-pgvector:pg17-0.8.1 AS ext-pgvector
FROM ghcr.io/oorabona/ext-citus:pg17-13.2.0 AS ext-citus

# Later, files are copied based on flavor
COPY --from=ext-pgvector /output/extension/ /tmp/ext/pgvector/extension/
COPY --from=ext-pgvector /output/lib/ /tmp/ext/pgvector/lib/
```

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

3. **Update Dockerfile** to include the extension in relevant flavors.

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

Extension versions are defined in `extensions/config.yaml`. The Dockerfile references these via build args:

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
