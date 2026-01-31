# Docker Containers

Production-ready Docker images with **zero-touch upstream monitoring** — when a new version drops, builds happen automatically.

[![Auto Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)
[![Upstream Monitor](https://github.com/oorabona/docker-containers/actions/workflows/upstream-monitor.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/upstream-monitor.yaml)
[![ShellCheck](https://github.com/oorabona/docker-containers/actions/workflows/shellcheck.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/shellcheck.yaml)

## What's in the box

| Container | What it does | Variants |
|-----------|-------------|----------|
| [postgres](postgres/) | PostgreSQL with extension ecosystem | base, vector, analytics, timeseries, distributed, full |
| [terraform](terraform/) | Terraform CLI, cloud-provider scoped | base, aws, azure, gcp, full |
| [wordpress](wordpress/) | WordPress with PHP optimizations | — |
| [openresty](openresty/) | Nginx + Lua web platform | — |
| [php](php/) | PHP-FPM runtime | — |
| [ansible](ansible/) | Automation platform | — |
| [debian](debian/) | Minimal base image | — |
| [jekyll](jekyll/) | Static site generator | — |
| [openvpn](openvpn/) | VPN server | — |
| [sslh](sslh/) | SSL/SSH port multiplexer | — |

All images are published to [GHCR](https://github.com/oorabona?tab=packages) and [Docker Hub](https://hub.docker.com/u/oorabona).

## How it works

```
Upstream releases new version
        │
        ▼
  upstream-monitor.yaml     ← daily at 06:00 UTC
  detects version change
        │
        ▼
  Creates PR + triggers
  auto-build.yaml
        │
        ▼
  Smart rebuild: compares    ← skips if nothing changed
  build digest vs registry
        │
        ▼
  Multi-arch build           ← linux/amd64 + linux/arm64
  (native runners, no QEMU)
        │
        ▼
  Push to GHCR + Docker Hub
  Emit build lineage JSON
        │
        ▼
  Auto-merge PR
```

**Key differentiators:**

- **Smart rebuild detection** — content-based digest skips unchanged builds ([ADR-002](docs/adr/ADR-002-smart-rebuild-detection.md))
- **Declarative variants** — one Dockerfile, N flavors via `variants.yaml` ([ADR-003](docs/adr/ADR-003-variant-system.md))
- **Build lineage tracking** — full provenance chain from source to published image ([ADR-004](docs/adr/ADR-004-build-lineage-tracking.md))
- **Native multi-arch** — parallel amd64/arm64 on dedicated runners, no emulation ([ADR-001](docs/adr/ADR-001-multi-platform-native-runners.md))

## Quick start

```bash
# List containers
./make list

# Build a container (auto-discovers latest upstream version)
./make build postgres

# Build with specific version
./make build postgres 17

# Push to registries
./make push postgres

# Check what's upstream
./make version postgres

# Check all containers for updates
./make check-updates

# Show build lineage
./make lineage postgres

# Show image sizes
./make sizes
```

## Adding a container

1. Create a directory with a `Dockerfile` and a `version.sh`:

```bash
mkdir my-app
```

2. `version.sh` discovers the latest upstream version:

```bash
#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

get_latest_upstream() {
    latest-docker-tag library/nginx "^[0-9]+\.[0-9]+\.[0-9]+$"
}

handle_version_request "$1" "oorabona/my-app" "^[0-9]+\.[0-9]+\.[0-9]+$" "get_latest_upstream"
```

3. Build and test:

```bash
./make build my-app
./make run my-app
```

That's it. The CI picks it up automatically on next push.

## Requirements

- Docker Engine 20.10+ (or Podman)
- Bash 4.0+
- [yq](https://github.com/mikefarah/yq) (for variant containers)

## Documentation

- [Development Guide](docs/DEVELOPMENT.md) — internals, variants, build system
- [CI/CD Workflows](docs/GITHUB_ACTIONS.md) — GitHub Actions reference
- [Architecture](docs/WORKFLOW_ARCHITECTURE.md) — pipeline design
- [Local Development](docs/LOCAL_DEVELOPMENT.md) — dev setup
- [Testing Guide](docs/TESTING_GUIDE.md) — running tests locally
- [Container Dashboard](https://oorabona.github.io/docker-containers/) — live build status

## License

[MIT](LICENSE)
