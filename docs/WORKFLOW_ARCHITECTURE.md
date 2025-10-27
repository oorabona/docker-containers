# 🏗️ Workflow Architecture - Docker Containers Automation

## 📊 Overview

This document describes the complete architecture of the Docker container automation system, including version detection, build, push, and dashboard updates.

## 🔄 Complete Automation Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    UPSTREAM VERSION MONITOR                          │
│                    (Cron: 2x/day)                                   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ check-upstream-      │
                    │ versions action      │
                    │                      │
                    │ Compare:             │
                    │ upstream vs          │
                    │ oorabona/* registry  │
                    └──────────┬───────────┘
                               │
                 ┌─────────────┴─────────────┐
                 │                           │
          ┌──────▼────────┐         ┌───────▼────────┐
          │ No Updates    │         │ Updates Found  │
          │ Available     │         │                │
          └───────────────┘         └───────┬────────┘
                                            │
                                            ▼
                                ┌───────────────────────┐
                                │ classify-version-     │
                                │ change.sh             │
                                │                       │
                                │ Determines: major vs  │
                                │ minor change          │
                                └───────┬───────────────┘
                                        │
                          ┌─────────────┴────────────┐
                          │                          │
                   ┌──────▼──────┐          ┌────────▼────────┐
                   │ MAJOR       │          │ MINOR/PATCH     │
                   │             │          │                 │
                   │ - Create PR │          │ - Create PR     │
                   │ - Add labels│          │ - Add labels    │
                   │ - Assign    │          │ - Auto-merge    │
                   │   owner     │          │   enabled       │
                   │ - Manual    │          │                 │
                   │   review    │          │                 │
                   └─────────────┘          └────────┬────────┘
                                                     │
                                                     ▼
                                            ┌────────────────┐
                                            │ PR Auto-Merged │
                                            │ to master      │
                                            └────────┬───────┘
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│                         AUTO-BUILD WORKFLOW                             │
│                 (Trigger: push to master)                              │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ detect-containers    │
                    │ action               │
                    │                      │
                    │ Detects modified     │
                    │ containers via diff  │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ build-container      │
                    │ action               │
                    │                      │
                    │ Matrix strategy:     │
                    │ Build each container │
                    └──────────┬───────────┘
                               │
                 ┌─────────────┴────────────┐
                 │                          │
          ┌──────▼────────┐        ┌────────▼─────────┐
          │ Build FAILED  │        │ Build SUCCESS    │
          │               │        │                  │
          │ - Retry once  │        │ - Push to GHCR   │
          │ - Exit on     │        │ - Push to Docker │
          │   failure     │        │   Hub            │
          └───────────────┘        └────────┬─────────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ update-dashboard│
                                   │ workflow        │
                                   │                 │
                                   │ ONLY if:        │
                                   │ - Build success │
                                   │ - Push to master│
                                   └────────┬────────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ Generate        │
                                   │ Dashboard       │
                                   │                 │
                                   │ - Analyze       │
                                   │   registries    │
                                   │ - Build Jekyll  │
                                   │ - Deploy to     │
                                   │   GitHub Pages  │
                                   └─────────────────┘
```

## 🎯 Workflow Details

### 1. upstream-monitor.yaml

**Triggers**:
- Cron: `0 6,18 * * *` (6am and 6pm UTC, 2x/day)
- Manual: `workflow_dispatch`

**Process**:
1. **check-upstream-versions**: Uses `make check-updates` script to:
   - Read `version.sh` from each container (upstream version)
   - Compare with `oorabona/*` on Docker Hub/GHCR (published version)
   - Return JSON with containers needing updates

2. **classify-version-change**: Determines change type:
   - `major`: Major version change or new container
   - `minor`: Minor/patch change

3. **Create Pull Request**: Creates PR with:
   - `LAST_REBUILD.md` file as marker
   - Title indicating type (🔄 Major or 🚀 Minor)
   - Description with change details

4. **Auto-merge** (if minor): Enables auto-merge on PR

**Outputs**:
- PR created and potentially auto-merged
- `LAST_REBUILD.md` contains rebuild history

### 2. auto-build.yaml

**Triggers**:
- `pull_request`: On modifications to Dockerfile, version.sh, etc.
- `push` (master): After PR merge
- `workflow_call`: Called by other workflows
- `workflow_dispatch`: Manual trigger

**Process**:

#### Job 1: detect-containers
- Uses `.github/actions/detect-containers`
- Detection strategies:
  - **workflow_dispatch with force_rebuild**: All containers
  - **workflow_dispatch with specific container**: Targeted container
  - **push/PR**: Git diff to detect modified files
  - **workflow_call**: Container passed as input

#### Job 2: build-and-push
- Matrix: One job per detected container
- Steps:
  1. **Checkout**: Clone repo
  2. **Login registries**: Docker Hub + GHCR (if push to master)
  3. **Build**: Uses `.github/actions/build-container`
     - On PR: Local build only (`--load`)
     - On push master: Build + Push (`--push`)
  4. **Retry**: If failure, retry once
  5. **Summary**: Generates GitHub summary with links to images

**Behavior by event**:
- **PR**: BUILD only (validation test)
- **Push master**: BUILD + PUSH (deployment)

#### Job 3: update-dashboard
**Strict condition**:
```yaml
if: |
  always() && 
  needs.build-and-push.result == 'success' &&
  github.event_name == 'push' &&
  github.ref == 'refs/heads/master'
```

**Why this condition?**
- Avoids updates during PRs (test mode)
- Ensures only successful builds trigger dashboard
- Confirms we're on master (production deployment)

### 3. update-dashboard.yaml

**Triggers**:
- `workflow_call`: Called by auto-build
- `push` (master): On docs/ or *.md modifications
- `workflow_dispatch`: Manual trigger

**Process**:

#### Job 1: build
1. **Generate dashboard**: Executes `generate-dashboard.sh`
   - Iterates through all containers
   - Calls `helpers/latest-docker-tag oorabona/<container>` for published version
   - Calls `version.sh` for upstream version
   - Compares and determines status (Up to date / Update available / Not published)
   - Generates `index.md` with Jekyll includes

2. **Build Jekyll**: Compiles static site
   - Uses `_config.yml` from `docs/site/`
   - Templates in `_layouts/` and `_includes/`
   - Generates `./_site`

3. **Upload artifact**: Prepares site for deployment

#### Job 2: deploy
**Condition**:
```yaml
if: github.event_name == 'push' || 
    github.event_name == 'workflow_dispatch' || 
    (github.event_name == 'workflow_call' && github.ref == 'refs/heads/master')
```

- Deploys to GitHub Pages
- URL: https://oorabona.github.io/docker-containers/

## 📝 LAST_REBUILD.md File

### Purpose
- **PR Marker**: GitHub requires at least 1 modified file to create a PR
- **Workflow Trigger**: Present in `auto-build.yaml` `paths`
- **Documentation**: Rebuild history with metadata and workflow links
- **PR Quality**: Auto-generated table format with links to workflow runs

### Format
```markdown
# Container Rebuild Information

| Field | Value |
|-------|-------|
| **Container** | `ansible` |
| **Version Change** | `12.0.0` → `12.1.0` |
| **Change Type** | `minor` |
| **Rebuild Date** | 2025-10-23T14:23:45Z |
| **Triggered By** | Upstream Monitor (automated) |
| **Reason** | 🚀 Minor/patch version update detected |
| **Detection Run** | [View Workflow](https://github.com/oorabona/docker-containers/actions/runs/123456) |

## Build Status

This file triggers the auto-build workflow when merged to master.
Build status will be available in GitHub Actions after merge.

## Next Steps

- ✅ **Auto-merge enabled** - will merge automatically once CI passes
- Build will trigger automatically on merge
```

### PR Labels & Assignment

**Automatic labels**:
- `automation` - All automated PRs
- `<container-name>` - Container being updated (e.g., `ansible`, `debian`)
- `major-update` or `minor-update` - Type of version change

**Auto-assignment**:
- **Major updates**: Automatically assigns repository owner for review
- **Minor updates**: No assignment (auto-merge enabled)

---
*Auto-generated by docker-containers automation system*
```

### Lifecycle
1. **Creation**: By `upstream-monitor` when update detected
2. **Commit**: In automatic PR
3. **Merge**: With PR (triggers `auto-build`)
4. **Persistence**: Remains in repo as rebuild trigger marker

**Note**: This file is created/updated per upstream version change as a PR trigger mechanism.

## 🔍 Version Source of Truth

### Upstream Versions (source)
- **Defined in**: `<container>/version.sh`
- **Strategies**:
  - Docker Hub API: `helpers/latest-docker-tag owner/image "pattern"`
  - PyPI: `helpers/python-tags` → `get_pypi_latest_version package`
  - GitHub Releases: GitHub API
  - Custom: Container-specific script

### Published Versions (what we deployed)
- **Source**: `oorabona/*` on Docker Hub and GHCR
- **Method**: `helpers/latest-docker-tag oorabona/<container> "pattern"`
- **Pattern**: Defined via `version.sh --registry-pattern`

### Comparison
```bash
# Dans make check-updates et generate-dashboard.sh
current=$(helpers/latest-docker-tag "oorabona/$container" "$pattern")
latest=$(cd $container && ./version.sh)

if [ "$current" != "$latest" ]; then
  # Update available!
fi
```

**Why oorabona/* and not upstream?**
- We compare our published version vs upstream
- Allows us to know if **we** need to rebuild
- Avoids unnecessary rebuilds if already up-to-date

## 🎯 Use Cases

### New Container
1. **Detection**: `current_version = "no-published-version"`
2. **Classification**: Treated as `major` (review required)
3. **PR**: Created without auto-merge
4. **Review**: Manual required
5. **Merge**: Triggers build + dashboard

### Minor Update
1. **Detection**: `current 1.0.0 → latest 1.0.1`
2. **Classification**: `minor`
3. **PR**: Created with auto-merge enabled
4. **Auto-merge**: After successful checks
5. **Build**: Automatic on master
6. **Dashboard**: Updated automatically

### Major Update
1. **Detection**: `current 1.0.0 → latest 2.0.0`
2. **Classification**: `major`
3. **PR**: Created without auto-merge
4. **Review**: Manual (possible breaking changes)
5. **Merge**: Manual after validation
6. **Build**: Automatic on master
7. **Dashboard**: Updated automatically

### Force Rebuild (manual)
1. **Trigger**: `workflow_dispatch` with `force_rebuild: true`
2. **Detection**: Ignores version comparison
3. **Build**: All containers (or specific)
4. **Dashboard**: Updated if push to master

## 🐛 Troubleshooting

### Dashboard not updated after build
**Symptom**: Container published on Docker Hub but dashboard shows old version

**Possible causes**:
1. ❌ Build from PR (no push to master)
2. ❌ `update-dashboard` condition not met
3. ❌ Docker Hub API cache (propagation delay)

**Solution**:
```bash
# Check workflow run
gh run list --workflow=auto-build.yaml

# Check if update-dashboard was called
gh run view <run-id> --log | grep "update-dashboard"

# Manual dashboard trigger
gh workflow run update-dashboard.yaml
```

### PR not created for new version
**Symptom**: Newer upstream version but no PR

**Possible causes**:
1. ❌ `version.sh` returns error
2. ❌ Incorrect registry pattern
3. ❌ API call timeout

**Solution**:
```bash
# Test locally
cd ansible
./version.sh  # Should return upstream version
./version.sh --registry-pattern  # Should return regex pattern

# Test comparison
./make check-updates ansible

# Check upstream-monitor logs
gh run list --workflow=upstream-monitor.yaml
```

### Build fails on PR
**Symptom**: Build fails only on PR, not locally

**Possible causes**:
1. ❌ Environment difference (GitHub Actions vs local)
2. ❌ Secrets/variables not available on PR fork
3. ❌ Registry authentication (normal on PR)

**Solution**:
- On PR, build should NOT push (normal behavior)
- Verify `BUILD_MODE=local` during PRs
- Logs in GitHub Actions summary

## 📊 Metrics & Monitoring

### Health Indicators
- **Build success rate**: Visible in GitHub Actions
- **Dashboard sync lag**: Compare registry vs dashboard
- **PR auto-merge rate**: minor updates (should be ~80%)
- **Version detection accuracy**: Upstream vs published

### Useful Commands
```bash
# List all workflow runs
gh run list --limit 50

# View run details
gh run view <run-id>

# Download logs
gh run download <run-id>

# Manual upstream monitor trigger
gh workflow run upstream-monitor.yaml

# Force rebuild all containers
gh workflow run auto-build.yaml -f force_rebuild=true

# Update dashboard
gh workflow run update-dashboard.yaml
```

## 🔐 Required Permissions

### GITHUB_TOKEN
- `contents: write`: Commit LAST_REBUILD.md, create PRs
- `packages: write`: Push to GHCR
- `pages: write`: Deploy GitHub Pages
- `pull-requests: write`: Manage PRs (create, merge, close)

### Secrets
- `DOCKERHUB_USERNAME`: Docker Hub username
- `DOCKERHUB_TOKEN`: Docker Hub authentication token

## 📚 References

- [GitHub Actions Docs](https://docs.github.com/en/actions)
- [Docker Buildx](https://docs.docker.com/buildx/)
- [Jekyll Documentation](https://jekyllrb.com/docs/)
- [GitHub Pages](https://docs.github.com/en/pages)

---

**Last Updated**: October 26, 2025  
**Author**: Docker Containers Automation System
