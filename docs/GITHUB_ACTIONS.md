# GitHub Actions Reference

## Available Workflows

### 1. Upstream Version Monitor

**File**: `.github/workflows/upstream-monitor.yaml`

**Purpose**: Automatically monitors upstream sources for version updates and creates pull requests.

#### Triggers
- **Schedule**: Runs twice daily (6 AM and 6 PM UTC)
- **Manual**: Workflow dispatch with configurable inputs

#### Inputs
```yaml
container:
  description: Specific container to check (leave empty for all)
  required: false
  type: string

create_pr:
  description: Create PR for version updates
  required: false
  default: true
  type: boolean

debug:
  description: Enable debug output
  required: false
  default: false
  type: boolean
```

#### Outputs
- Container update summary in GitHub Actions summary
- Pull requests for version updates
- Build trigger for updated containers

### 2. Auto Build & Push

**File**: `.github/workflows/auto-build.yaml`

**Purpose**: Builds and pushes containers when changes are detected.

#### Triggers
- **Push**: To main/master branches affecting container files
- **Pull Request**: To main/master branches
- **Schedule**: Twice daily for upstream updates
- **Manual**: Workflow dispatch

#### Features
- Multi-architecture builds (amd64, arm64)
- Docker layer caching
- Registry push automation
- Build matrix for parallel execution

### 3. Version Script Validation

**File**: `.github/workflows/validate-version-scripts.yaml`

**Purpose**: Validates that all version.sh scripts are functional.

## Available Actions

### 1. Check Upstream Versions

**Path**: `.github/actions/check-upstream-versions`

**Purpose**: Checks for upstream version updates for containers.

#### Inputs
```yaml
container:
  description: Container to check (optional)
  required: false
```

#### Outputs
```yaml
containers_with_updates:
  description: JSON array of containers with updates
update_count:
  description: Number of containers with updates
version_info:
  description: JSON object with version information
```

### 2. Update Version

**Path**: `.github/actions/update-version`

**Purpose**: Updates a container's version.sh file with a new version.

#### Inputs
```yaml
container:
  description: Container name to update
  required: true
new_version:
  description: New version to set
  required: true
commit_changes:
  description: Whether to commit the changes
  required: false
  default: 'false'
```

#### Outputs
```yaml
updated:
  description: Whether the version was actually updated
old_version:
  description: Previous version before update
skip_reason:
  description: Reason for skipping if applicable
```

### 3. Build Container

**Path**: `.github/actions/build-container`

**Purpose**: Builds a specific container with optimizations.

### 4. Detect Containers

**Path**: `.github/actions/detect-containers`

**Purpose**: Detects all containers in the repository with changes.

### 5. Close Duplicate PRs

**Path**: `.github/actions/close-duplicate-prs`

**Purpose**: Manages and closes duplicate version update PRs.

## Usage Examples

### Manual Upstream Check

```bash
# Trigger upstream monitoring for all containers
gh workflow run upstream-monitor.yaml

# Trigger for specific container with debug
gh workflow run upstream-monitor.yaml \
  --field container=wordpress \
  --field debug=true \
  --field create_pr=false
```

### Manual Build

```bash
# Build all containers
gh workflow run auto-build.yaml

# Force rebuild specific container
gh workflow run auto-build.yaml \
  --field container=wordpress \
  --field force_rebuild=true
```

### Using Actions in Other Workflows

```yaml
- name: Check for updates
  uses: ./.github/actions/check-upstream-versions
  with:
    container: wordpress

- name: Update version
  uses: ./.github/actions/update-version
  with:
    container: wordpress
    new_version: "6.1.1"
    commit_changes: true
```

## Environment Variables

### Workflow-level Environment Variables

```yaml
env:
  MAX_OPEN_PRS_PER_CONTAINER: 2    # Max PRs per container
  PR_AUTO_CLOSE_DAYS: 7           # Auto-close stale PRs
  DEBUG_OUTPUT: false             # Default debug setting
```

### Action-level Environment Variables

```yaml
env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  DOCKER_BUILDKIT: 1
  BUILDX_NO_DEFAULT_ATTESTATIONS: 1
```

## Permissions Required

### Repository Permissions
```yaml
permissions:
  contents: write      # For checking out and modifying files
  pull-requests: write # For creating and managing PRs
  issues: write        # For PR comments and cleanup
  packages: read       # For accessing Docker registry
```

### Token Permissions
- The default `GITHUB_TOKEN` has sufficient permissions for most operations
- For advanced features, a custom PAT might be needed

## Best Practices

### Workflow Design
1. **Fail-fast principle**: Stop early on critical errors
2. **Idempotent operations**: Safe to re-run workflows
3. **Clear naming**: Descriptive job and step names
4. **Error handling**: Graceful degradation on failures

### Action Development
1. **Composite actions**: Use for reusable shell scripts
2. **Input validation**: Validate all inputs
3. **Output consistency**: Standardized output formats
4. **Documentation**: Clear descriptions and examples

### Security Considerations
1. **Minimal permissions**: Only required permissions
2. **Secret management**: Use GitHub Secrets
3. **Input sanitization**: Validate untrusted inputs
4. **Audit logging**: Track all significant actions

## Troubleshooting

### Common Issues

#### Workflow Not Triggering
- Check branch protection rules
- Verify file path filters
- Check workflow permissions

#### Action Failing
- Enable debug mode with `debug: true`
- Check action logs for error details
- Verify input parameters

#### Version Detection Issues
- Test version.sh script locally
- Check network connectivity in actions
- Verify API rate limits

### Debug Mode

Enable debug output by setting the debug input to `true`:

```yaml
workflow_dispatch:
  inputs:
    debug:
      default: true
```

Or set the environment variable:

```yaml
env:
  DEBUG_OUTPUT: true
```

---

**Last Updated**: June 21, 2025
**Maintained By**: DevOps Team
