# Workflow Architecture - Docker Containers Automation

## Overview

This document describes the complete CI/CD architecture: version detection, multi-platform builds, registry push, dashboard generation, and maintenance automation.

**Last Updated:** February 2026

## Complete Automation Flow

```
┌───────────────────────────────────────────────────────────────┐
│              UPSTREAM VERSION MONITOR                          │
│              (Cron: daily 6 AM UTC)                           │
│              upstream-monitor.yaml                            │
└─────────────────────────┬─────────────────────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
               │ check-upstream-     │
               │ versions action     │
               │                     │
               │ Compare: upstream   │
               │ vs registry tags    │
               └──────────┬──────────┘
                          │
            ┌─────────────┴─────────────┐
            │                           │
     ┌──────▼────────┐        ┌────────▼────────┐
     │ No Updates    │        │ Updates Found   │
     └───────────────┘        └────────┬────────┘
                                       │
                          ┌────────────▼────────────┐
                          │ classify-version-change  │
                          │ (major / minor / patch)  │
                          └────────────┬────────────┘
                                       │
                          ┌────────────▼────────────┐
                          │ close-duplicate-prs      │
                          │ Create PR with bump      │
                          │ Auto-merge if minor      │
                          └────────────┬────────────┘
                                       │
┌──────────────────────────────────────▼────────────────────────┐
│                    AUTO-BUILD PIPELINE                         │
│                    auto-build.yaml                            │
│                                                               │
│  Triggers: push (master), PR, workflow_call, manual           │
│                                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ detect-      │  │ cache-base-  │  │ build-extensions │   │
│  │ containers   │──│ images       │──│ (postgres ext)   │   │
│  └──────┬───────┘  └──────────────┘  └────────┬─────────┘   │
│         │                                      │              │
│         ▼                                      ▼              │
│  ┌────────────────────────────────────────────────────┐      │
│  │ build-and-push (matrix: per-container per-platform)│      │
│  │  amd64 runner ─────┐                               │      │
│  │  arm64 runner ─────┼──▶ push to GHCR + DockerHub   │      │
│  └────────────────────┼───────────────────────────────┘      │
│                       │                                       │
│  ┌────────────────────▼───────────────────────────────┐      │
│  │ create-manifest (multi-arch manifest list)          │      │
│  └────────────────────┬───────────────────────────────┘      │
│                       │                                       │
│  ┌────────────────────▼───────────────────────────────┐      │
│  │ commit-lineage (.build-lineage/ artifacts)          │      │
│  └────────────────────┬───────────────────────────────┘      │
│                       │                                       │
│  ┌────────────────────▼───────────────────────────────┐      │
│  │ update-dashboard (workflow_call)                     │      │
│  └────────────────────────────────────────────────────┘      │
└───────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────┐
│ SUPPORTING WORKFLOWS                                          │
│                                                               │
│  recreate-manifests       ─ Manifest-only (no rebuild)        │
│  shellcheck.yaml          ─ Lint all .sh on push/PR           │
│  validate-version-scripts ─ Test version.sh on PR             │
│  sync-dockerhub-readme    ─ Sync README to Docker Hub         │
│  cleanup-registry         ─ Monthly GHCR image cleanup        │
│  update-dashboard         ─ Jekyll site → GitHub Pages        │
└───────────────────────────────────────────────────────────────┘
```

## Workflows

### 1. auto-build.yaml (Main Pipeline)

**Triggers:** `push` (master), `pull_request` (container changes), `workflow_call`, `workflow_dispatch`

**Jobs:**

| Job | Purpose | Depends On |
|-----|---------|------------|
| `detect-containers` | Smart change detection via git diff or force input | - |
| `cache-base-images` | Cache postgres base images (avoids Docker Hub rate limits) | detect |
| `build-extensions` | Build PostgreSQL extension images (pgvector, etc.) | cache |
| `build-and-push` | Multi-platform builds per container (amd64 + arm64 runners) | extensions |
| `create-manifest` | Create multi-arch manifest lists and push | build |
| `commit-lineage` | Commit `.build-lineage/` JSON artifacts | manifest |
| `update-dashboard` | Trigger dashboard regeneration | commit |

**Key features:**
- Native multi-platform builds (separate amd64/arm64 runners, no QEMU)
- Smart rebuild detection via build digest labels
- Registry cache (`--cache-from/--cache-to type=registry`)
- Build lineage tracking (base image digest, build args, timestamps)

### 2. upstream-monitor.yaml

**Triggers:** `schedule` (6 AM UTC daily), `workflow_dispatch`

**Flow:**
1. `check-upstream-versions` composite action compares `version.sh` output vs published registry tags
2. `classify-version-change.sh` determines if update is major, minor, or patch
3. `close-duplicate-prs` action prevents PR duplication
4. Creates PR with version bump file changes
5. Auto-merge for minor/patch updates (skipped for major)

### 3. update-dashboard.yaml

**Triggers:** `workflow_call` (from auto-build), `push` (master, docs changes), `workflow_dispatch`

**Flow:**
1. Runs `generate-dashboard.sh` to produce Jekyll data files
2. Builds Jekyll site
3. Deploys to GitHub Pages

### 4. Recreate Manifests (`recreate-manifests.yaml`)

**Triggers:** `workflow_dispatch` only

Recreates multi-arch manifest lists without rebuilding containers. Useful when manifests need to be regenerated (e.g., after a manifest creation fix, or to sync Docker Hub with GHCR).

**Inputs:**
- `container` (optional): Specific container, or all if empty
- `registry`: `both` (default), `ghcr`, or `dockerhub`

**Flow:**
1. `detect-containers` action lists all containers/variants (force_rebuild=true)
2. `create-manifest` matrix creates manifest lists using `docker buildx imagetools create`
3. Docker Hub manifests use GHCR images as cross-registry sources

**Usage:**
```bash
# Recreate Docker Hub manifests for all containers
gh workflow run recreate-manifests.yaml -f registry=dockerhub

# Recreate manifests for a specific container on both registries
gh workflow run recreate-manifests.yaml -f container=postgres
```

### 5. Supporting Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `shellcheck.yaml` | push, PR | Lint all `.sh` scripts with shellcheck |
| `validate-version-scripts.yaml` | PR (version.sh changes) | Validate version.sh scripts can run |
| `sync-dockerhub-readme.yaml` | push (README changes) | Sync README.md to Docker Hub descriptions |
| `cleanup-registry.yaml` | schedule (monthly) | Delete old GHCR images per retention policy |

## Composite Actions

All located in `.github/actions/`:

| Action | Purpose |
|--------|---------|
| `detect-containers` | Smart container detection: git diff, force_rebuild flag, or explicit input; outputs JSON matrix |
| `build-container` | Builds single container with Docker Buildx for specified platform |
| `check-upstream-versions` | Compares upstream version.sh output vs published registry tags |
| `close-duplicate-prs` | Closes existing PRs for same container/version |
| `check-dependency-versions` | Checks 3rd party dependency versions against upstream releases |
| `update-version` | Updates container version files and creates commits |
| `docker-login` | Logs into GHCR (required) and Docker Hub (optional) |
| `setup-github-cli` | Ensures `gh` CLI is available for PR/merge operations |

## Local Scripts

### Build Pipeline (`scripts/`)

| Script | Purpose |
|--------|---------|
| `build-container.sh` | Orchestrates Docker Buildx builds, cache, build args, lineage |
| `build-extensions.sh` | Builds PostgreSQL extension images |
| `push-container.sh` | Pushes images to GHCR and Docker Hub |
| `check-version.sh` | Detects upstream versions via version.sh |

### Shared Utilities (`helpers/`)

| Helper | Purpose |
|--------|---------|
| `logging.sh` | Shared log/info/warn/error/debug output functions |
| `variant-utils.sh` | Read variants.yaml, determine container variants/flavors |
| `build-args-utils.sh` | Extract build arguments from config.yaml |
| `build-cache-utils.sh` | Compute build digests, check registry for skip-rebuild |
| `extension-utils.sh` | PostgreSQL extension image build helpers |
| `registry-utils.sh` | Docker Hub and GHCR API query utilities |
| `version-utils.sh` | Version detection with registry pattern fallback |
| `retry.sh` | Retry with exponential backoff for transient failures |
| `latest-docker-tag` | Get latest Docker tag matching regex from any registry |
| `latest-git-tag` | Get latest Git tag matching a regex pattern |
| `check-docker-tag` | Check if specific image tag exists in registry |
| `docker-registry` | Low-level Docker registry API queries |
| `docker-tag` | Get metadata about a Docker tag (digest, date) |
| `docker-tags` | List all tags for a Docker image via skopeo |
| `git-tags` | List available Git tags |
| `python-tags` | Query PyPI for latest Python package versions |
| `skopeo-squash` | Utility wrapper for skopeo operations |

## Version Source of Truth

```
Container version.sh
    │
    ├── version.sh (no args)          → Latest upstream version
    ├── version.sh --upstream         → Upstream download URL version
    ├── version.sh --registry-pattern → Regex for matching registry tags
    └── version.sh --check-updates    → Quick update check
```

Each container defines its own `version.sh` that queries the upstream source (GitHub releases, Docker Hub, PyPI, etc.) and returns version information.

Published versions are detected via `helpers/version-utils.sh` which calls `latest-docker-tag` with the container's registry pattern (or a semver fallback).

## Container Configuration

Each container directory may include:

| File | Purpose |
|------|---------|
| `Dockerfile` | Container build definition |
| `version.sh` | Upstream version detection script |
| `config.yaml` | Build configuration (base_image, build_args, schedules) |
| `variants.yaml` | Multi-variant definitions (e.g., postgres: base, vector, full) |
| `test.sh` | Container smoke tests |

## Build Lineage

Every build produces a `.build-lineage/<container>.json` artifact:

```json
{
  "container": "postgres",
  "version": "17-alpine",
  "tag": "17-alpine-full",
  "platform": "linux/amd64,linux/arm64",
  "build_digest": "sha256:...",
  "base_image_ref": "postgres:17-alpine",
  "base_image_digest": "sha256:...",
  "built_at": "2026-01-31T12:00:00+00:00",
  "build_args": {"PG_MAJOR": "17"}
}
```

This enables:
- Reproducible builds (exact base image pinning)
- Smart rebuild detection (skip if digest matches)
- Dashboard version mismatch detection
- Audit trail for container provenance
