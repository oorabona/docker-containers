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
│   ├── auto-build.yaml      # Automatic container builds
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
| debian | Base Debian image |
| openresty | OpenResty (Nginx + Lua) |
| openvpn | OpenVPN server |
| php | PHP-FPM variants |
| postgres | PostgreSQL with extensions |
| sslh | SSL/SSH multiplexer |
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
| `auto-build.yaml` | Push, schedule | Build and push containers |
| `upstream-monitor.yaml` | Schedule | Check for upstream updates |
| `update-dashboard.yaml` | Schedule, manual | Regenerate status dashboard |
| `validate-version-scripts.yaml` | PR | Validate version.sh scripts |

## Environment Variables

| Variable | Purpose |
|----------|--------|
| `DOCKEROPTS` | Additional Docker build options |
| `NPROC` | Parallelism for builds |

## Workflow Integration

This project uses the standard Claude Code workflow:
1. `/clarify` - Scope clarification
2. `/spec` - Specification production
3. `/implement` - Implementation
4. `/review` - Code review
5. `/finalize` - Story completion

Run `/workflow <task>` to execute the full cycle.
