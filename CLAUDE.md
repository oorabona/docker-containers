# Project: docker-containers

Custom Docker container images with automated upstream version monitoring and CI/CD pipelines.

## Quick Start

```bash
# List available containers
./make list

# Build a container (auto-discovers latest upstream version)
./make build <container-name>

# Build with specific version
./make build <container-name> <version>

# Push to registry
./make push <container-name>

# Check upstream versions
./make version <container-name>

# Run tests
./test-all-containers.sh
```

## Project Structure

```
docker-containers/
├── docs/                    # Documentation (see DOCUMENTATION_INDEX.md)
│   ├── DEVELOPMENT.md       # Internal dev guide (extensions, variants, build system)
│   ├── GITHUB_ACTIONS.md    # CI/CD documentation
│   ├── WORKFLOW_ARCHITECTURE.md
│   ├── LOCAL_DEVELOPMENT.md
│   └── TESTING_GUIDE.md
├── .github/workflows/       # GitHub Actions
│   ├── auto-build.yaml      # Build and push containers (full pipeline)
│   ├── recreate-manifests.yaml # Recreate multi-arch manifests without rebuilding
│   ├── upstream-monitor.yaml # Version monitoring
│   ├── update-dashboard.yaml # Dashboard generation
│   └── validate-version-scripts.yaml
├── helpers/                 # Shared shell utilities
├── scripts/                 # Build/push/version scripts
├── <container>/             # Container directories
│   ├── Dockerfile
│   ├── version.sh           # Version discovery script
│   └── ...
├── TODO.md                  # Main backlog
└── .claude/
    └── skills/
        └── project-experience/
            ├── SKILL.md
            └── GOTCHAS.md
```

## Stack

- **Language:** Bash (shell scripts)
- **Container Runtime:** Docker with BuildKit
- **CI/CD:** GitHub Actions
- **Documentation:** Jekyll (GitHub Pages)
- **Testing:** Custom shell test framework

## Containers

| Container | Description |
|-----------|-------------|
| ansible | Ansible automation platform |
| debian | Base Debian image |
| jekyll | Jekyll static site generator |
| openresty | OpenResty (Nginx + Lua) |
| openvpn | OpenVPN server |
| php | PHP-FPM variants |
| postgres | PostgreSQL with extensions (variants: base, vector, analytics, timeseries, distributed, full) |
| sslh | SSL/SSH multiplexer |
| terraform | Terraform CLI (variants: base, aws, azure, gcp, full) |
| wordpress | WordPress with optimizations |

## Conventions

### Shell Scripts
- Use `shellcheck` for linting
- Source shared utilities from `helpers/`
- Use logging functions from `helpers/logging.sh`

### Dockerfiles
- Multi-stage builds where applicable
- Use BuildKit features (cache mounts, etc.)
- Pin base image versions

### Version Discovery
- Each container has `version.sh` for upstream version detection
- Scripts must output JSON for automation

### Git
- Branch naming: `<type>/<description>`
- Commit format: `<type>(<scope>): <description>`

## Commands Reference

| Action | Command |
|--------|--------|
| List containers | `./make list` |
| Build | `./make build <target> [version]` |
| Build extensions | `./make build-extensions <target> [version] [--local-only]` |
| Push | `./make push <target> [version]` |
| Run | `./make run <target> [version]` |
| Check version | `./make version <target>` |
| Check updates | `./make check-updates [target]` |
| Check dep updates | `./make check-dep-updates [target]` |
| Test all | `./test-all-containers.sh` |
| Validate scripts | `./validate-version-scripts.sh` |

## Important Notes

- Always return to root directory before running `./make`
- Dashboard is auto-generated - don't edit `index.md` manually
- Version scripts must handle network failures gracefully
- Use `act` for local GitHub Actions testing (see `.actrc`)

## GitHub Actions Workflows

| Workflow | Trigger | Purpose |
|----------|---------|--------|
| `auto-build.yaml` | Push, PR, workflow_call, manual | Build and push containers (inputs: container, force_rebuild, skip_extensions, scope_versions, scope_flavors, scope_extensions) |
| `recreate-manifests.yaml` | Manual | Recreate multi-arch manifest lists without rebuilding (inputs: container, registry: both/ghcr/dockerhub) |
| `upstream-monitor.yaml` | Schedule (6 AM UTC daily), manual | Check upstream + dependency updates |
| `update-dashboard.yaml` | workflow_call, manual | Regenerate status dashboard |
| `validate-version-scripts.yaml` | PR | Validate version.sh scripts |
| `cleanup-registry.yaml` | Schedule, manual | Clean old GHCR images |
| `shellcheck.yaml` | Push, PR | Lint shell scripts |
| `sync-dockerhub-readme.yaml` | Push, manual | Sync README to Docker Hub |

## Environment Variables

| Variable | Purpose |
|----------|--------|
| `DOCKEROPTS` | Additional Docker build options |
| `NPROC` | Parallelism for builds |
