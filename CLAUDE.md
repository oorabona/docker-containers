# Project: docker-containers

Custom Docker container images with automated upstream version monitoring and CI/CD pipelines.

- **Architecture decisions:** [`docs/adr/`](docs/adr/) — ADR-001 to ADR-006
- **Documentation index:** [`docs/DOCUMENTATION_INDEX.md`](docs/DOCUMENTATION_INDEX.md)

## Project Structure

```
docker-containers/
├── docs/                    # User docs + ADRs (see DOCUMENTATION_INDEX.md)
│   ├── adr/                 # Architecture Decision Records
│   └── site/                # Jekyll source for the dashboard (GitHub Pages)
├── .github/workflows/       # CI/CD pipelines
├── .github/actions/         # Composite actions (build-container, etc.)
├── helpers/                 # Shared shell utilities
├── scripts/                 # Build/push/version scripts
├── tests/                   # Test harness + e2e tests
├── examples/                # Docker Compose stacks
├── <container>/             # One directory per container
│   ├── Dockerfile           # Or Dockerfile.template + generate-dockerfile.sh
│   ├── config.yaml          # Build args, base image, dep sources
│   ├── variants.yaml        # Version + variant matrix
│   ├── version.sh           # Upstream version discovery
│   └── README.md
├── TODO.md                  # Active backlog
└── make                     # Project entry point — see Commands below
```

## Stack

- **Language:** Bash (shell scripts)
- **Container runtime:** Docker with BuildKit
- **CI/CD:** GitHub Actions
- **Documentation:** Jekyll on GitHub Pages (source in `docs/site/`)
- **Testing:** Custom shell test framework (`tests/`)

## Containers

Run `./make list` for the live list. See each `<container>/README.md` for usage.

## Commands

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
| Generate SBOM | `./make sbom <target> [tag]` |
| Test all containers | `./test-all-containers.sh` |
| Validate version scripts | `./validate-version-scripts.sh` |
| Local CI test (via `act`) | `./test-github-actions.sh` |

## Conventions

### Shell Scripts
- Lint with `shellcheck` (CI enforced)
- Source shared utilities from `helpers/`
- Use logging functions from `helpers/logging.sh`

### Dockerfiles
- Multi-stage builds where applicable
- Use BuildKit features (cache mounts, etc.)
- Pin base image versions

### Version Discovery
- Each container has `version.sh` for upstream version detection
- Scripts must output JSON for automation
- See ADR-002 for smart rebuild detection

### Multi-Distro Containers
- `web-shell` and `github-runner` use the template+generator pattern (see ADR-006)
- Edit `Dockerfile.template` + `config.yaml`; generator produces per-distro Dockerfiles at build time

### Git
- Branch naming: `<type>/<description>` (`feat/`, `fix/`, `refactor/`, `docs/`, `ci/`, `chore/`)
- Commit format: `<type>(<scope>): <description>`

## CI/CD

| Workflow | Purpose |
|----------|---------|
| `auto-build.yaml` | Build + push containers (smoke build on PR, full build + push on master) |
| `upstream-monitor.yaml` | Daily upstream + dep checks → auto-PRs via GitHub App bot |

Other workflows in `.github/workflows/`: `recreate-manifests`, `update-dashboard`, `validate-version-scripts`, `cleanup-registry`, `shellcheck`, `sync-dockerhub-readme`.

## Important Notes

- **When adding a new container, update the root `README.md`'s container table** (`## What's in the box`) — easy to forget since it's not part of any build/test path
- Always return to root directory before running `./make`
- Dashboard auto-generated from `.build-lineage/` JSON — don't edit `docs/site/_data/containers.yml` manually
- Version scripts must handle network failures gracefully
- Use `act` for local GitHub Actions testing (see `.actrc`)
