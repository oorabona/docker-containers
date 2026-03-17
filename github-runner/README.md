# github-runner

Self-hosted GitHub Actions runner in a Docker container. Supports Linux (Ubuntu 24.04, Debian Trixie) and Windows (Server 2022 ltsc2022), each in `base` and `dev` flavors. Runners are semi-ephemeral: each container handles exactly one job then exits, while named Docker volumes persist tool caches across restarts.

## Why this image?

GitHub provides an [official runner image](https://github.com/actions/runner/pkgs/container/actions-runner) (`ghcr.io/actions/actions-runner`) designed for [ARC](https://github.com/actions/actions-runner-controller) (Actions Runner Controller) on Kubernetes. If you run K8s, ARC is the recommended approach.

This image fills a different gap:

| Feature | Official (ARC) | This image |
|---------|:-:|:-:|
| Linux containers | ✅ | ✅ |
| Windows containers | ❌ | ✅ |
| Kubernetes required | Yes | No |
| `docker compose up` | ❌ | ✅ |
| GitHub App auth (JWT) | Via ARC config | Built into entrypoint |
| PAT / registration token auth | Via ARC config | Built into entrypoint |
| Semi-ephemeral with warm caches | Manual | `restart: always` + volumes |
| Org-level runners | Via ARC | Via env var (`GITHUB_ORG`) |
| Multi-distro (Ubuntu, Debian) | Ubuntu only | Ubuntu + Debian |

**Use this image when:** you want self-hosted runners on Docker Desktop, Podman, or any Docker host — without Kubernetes.

**Use the official image when:** you have a Kubernetes cluster and want to use ARC.

## Quick Start

```bash
# Copy and fill in the env file
cp .env.example .env
# Edit .env: set GITHUB_TOKEN + GITHUB_REPOSITORY (or GITHUB_ORG)

# Start a single runner
docker compose up

# Start 3 parallel runners
docker compose up --scale runner=3
```

The container registers itself with GitHub, executes one job, then exits with code 0.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RUNNER_TOKEN` | One of Token/PAT/App | — | Direct registration token from GitHub UI (expires in 1h) |
| `GITHUB_TOKEN` | One of Token/PAT/App | — | PAT with `repo` or `admin:org` scope |
| `APP_ID` | One of Token/PAT/App | — | GitHub App ID |
| `APP_PRIVATE_KEY` | One of Token/PAT/App | — | GitHub App private key (PEM string with literal `\n`) |
| `APP_PRIVATE_KEY_FILE` | One of Token/PAT/App | — | Path to GitHub App PEM file (alternative to `APP_PRIVATE_KEY`) |
| `GITHUB_REPOSITORY` | One of Repo/Org | — | Target repository in `owner/repo` format |
| `GITHUB_ORG` | One of Repo/Org | — | Target organisation name |
| `RUNNER_NAME_PREFIX` | No | `runner` | Prefix for the unique runner name |
| `RUNNER_LABELS` | No | `self-hosted,linux,<arch>` | Comma-separated runner labels |
| `RUNNER_GROUP` | No | `Default` | Runner group name |
| `RUNNER_TOOL_CACHE` | No | `/opt/hostedtoolcache` | Tool cache directory; compose.yaml maps this to a named volume at `/cache/tool-cache` |
| `GITHUB_API_URL` | No | `https://api.github.com` | Override for GitHub Enterprise Server |
| `ALLOW_ROOT` | No | `false` | Set `true` to run as root (security risk — testing only) |
| `RUNNER_DISABLE_AUTO_UPDATE` | No | `1` | Disable runner agent auto-update (recommended for containers) |

## Auth Modes

### PAT (Personal Access Token)

Requires a PAT with `repo` scope (repository runner) or `admin:org` scope (org runner).

```bash
docker run --rm \
  -e GITHUB_TOKEN=ghp_xxxxxxxxxxxx \
  -e GITHUB_REPOSITORY=owner/repo \
  ghcr.io/oorabona/github-runner:2.332.0
```

### GitHub App

Requires an App installed on the target repository or organisation. Provide either the PEM content (inline) or a file path.

```bash
# PEM content inline (escape newlines as \n)
docker run --rm \
  -e APP_ID=123456 \
  -e APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\nMII...\n-----END RSA PRIVATE KEY-----" \
  -e GITHUB_REPOSITORY=owner/repo \
  ghcr.io/oorabona/github-runner:2.332.0

# PEM from file (mount the key)
docker run --rm \
  -e APP_ID=123456 \
  -e APP_PRIVATE_KEY_FILE=/run/secrets/app-key \
  -v /path/to/app.pem:/run/secrets/app-key:ro \
  -e GITHUB_REPOSITORY=owner/repo \
  ghcr.io/oorabona/github-runner:2.332.0
```

JWT generation uses `openssl` (pure bash, no extra dependencies).

## Running on Windows

1. Go to your repo on GitHub: **Settings** → **Actions** → **Runners** → **New self-hosted runner**
2. Copy the registration token from the configure step (it starts with `A` and is valid for 1 hour)

### Linux runners (Podman Desktop or Docker Desktop)

Both Podman Desktop and Docker Desktop can run Linux runner images on Windows via WSL2:

```bash
podman run --rm \
  -e RUNNER_TOKEN=AXXXXXXXXXXXXXXXXXX \
  -e GITHUB_REPOSITORY=owner/repo \
  ghcr.io/oorabona/github-runner:2.332.0
```

### Windows runners (Docker Desktop only)

Windows container images require Docker Desktop (or Rancher Desktop with moby engine).
Podman does not support Windows containers.

1. Switch Docker Desktop to **Windows containers** (right-click tray icon → "Switch to Windows containers")
2. Go to your repo → Settings → Actions → Runners → New self-hosted runner
3. Copy the registration token

```bash
docker run --rm \
  -e RUNNER_TOKEN=AXXXXXXXXXXXXXXXXXX \
  -e GITHUB_REPOSITORY=owner/repo \
  ghcr.io/oorabona/github-runner:2.332.0-windows-ltsc2022
```

> **Note:** Windows containers require process isolation (default on Windows Server)
> or Hyper-V isolation (Windows 11 Pro/Enterprise).

> **Note:** The registration token expires after 1 hour. For persistent runners or scaled deployments, use PAT or GitHub App auth instead — those never expire and can refresh a fresh registration token on every container start.

## Flavors

| Flavor | Tag suffix | Included |
|--------|-----------|----------|
| `base` | `-base` | runner agent, git, curl, jq, unzip, ca-certificates, libicu-dev, libkrb5-dev |
| `dev` | `-dev` | everything in `base` + build-essential, pkg-config, libssl-dev, libgtk-3-dev, libwebkit2gtk-4.1-dev (Tauri prerequisites) |

The `dev` flavor targets Tauri-based build pipelines. Language runtimes (Rust, Node, Python) are NOT pre-installed — use `setup-*` actions; they will be cached in `RUNNER_TOOL_CACHE`.

## Distros

| Distro | Tag | Notes |
|--------|-----|-------|
| Ubuntu 24.04 | `2.332.0` or `2.332.0-ubuntu-2404-base` | Default, recommended |
| Debian Trixie | `2.332.0-debian-trixie-base` | Smaller base image |
| Windows Server 2022 | `2.332.0-windows-ltsc2022-base` | Requires Windows host or `--profile windows` |

## Scaling

```bash
# Start 5 parallel runners for the same repo
docker compose up --scale runner=5
```

Each container instance gets a unique name (`${RUNNER_NAME_PREFIX}-${HOSTNAME}-${EPOCH}`) and registers independently. All share the same named volumes for tool caches.

## Cache Volumes

Named Docker volumes persist build tool caches across container restarts. They survive `docker compose down` (use `docker compose down --volumes` to remove them).

| Volume | Container path | Purpose |
|--------|---------------|---------|
| `github-runner-tool-cache` | `/cache/tool-cache` | `setup-node`, `setup-go`, etc. (`RUNNER_TOOL_CACHE`) |
| `github-runner-cargo-cache` | `/home/runner/.cargo` | Rust cargo registry + compiled deps |
| `github-runner-npm-cache` | `/home/runner/.npm` | npm global cache |
| `github-runner-nuget-cache` | `/home/runner/.nuget` | NuGet package cache |
| `github-runner-pnpm-store` | `/home/runner/.pnpm-store` | pnpm content-addressable store |

## Docker-outside-of-Docker (DooD)

Allows workflows to run `docker` commands by sharing the host Docker socket. The `runner` user is pre-added to the `docker` group at build time.

```yaml
# In compose.yaml — uncomment the socket volume:
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
```

Or with `docker run`:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e GITHUB_TOKEN=... \
  -e GITHUB_REPOSITORY=... \
  ghcr.io/oorabona/github-runner:2.332.0
```

**Security warning:** Mounting the Docker socket grants the container full control over the host Docker daemon. Only do this on trusted infrastructure. DinD (Docker-in-Docker with `--privileged`) is not supported.

## Windows Runner

The Windows variant (`-windows-ltsc2022`) runs on Windows Server 2022 with process isolation (no Hyper-V required).

```bash
# Start only the Windows runner (requires a Windows host or Hyper-V)
docker compose --profile windows up
```

Requirements:
- Windows Server 2022 or Windows 10/11 with Windows containers enabled
- Docker Desktop configured for Windows containers
- No Hyper-V needed (process isolation is the default)

The Windows runner uses PowerShell (`entrypoint.ps1`) and installs packages via Chocolatey.

## Building Locally

```bash
# From the repository root:
./make build github-runner 2.332.0

# Build all variants (generates Dockerfiles for all distros × flavors):
./make build github-runner

# Build a specific distro + flavor:
./github-runner/generate-dockerfile.sh ubuntu-2404 base
docker build --build-arg RUNNER_VERSION=2.332.0 \
  -f github-runner/Dockerfile.ubuntu-2404-base \
  github-runner/
```

## Troubleshooting

### Token expired (HTTP 401)

Registration tokens are valid for 1 hour. The entrypoint fetches a fresh token on every start — if the API returns 401, it retries up to 5 times with exponential backoff (2 s, 4 s, 8 s, 16 s, 32 s). If all attempts fail:

```
[ERROR] Failed to obtain registration token after 5 attempts.
```

Check that `GITHUB_TOKEN` has the correct scope (`repo` for repository runners, `admin:org` for org runners).

### Name conflicts

If a runner with the same name is already registered, `config.sh` exits with code 3. The entrypoint treats this as a fatal error and exits non-zero. To avoid conflicts, set `RUNNER_NAME_PREFIX` to a unique value or use `docker compose up --scale runner=N` which gives each container a different hostname.

### No-network errors at startup

The entrypoint exits immediately on DNS / connection failures (curl exits non-zero). There is no retry for network-unavailable errors — only for HTTP-level failures (4xx/5xx). Ensure the container can reach `api.github.com` (or your GHES URL).

### Orphan runners after SIGKILL

If the container is killed with `SIGKILL` (OOM kill, `docker kill`, etc.) the SIGTERM cleanup handler does not run and the runner stays registered as offline on GitHub. GitHub automatically removes offline runners after 14 days, but the `cleanup-offline-runners.sh` script lets you remove them immediately.

```bash
# Dry-run: list offline runners without removing (default)
./github-runner/cleanup-offline-runners.sh owner/repo

# Org-level
./github-runner/cleanup-offline-runners.sh --org myorg

# Actually remove them
./github-runner/cleanup-offline-runners.sh owner/repo --force

# Uses GITHUB_REPOSITORY or GITHUB_ORG from the environment
./github-runner/cleanup-offline-runners.sh --force
```

The script requires the `gh` CLI to be authenticated (or `GITHUB_TOKEN` in the environment with `repo` scope for repository runners or `admin:org` scope for org runners). It always prints a table of offline runners before acting.

### Volume UID mismatch

If a cache volume was created by a different UID, the entrypoint attempts `chown` on startup and warns if it cannot fix the permissions:

```
[WARN]  Cache directory not writable: /cache/tool-cache — attempting permission fix
```

To reset: `docker volume rm github-runner-tool-cache` (loses cached data).
