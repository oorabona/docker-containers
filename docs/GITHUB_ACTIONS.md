# GitHub Actions Reference

This guide covers the automated workflows and actions used for container management.

## Workflows

### 1. Upstream Monitor (`upstream-monitor.yaml`)

Monitors upstream sources for version updates and creates PRs automatically.

**Triggers:**
- Schedule: 6 AM/6 PM UTC daily
- Manual: `gh workflow run upstream-monitor.yaml`

**Key Inputs:**
```bash
# Check specific container with debug
gh workflow run upstream-monitor.yaml \
  --field container=wordpress \
  --field debug=true \
  --field create_pr=true
```

**Outputs:**
- Container update summary
- Pull requests for version updates
- Automatic build triggers

### 2. Auto Build (`auto-build.yaml`)

Builds and pushes containers when changes are detected.

**Triggers:**
- Push to main/master (affecting container files)
- Pull requests
- Schedule (twice daily)
- Manual dispatch

**Features:**
- Multi-architecture builds (amd64, arm64)
- Smart change detection
- Registry push automation
- Build retry logic

**Usage:**
```bash
# Build all containers
gh workflow run auto-build.yaml

# Force rebuild specific container  
gh workflow run auto-build.yaml \
  --field container=wordpress \
  --field force_rebuild=true
```

### 3. Version Validation (`validate-version-scripts.yaml`)

Validates all version.sh scripts for functionality and standards compliance.

**Triggers:**
- Changes to version.sh files
- Manual dispatch

**Local Testing:**
```bash
./validate-version-scripts.sh
```

## Reusable Actions

### Check Upstream Versions (`.github/actions/check-upstream-versions`)

Checks for upstream version updates across containers.

**Inputs:**
- `container` (optional): Specific container to check

**Outputs:**
- `containers_with_updates`: JSON array of containers needing updates
- `update_count`: Number of containers with updates
- `version_info`: Detailed version information

### Build Container (`.github/actions/build-container`)

Builds a specific container with optimizations and error handling.

**Inputs:**
- `container`: Container name to build
- `force_rebuild`: Force rebuild even if up-to-date
- `dockerhub_username`, `dockerhub_token`, `github_token`: Registry credentials

**Features:**
- Multi-architecture support
- Build caching
- Registry push automation
- Retry logic on failures

### Detect Containers (`.github/actions/detect-containers`)

Intelligently detects which containers need building based on changes.

**Outputs:**
- `containers`: JSON array of containers to build
- `count`: Number of containers detected

## Usage Examples

### Manual Workflow Triggers

```bash
# Monitor all containers for updates
gh workflow run upstream-monitor.yaml

# Check specific container with debug output
gh workflow run upstream-monitor.yaml \
  --field container=ansible \
  --field debug=true \
  --field create_pr=false

# Force rebuild all containers
gh workflow run auto-build.yaml \
  --field force_rebuild=true

# Validate version scripts
gh workflow run validate-version-scripts.yaml
```

### Using Actions in Custom Workflows

```yaml
name: Custom Container Workflow
on: workflow_dispatch

jobs:
  check-and-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Check for updates
        id: check
        uses: ./.github/actions/check-upstream-versions
        with:
          container: wordpress
      
      - name: Build if updated
        if: steps.check.outputs.update_count > 0
        uses: ./.github/actions/build-container
        with:
          container: wordpress
          force_rebuild: false
          github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Required Permissions

Workflows require specific GitHub token permissions:

```yaml
permissions:
  contents: write      # Read/modify repository files
  pull-requests: write # Create and manage PRs  
  packages: write      # Push to container registries
  issues: write        # PR comments and management
```

## Environment Configuration

### Workflow Environment Variables

```yaml
env:
  DOCKER_BUILDKIT: 1                    # Enable BuildKit
  BUILDX_NO_DEFAULT_ATTESTATIONS: 1     # Disable attestations
  MAX_OPEN_PRS_PER_CONTAINER: 2         # Limit concurrent PRs
  PR_AUTO_CLOSE_DAYS: 7                 # Auto-close stale PRs
```

### Registry Configuration

```yaml
env:
  REGISTRY_URL: ghcr.io
  DOCKERHUB_REGISTRY: docker.io
  # Credentials via GitHub Secrets:
  # DOCKERHUB_USERNAME, DOCKERHUB_TOKEN
```

## Troubleshooting

### Common Issues

**Workflow Not Triggering:**
- Check branch protection rules
- Verify file path filters in workflow triggers
- Ensure workflow permissions are correct

**Version Script Failures:**
- Test script locally: `cd container && ./version.sh latest`
- Check API rate limits and network connectivity
- Verify JSON parsing with `jq`

**Build Failures:**
- Enable debug mode: `--field debug=true`
- Check Docker daemon status
- Verify registry credentials
- Review build logs for specific errors

### Debug Techniques

**Enable Debug Output:**
```bash
# For workflows
gh workflow run upstream-monitor.yaml --field debug=true

# For local testing
DEBUG=1 ./make build wordpress
```

**Local Testing:**
```bash
# Test GitHub Actions locally
./test-github-actions.sh

# Test specific workflow
./test-github-actions.sh upstream -c wordpress --verbose
```

## Best Practices

### Workflow Design
- Use descriptive job and step names
- Implement proper error handling
- Keep workflows idempotent (safe to re-run)
- Use fail-fast for critical errors

### Security
- Use minimal required permissions
- Store sensitive data in GitHub Secrets
- Validate all user inputs
- Audit workflow changes regularly

### Performance
- Use build caching where possible
- Implement parallel execution for independent tasks
- Optimize container builds with multi-stage Dockerfiles
- Use specific action versions (not `@latest`)

---

**Last Updated**: July 2025
