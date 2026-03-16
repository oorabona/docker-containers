---
doc-meta:
  title: "GitHub Self-Hosted Runner Container"
  status: canonical
  adversarial_applied: true
  story_id: GITHUB-RUNNER
  created: 2026-03-15T16:04:41+01:00
  author: spec
---

# GITHUB-RUNNER: Self-Hosted GitHub Actions Runner Container

## Summary

Add a `github-runner` container that provides a self-hosted GitHub Actions runner.
Supports 3 OS distros (ubuntu-2404, debian-trixie, windows-ltsc2022), each in `base` and
`dev` flavors — 6 variants total.
Uses the template+generator pattern for Linux (like web-shell) and a standalone
`Dockerfile.windows` for Windows. Runners are semi-ephemeral: `--ephemeral` flag ensures
each container handles exactly one job, while Docker volumes persist tool caches between
container restarts.

## User Story

As a platform engineer, I want to run self-hosted GitHub Actions runners inside Docker so
I can use custom tooling, avoid GitHub-hosted runner limits, and cache build artifacts
across jobs with persistent volumes.

## Acceptance Criteria

| ID   | Criterion |
|------|-----------|
| AC-1 | Linux image `github-runner:2.332.0-ubuntu-2404-base` builds locally via `./make build github-runner` |
| AC-2 | Windows image `github-runner:2.332.0-windows-ltsc2022-base` builds on a `windows-latest` GitHub runner |
| AC-3 | A container launched with valid `GITHUB_TOKEN` + `GITHUB_REPOSITORY` registers, picks up a test workflow job, executes it, and deregisters |
| AC-4 | `docker compose up` in `github-runner/` starts a semi-ephemeral runner with `RUNNER_TOOL_CACHE`, `.cargo`, `.npm`, `.nuget`, and `pnpm-store` volumes |
| AC-5 | `auto-build.yaml` CI pushes all Linux variants to GHCR on `ubuntu-latest`; Windows variant pushes on `windows-latest` |
| AC-6 | All 6 variants (3 OS × 2 flavors) build successfully and pass smoke tests |

## BDD Scenarios

### Scenario 1 — Linux local build (AC-1)

```
Given I am in /mnt/wsl/shared/dev/docker-containers
When  I run: ./make build github-runner 2.332.0
Then  docker images shows ghcr.io/oorabona/github-runner:2.332.0
And   the image contains /home/runner/run.sh
And   generate-dockerfile.sh produced Dockerfile.ubuntu-2404 before build
```

### Scenario 2 — Ephemeral registration via PAT (AC-3)

```
Given GITHUB_TOKEN is a PAT with repo scope
And   GITHUB_REPOSITORY=owner/repo
When  I run: docker run --rm -e GITHUB_TOKEN -e GITHUB_REPOSITORY ghcr.io/oorabona/github-runner:2.332.0
Then  entrypoint.sh calls POST /repos/owner/repo/actions/runners/registration-token
And   config.sh --ephemeral --unattended --name runner-${HOSTNAME}-${EPOCH} runs successfully
And   run.sh starts the runner agent
And   after one job completes the container exits 0
```

### Scenario 3 — Ephemeral registration via GitHub App (AC-3)

```
Given APP_ID and APP_PRIVATE_KEY are set
And   GITHUB_REPOSITORY=owner/repo
When  the container starts
Then  entrypoint.sh generates a JWT, exchanges it for an installation token via GitHub API
And   registration proceeds identically to the PAT path
```

### Scenario 4 — Token expiry + retry (edge case)

```
Given the registration token API call fails with HTTP 401
When  the entrypoint retries with exponential backoff
Then  it retries at 2s, 4s, 8s, 16s, 32s (max 5 attempts)
And   exits 1 with message "ERROR: failed to obtain registration token after 5 attempts"
```

### Scenario 5 — Semi-ephemeral with cache volumes (AC-4)

```
Given docker compose up in github-runner/
When  a job using setup-node writes to RUNNER_TOOL_CACHE
Then  the data persists in the named Docker volume github-runner-tool-cache
And   the next container restart reuses the cached tool
```

### Scenario 6 — Windows build in CI (AC-2, AC-5)

```
Given a push to a path matching github-runner/**
And   the build matrix entry has os: windows
When  auto-build.yaml detects os: windows on the variant
Then  it runs the build step on a windows-latest runner
And   uses build-container-windows/action.yaml (pwsh-based)
And   pushes github-runner:2.332.0-windows-ltsc2022-base to GHCR
```

---

## Architecture

### Directory Structure

```
github-runner/
├── config.yaml                    # Container meta + distro definitions + base image cache
├── variants.yaml                  # Build matrix (versions + 10 variants)
├── version.sh                     # Upstream version discovery (GitHub releases API)
├── Dockerfile.linux               # Template with @@MARKERS@@
├── Dockerfile.windows             # Standalone (no template, ltsc2022 only)
├── generate-dockerfile.sh         # Expands Dockerfile.linux per distro → Dockerfile.<flavor>
├── entrypoint.sh                  # Linux: registration + run loop
├── entrypoint.ps1                 # Windows: registration + run loop (PowerShell)
├── compose.yaml                   # Local dev: cache volumes + env file
├── README.md                      # Usage + env var reference
└── tests/
    ├── test-runner-linux.sh       # bats tests (entrypoint logic, not live GitHub)
    └── test-runner-windows.ps1    # Pester tests for entrypoint.ps1
```

### Data Flow

```
variants.yaml                    config.yaml
     │                                │
     ▼                                ▼
list_build_matrix()         generate-dockerfile.sh
     │                                │
     ▼                                ▼
CI matrix (6 entries)        expand_template()         ← helpers/template-utils.sh
     │                                │
     ├── os=linux  ──────────►  Generated Dockerfile.<distro>
     │     │                          │
     │     ▼                          ▼
     │  ubuntu-latest runner    build_container()
     │                                │
     └── os=windows ─────────►  Dockerfile.windows
           │                          │
           ▼                          ▼
       windows-latest runner    build-container-windows/action.yaml
                                      │
                                      ▼
                              lineage → SBOM (Linux only) → dashboard
```

### Flavor Matrix

| Flavor | Base packages | Extra packages |
|--------|--------------|----------------|
| `base` | agent, git, curl, jq, unzip | — |
| `dev`  | everything in base | build-essential (Linux) or VS Build Tools (Windows), libgtk-3-dev, libwebkit2gtk-4.1-dev (Linux only) |

The `dev` flavor targets Tauri-based build pipelines. It does NOT pre-install language
runtimes (Rust, Node, Python) — those are pulled by `setup-*` actions and cached via
`RUNNER_TOOL_CACHE`.

**Docker-outside-of-Docker (DooD):** Both flavors support DooD when the host Docker socket
is bind-mounted (`-v /var/run/docker.sock:/var/run/docker.sock`). The `runner` user is in
the `docker` group. DinD (Docker-in-Docker with `--privileged`) is NOT supported — see
Out of Scope.

---

## Block 1: Container Scaffold

**Files:** `github-runner/config.yaml`, `github-runner/variants.yaml`, `github-runner/version.sh`

### config.yaml

```yaml
name: github-runner
description: "Self-hosted GitHub Actions runner (Linux + Windows)"

# Used by build matrix for Linux variants only; Windows uses Dockerfile.windows directly
generate_dockerfile: true
dockerfile_generator: generate-dockerfile.sh

base_image_cache:
  ubuntu-2404-base:
    source: ubuntu
    tags: ["24.04"]
  ubuntu-2204-base:
    source: ubuntu
    tags: ["22.04"]
  # debian-trixie and debian-bookworm come from ghcr.io/oorabona/debian — no cache needed

distros:
  ubuntu-2404:
    base_image: "ubuntu:24.04"
    base_image_arg: UBUNTU_2404_BASE
    pkg_manager: apt
    install_cmd: "apt-get update && apt-get install -y --no-install-recommends"
    cleanup_cmd: "rm -rf /var/lib/apt/lists/*"
    runner_user: runner
    user_exists: false
    arch_map:
      amd64: x64
      arm64: arm64

  ubuntu-2204:
    base_image: "ubuntu:22.04"
    base_image_arg: UBUNTU_2204_BASE
    pkg_manager: apt
    install_cmd: "apt-get update && apt-get install -y --no-install-recommends"
    cleanup_cmd: "rm -rf /var/lib/apt/lists/*"
    runner_user: runner
    user_exists: false
    arch_map:
      amd64: x64
      arm64: arm64

  debian-trixie:
    base_image: "ghcr.io/oorabona/debian:trixie"
    base_image_arg: DEBIAN_TRIXIE_BASE
    pkg_manager: apt
    install_cmd: "apt-get update && apt-get install -y --no-install-recommends"
    cleanup_cmd: "rm -rf /var/lib/apt/lists/*"
    runner_user: runner
    user_exists: false
    arch_map:
      amd64: x64
      arm64: arm64

  debian-bookworm:
    base_image: "ghcr.io/oorabona/debian:bookworm"
    base_image_arg: DEBIAN_BOOKWORM_BASE
    pkg_manager: apt
    install_cmd: "apt-get update && apt-get install -y --no-install-recommends"
    cleanup_cmd: "rm -rf /var/lib/apt/lists/*"
    runner_user: runner
    user_exists: false
    arch_map:
      amd64: x64
      arm64: arm64

  windows-ltsc2022:
    base_image: "mcr.microsoft.com/windows/servercore:ltsc2022"
    pkg_manager: none   # chocolatey / direct download
    runner_user: runneradmin
    isolation: process   # Hyper-V not required on Server 2022

flavors:
  base:
    packages:
      apt: [git, curl, jq, unzip, ca-certificates, libicu-dev, libkrb5-dev]
    windows_packages: [git, jq, curl]   # choco

  dev:
    extends: base
    packages:
      apt:
        - build-essential
        - pkg-config
        - libssl-dev
        - libgtk-3-dev
        - libwebkit2gtk-4.1-dev
        - libayatana-appindicator3-dev
        - librsvg2-dev
    windows_packages: []   # VS Build Tools workload handled in Dockerfile.windows
```

### variants.yaml

```yaml
build:
  version_retention: 3

versions:
  - tag: "2.332.0"
    variants:
      - name: ubuntu-2404
        suffix: ""
        flavor: ubuntu-2404
        description: "Ubuntu 24.04 runner (latest, default)"
        default: true

      # v2: add ubuntu-2204, debian-bookworm
      - name: debian-trixie
        suffix: "-debian-trixie"
        flavor: debian-trixie
        description: "Debian Trixie runner"

      - name: windows-ltsc2022
        suffix: "-windows-ltsc2022"
        flavor: windows-ltsc2022
        description: "Windows Server 2022 runner"
        os: windows
```

> Note: each distro produces both `base` and `dev` flavor images. The build matrix expands
> variants × flavors → 6 images. The flavor suffix is appended after the distro suffix
> (e.g., `2.332.0-ubuntu-2404-dev`, `2.332.0-debian-trixie-base`). The bare tag
> (`2.332.0`) maps to `ubuntu-2404-base`.

### version.sh

Discovery strategy: GitHub releases API, latest non-prerelease tag matching `v\d+\.\d+\.\d+`.

```bash
#!/usr/bin/env bash
# github-runner/version.sh
# Output: JSON {"version": "2.332.0", "url": "https://..."}
set -euo pipefail
source "$(dirname "$0")/../helpers/logging.sh"

REPO="actions/runner"
API="https://api.github.com/repos/${REPO}/releases/latest"

response=$(curl -sf \
  -H "Accept: application/vnd.github+json" \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  "${API}")

version=$(echo "$response" | jq -r '.tag_name | ltrimstr("v")')
echo "{\"version\": \"${version}\"}"
```

**Exit criteria:**
- `./make version github-runner` prints `{"version": "2.332.0"}` (or current latest)
- Script exits 0 on success, 1 on network failure with error on stderr
- Works with or without `GITHUB_TOKEN` (rate-limited without token)

**Dependencies:** None (first block)

---

## Block 2: Linux Dockerfile Template + Generator

**Files:** `github-runner/Dockerfile.linux`, `github-runner/generate-dockerfile.sh`

### Dockerfile.linux (template)

Markers:

| Marker | Replaced with |
|--------|--------------|
| `@@BASE_IMAGE@@` | `ubuntu:24.04`, `ghcr.io/oorabona/debian:trixie`, etc. |
| `@@BASE_IMAGE_ARG@@` | ARG name for the base image (e.g., `UBUNTU_2404_BASE`) |
| `@@INSTALL_PACKAGES@@` | distro install command + package list (base flavor) |
| `@@DEV_PACKAGES@@` | extra dev-flavor packages (empty string for base) |
| `@@RUNNER_USER@@` | `runner` (all Linux distros) |
| `@@CREATE_USER@@` | `useradd -m runner` or empty if user_exists=true |
| `@@FLAVOR_LABEL@@` | `base` or `dev` |

Template structure (abbreviated):

```dockerfile
# Generated by generate-dockerfile.sh — DO NOT EDIT
# Distro: @@DISTRO_NAME@@  Flavor: @@FLAVOR_LABEL@@
ARG @@BASE_IMAGE_ARG@@=@@BASE_IMAGE@@
FROM ${@@BASE_IMAGE_ARG@@}

ARG RUNNER_VERSION
ARG TARGETARCH

LABEL org.opencontainers.image.description="GitHub Actions self-hosted runner (@@DISTRO_NAME@@ @@FLAVOR_LABEL@@)"
LABEL org.opencontainers.image.source="https://github.com/oorabona/docker-containers"
LABEL com.github.runner.version="${RUNNER_VERSION}"
LABEL com.github.runner.flavor="@@FLAVOR_LABEL@@"
LABEL com.github.runner.distro="@@DISTRO_NAME@@"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    @@INSTALL_PACKAGES@@
    @@DEV_PACKAGES@@

# Install tini as init process (zombie prevention + signal forwarding)
RUN apt-get update && apt-get install -y --no-install-recommends tini && rm -rf /var/lib/apt/lists/*

@@CREATE_USER@@

# Add runner to docker group for DooD (Docker-outside-of-Docker)
RUN groupadd -f docker && usermod -aG docker @@RUNNER_USER@@

WORKDIR /home/@@RUNNER_USER@@/actions-runner

RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "x64") && \
    curl -fsSL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz" \
      -o runner.tar.gz && \
    curl -fsSL \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz.sha256" \
      -o runner.sha256 && \
    echo "$(cat runner.sha256)  runner.tar.gz" | sha256sum -c - && \
    tar xzf runner.tar.gz && \
    rm runner.tar.gz runner.sha256 && \
    ./bin/installdependencies.sh

COPY entrypoint.sh /home/@@RUNNER_USER@@/entrypoint.sh
RUN chmod +x /home/@@RUNNER_USER@@/entrypoint.sh

USER @@RUNNER_USER@@
ENV HOME=/home/@@RUNNER_USER@@
ENV RUNNER_TOOL_CACHE=/home/@@RUNNER_USER@@/.cache

ENTRYPOINT ["tini", "--", "/home/@@RUNNER_USER@@/entrypoint.sh"]
```

### generate-dockerfile.sh

Reads `config.yaml` (via `yq`), iterates over distros × flavors, calls
`expand_template()` from `helpers/template-utils.sh`. Produces
`Dockerfile.<distro>-<flavor>` (e.g., `Dockerfile.ubuntu-2404-base`).

`build_container()` in `scripts/build-container.sh` already calls
`generate-dockerfile.sh` before `docker buildx build` when
`generate_dockerfile: true` is set in `config.yaml`.

> **Implementation note:** `expand_template()` from `helpers/template-utils.sh` replaces
> ENTIRE lines containing `@@MARKER@@`. Markers must be on their own line as comments
> (e.g., `# @@BASE_IMAGE@@`), NOT inline within Dockerfile instructions. The
> `generate-dockerfile.sh` script must emit complete Dockerfile lines for each marker.

```bash
#!/usr/bin/env bash
# github-runner/generate-dockerfile.sh
# Usage: ./generate-dockerfile.sh [distro] [flavor]
#   If distro and flavor are omitted, generates all combinations.
```

**Exit criteria:**
- `./github-runner/generate-dockerfile.sh ubuntu-2404 base` produces `Dockerfile.ubuntu-2404-base`
- `./github-runner/generate-dockerfile.sh` (no args) produces all 8 Linux Dockerfiles
- Generated files pass `shellcheck` (embedded shell blocks)
- `docker build --no-cache -f github-runner/Dockerfile.ubuntu-2404-base github-runner/` succeeds locally

**Dependencies:** Block 1 (config.yaml for distro definitions)

---

## Block 3: Windows Dockerfile

**Files:** `github-runner/Dockerfile.windows`

Not template-based. Single distro (`windows-servercore:ltsc2022`), two flavors handled
via a `FLAVOR` build-arg.

```dockerfile
# syntax=docker/dockerfile:1
ARG WINDOWS_BASE=mcr.microsoft.com/windows/servercore:ltsc2022
FROM ${WINDOWS_BASE}

ARG RUNNER_VERSION=2.332.0
ARG FLAVOR=base

SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Install Chocolatey
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; \
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; \
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Enable long paths
RUN Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1
RUN git config --system core.longpaths true

# Create runner user
RUN net user runneradmin /add /Y; net localgroup administrators runneradmin /add

# Base packages
RUN choco install -y git curl jq unzip

# Dev packages (VS Build Tools + Tauri prerequisites) — only when FLAVOR=dev
RUN if ($env:FLAVOR -eq 'dev') { \
      choco install -y visualstudio2022buildtools \
        --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"; \
    }

WORKDIR C:\actions-runner

RUN $url = "https://github.com/actions/runner/releases/download/v${env:RUNNER_VERSION}/actions-runner-win-x64-${env:RUNNER_VERSION}.zip"; \
    Invoke-WebRequest -Uri $url -OutFile runner.zip; \
    Expand-Archive -Path runner.zip -DestinationPath . -Force; \
    Remove-Item runner.zip

COPY entrypoint.ps1 C:\entrypoint.ps1

USER runneradmin

LABEL org.opencontainers.image.description="GitHub Actions self-hosted runner (Windows ltsc2022 ${FLAVOR})"
LABEL com.github.runner.version="${RUNNER_VERSION}"
LABEL com.github.runner.flavor="${FLAVOR}"
LABEL com.github.runner.distro="windows-ltsc2022"

ENTRYPOINT ["powershell", "-File", "C:\\entrypoint.ps1"]
```

> **Note on isolation:** Windows Server 2022 containers default to process isolation.
> Hyper-V isolation requires the Hyper-V role, which is unavailable on standard GitHub
> `windows-latest` hosted runners. The Dockerfile does not specify `--isolation` — this
> is set at `docker run` time or via the daemon config.

**Exit criteria:**
- `docker build --build-arg RUNNER_VERSION=2.332.0 --build-arg FLAVOR=base -f Dockerfile.windows .` succeeds on a Windows host
- Image contains `C:\actions-runner\run.cmd`
- `FLAVOR=dev` image additionally contains `MSBuild.exe`

**Dependencies:** Block 1 (variants.yaml `os: windows` field)

---

## Block 4: Entrypoints

**Files:** `github-runner/entrypoint.sh`, `github-runner/entrypoint.ps1`

### entrypoint.sh (Linux)

#### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GITHUB_TOKEN` | One of PAT/App | — | PAT with `repo` or `admin:org` scope |
| `APP_ID` | One of PAT/App | — | GitHub App ID |
| `APP_PRIVATE_KEY` | One of PAT/App | — | GitHub App private key (PEM string) |
| `GITHUB_REPOSITORY` | One of repo/org | — | `owner/repo` |
| `GITHUB_ORG` | One of repo/org | — | `myorg` |
| `RUNNER_NAME_PREFIX` | No | `runner` | Prefix for unique runner name |
| `RUNNER_LABELS` | No | `self-hosted` | Comma-separated labels |
| `RUNNER_GROUP` | No | `Default` | Runner group name |
| `RUNNER_TOOL_CACHE` | No | `/home/runner/.cache` | Tool cache directory |
| `APP_PRIVATE_KEY_FILE` | No | — | Path to GitHub App PEM file (alternative to `APP_PRIVATE_KEY` env var) |
| `GITHUB_API_URL` | No | `https://api.github.com` | API base URL (set for GitHub Enterprise) |
| `ALLOW_ROOT` | No | `false` | Set to `true` to allow running as root (security risk) |
| `RUNNER_DISABLE_AUTO_UPDATE` | No | `1` | Disable runner agent auto-update (prevents crash loop in containers) |
| `DOCKER_HOST` | No | — | Docker daemon socket (auto-detected if /var/run/docker.sock mounted) |

#### Auth Logic

```
if GITHUB_TOKEN is set:
    token = POST /repos/{owner}/{repo}/actions/runners/registration-token
            (or /orgs/{org}/actions/runners/registration-token for org scope)
    Authorization: token ${GITHUB_TOKEN}
elif APP_ID + APP_PRIVATE_KEY are set:
    jwt = generate_jwt(APP_ID, APP_PRIVATE_KEY)   # RS256, exp=10min
    installation = GET /repos/{owner}/{repo}/installation
    access_token = POST /app/installations/{id}/access_tokens
    token = POST /repos/{owner}/{repo}/actions/runners/registration-token
            Authorization: token ${access_token}
elif APP_ID + APP_PRIVATE_KEY_FILE are set:
    key_file = APP_PRIVATE_KEY_FILE
    (same flow as APP_PRIVATE_KEY but reads from file)
else:
    echo "ERROR: must set GITHUB_TOKEN or APP_ID+APP_PRIVATE_KEY" >&2
    exit 1
```

JWT generation in pure bash using `openssl` (no external dependencies):

```bash
generate_jwt() {
  local app_id=$1 key_file=$2
  local header payload sig
  header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$(($(date +%s) - 60))" "$(($(date +%s) + 540))" "$app_id" \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')
  sig=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "$key_file" \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')
  echo "${header}.${payload}.${sig}"
}
```

#### Retry Logic

```bash
get_registration_token() {
  local attempt=1 delay=2
  while (( attempt <= 5 )); do
    response=$(curl -sf -X POST \
      -H "Authorization: token ${TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API_URL}" 2>&1)
    if [[ $? -eq 0 ]]; then
      echo "$response" | jq -r '.token'
      return 0
    fi
    log_warning "Attempt ${attempt}/5 failed (retry in ${delay}s)"
    sleep "$delay"
    (( delay *= 2, attempt++ ))
  done
  log_error "Failed to obtain registration token after 5 attempts"
  return 1
}
```

#### Signal Handling + Cleanup

```bash
_cleanup() {
  log_info "Runner received shutdown signal — deregistering"
  cd /home/runner/actions-runner
  ./config.sh remove --token "$(get_registration_token)" 2>/dev/null || true
  exit 0
}
trap _cleanup SIGTERM SIGINT
```

#### Runner Name

```bash
RUNNER_NAME="${RUNNER_NAME_PREFIX}-$(hostname -s)-$(date +%s)"
```

> If a runner with this name already exists (HTTP 422 from config.sh), re-run with
> `--replace`.

#### Full Flow

```
0. If $(id -u) == 0 and ALLOW_ROOT != "true": exit 1 with "ERROR: running as root is not supported. Set ALLOW_ROOT=true to override."
0.5. Export RUNNER_DISABLE_AUTO_UPDATE=1 (prevent auto-update crash loop)
0.6. Fix volume permissions: for each cache dir in RUNNER_TOOL_CACHE, .cargo, .npm, .nuget, .pnpm-store:
     if dir exists and not writable: attempt chown to current user; warn on failure
1. Validate required env vars → exit 1 with clear error if missing
2. Obtain registration token (with retry)
3. Run: ./config.sh --url <repo_or_org_url> --token <reg_token>
              --name <RUNNER_NAME> --labels <RUNNER_LABELS>
              --runnergroup <RUNNER_GROUP> --ephemeral --unattended
   On exit code 3 (name conflict): retry with --replace
4. Register trap for SIGTERM/SIGINT
5. Run: ./run.sh
6. On exit: cleanup (trap fires automatically for signals; exit path for normal exit)
```

### entrypoint.ps1 (Windows)

Same logic as `entrypoint.sh` but in PowerShell. Key differences:
- JWT via `System.Security.Cryptography.RSACryptoServiceProvider`
- Retry loop uses `Start-Sleep`
- Signal handling: `[Console]::CancelKeyPress` event
- Runner binary: `.\config.cmd` and `.\run.cmd`

**Exit criteria:**
- `docker run --rm -e GITHUB_TOKEN=invalid ghcr.io/oorabona/github-runner:2.332.0` exits 1
  with message `ERROR: failed to obtain registration token after 5 attempts`
- With valid token: runner appears in repo Settings > Actions > Runners within 30s
- After one job: container exits 0 and runner disappears from the UI
- `kill -SIGTERM <pid>` triggers cleanup and deregistration before exit

**Dependencies:** Blocks 2 + 3 (Dockerfiles must exist to test entrypoints)

---

## Block 5: compose.yaml

**Files:** `github-runner/compose.yaml`

```yaml
# github-runner/compose.yaml
# Usage:
#   cp .env.example .env  (fill in GITHUB_TOKEN + GITHUB_REPOSITORY or GITHUB_ORG)
#   docker compose up --scale runner=3
#
# Env file: github-runner/.env (git-ignored)
# Required vars in .env: GITHUB_TOKEN or APP_ID+APP_PRIVATE_KEY, GITHUB_REPOSITORY or GITHUB_ORG

services:
  runner:
    image: ghcr.io/oorabona/github-runner:latest
    env_file: .env
    environment:
      RUNNER_TOOL_CACHE: /cache/tool-cache
    volumes:
      - tool-cache:/cache/tool-cache
      - cargo-cache:/home/runner/.cargo
      - npm-cache:/home/runner/.npm
      - nuget-cache:/home/runner/.nuget
      - pnpm-store:/home/runner/.pnpm-store
      # DooD (Docker-outside-of-Docker) — uncomment to allow workflows to run docker commands
      # ⚠️ Security: grants container access to host Docker daemon
      # - /var/run/docker.sock:/var/run/docker.sock
    restart: "no"   # ephemeral: each container handles one job then exits

  runner-windows:
    image: ghcr.io/oorabona/github-runner:latest-windows-ltsc2022
    env_file: .env
    environment:
      RUNNER_TOOL_CACHE: C:\cache\tool-cache
    volumes:
      - windows-tool-cache:C:\cache\tool-cache
    restart: "no"
    platform: windows/amd64
    profiles:
      - windows   # opt-in: docker compose --profile windows up

volumes:
  tool-cache:
    name: github-runner-tool-cache
  cargo-cache:
    name: github-runner-cargo-cache
  npm-cache:
    name: github-runner-npm-cache
  nuget-cache:
    name: github-runner-nuget-cache
  pnpm-store:
    name: github-runner-pnpm-store
  windows-tool-cache:
    name: github-runner-windows-tool-cache
```

**`.env.example`:**

```dotenv
# Authentication — provide exactly one of:
# Option A: Personal Access Token
GITHUB_TOKEN=ghp_xxxxxxxxxxxx

# Option B: GitHub App
# APP_ID=123456
# APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\n..."

# Scope — provide exactly one of:
GITHUB_REPOSITORY=owner/repo
# GITHUB_ORG=myorg

# Optional
RUNNER_NAME_PREFIX=local
RUNNER_LABELS=self-hosted,linux
RUNNER_GROUP=Default
```

**Exit criteria:**
- `docker compose up` (Linux service) starts without errors
- `docker compose up --scale runner=3` starts 3 parallel runners, each with a unique name
- Cache volumes survive `docker compose down` (no `--volumes`)
- `docker compose --profile windows up` starts the Windows service

**Dependencies:** Block 4 (entrypoint must exist)

---

## Block 6: CI Pipeline Changes

**Files:**
- `.github/actions/build-container-windows/action.yaml` (new)
- `.github/workflows/auto-build.yaml` (modified)

### New: build-container-windows/action.yaml

PowerShell-based composite action. Mirrors `build-container/action.yaml` but:
- No Trivy scan (v1 scope)
- No SBOM (v1 scope)
- No multi-arch (Windows containers are always amd64)
- Uses `docker build` (not `buildx`) with `--platform windows/amd64`

```yaml
# .github/actions/build-container-windows/action.yaml
name: "Build Container (Windows)"
description: "Build and push a Windows Docker container image"

inputs:
  container:
    description: "Container name"
    required: true
  version:
    description: "Version tag"
    required: true
  flavor:
    description: "Flavor (base, dev)"
    required: true
    default: "base"
  push:
    description: "Push to registry"
    required: false
    default: "true"
  ghcr_token:
    description: "GHCR token"
    required: true

runs:
  using: composite
  steps:
    - name: Log in to GHCR
      shell: pwsh
      run: |
        echo "${{ inputs.ghcr_token }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

    - name: Build image
      shell: pwsh
      run: |
        $tag = "ghcr.io/${{ github.repository_owner }}/${{ inputs.container }}:${{ inputs.version }}-windows-ltsc2022-${{ inputs.flavor }}"
        docker build `
          --build-arg RUNNER_VERSION=${{ inputs.version }} `
          --build-arg FLAVOR=${{ inputs.flavor }} `
          --label "org.opencontainers.image.revision=${{ github.sha }}" `
          -t $tag `
          -f ${{ inputs.container }}/Dockerfile.windows `
          ${{ inputs.container }}/
        if (${{ inputs.push }} -eq "true") {
          docker push $tag
        }
```

### auto-build.yaml Changes

#### 1. Detect Windows variants in build matrix

In the `detect` job (or equivalent matrix-building step), add `os` field extraction:

```yaml
# In the matrix expansion step — pseudo-code showing the logic:
# For each variant in list_build_matrix():
#   if variant has "os: windows" → emit { ..., runner: "windows-latest", os: "windows" }
#   else                         → emit { ..., runner: "ubuntu-latest",  os: "linux"   }
```

The `variant_property()` helper in `variant-utils.sh` already supports arbitrary YAML
fields — `variant_property "$variant" "os"` returns `"windows"` or `""`.

#### 2. Conditional runs-on

```yaml
build:
  needs: [detect, cache-base-images]
  runs-on: ${{ matrix.runner }}   # ← was hardcoded to ubuntu-latest
  strategy:
    matrix: ${{ fromJson(needs.detect.outputs.matrix) }}
```

#### 3. Conditional build action

```yaml
    - name: Build (Linux)
      if: matrix.os != 'windows'
      uses: ./.github/actions/build-container
      with:
        container: ${{ matrix.container }}
        version: ${{ matrix.version }}
        # ... existing inputs

    - name: Build (Windows)
      if: matrix.os == 'windows'
      uses: ./.github/actions/build-container-windows
      with:
        container: ${{ matrix.container }}
        version: ${{ matrix.version }}
        flavor: ${{ matrix.flavor }}
        ghcr_token: ${{ secrets.GITHUB_TOKEN }}
```

#### 4. Skip Trivy/SBOM for Windows

```yaml
    - name: Scan with Trivy
      if: matrix.os != 'windows'
      # ... existing step
```

**Exit criteria:**
- Push to `github-runner/**` triggers `auto-build.yaml`
- Build matrix contains 6 entries (4 Linux + 2 Windows)
- Linux builds run on `ubuntu-latest`; Windows builds run on `windows-latest`
- All 6 images appear in GHCR after a successful run
- Trivy and SBOM steps are skipped for `windows-ltsc2022` variants

**Dependencies:** Blocks 2 + 3 + 4 (all Dockerfiles + entrypoints must exist)

---

## Block 7: Integration Tests + README

**Files:** `github-runner/tests/test-runner-linux.sh`, `github-runner/tests/test-runner-windows.ps1`, `github-runner/README.md`

### test-runner-linux.sh (bats)

Tests exercise entrypoint logic without live GitHub connectivity. A mock `curl` function
is injected via `PATH` prepend.

Test cases:

| Test | What it checks |
|------|---------------|
| Missing env vars | Exit 1 + correct error message when no auth env set |
| PAT path | `get_registration_token()` calls correct API endpoint |
| App path | JWT is generated and exchanged for installation token |
| Repo scope | API URL is `/repos/owner/repo/actions/runners/registration-token` |
| Org scope | API URL is `/orgs/myorg/actions/runners/registration-token` |
| Retry logic | 3 failed curl calls → 4th succeeds → token returned |
| Max retries | 5 failures → exit 1 with "5 attempts" message |
| Retry-After | Respects `Retry-After: 30` response header |
| Name conflict | Exit code 3 from config.sh → retry with `--replace` |
| SIGTERM cleanup | Signal triggers deregistration call before exit |
| Unique name | Two container starts → distinct `RUNNER_NAME` values |
| DooD socket access | If /var/run/docker.sock exists and runner is in docker group → `docker version` succeeds |

### test-runner-windows.ps1 (Pester)

Mirror of the bats tests for `entrypoint.ps1`. Uses Pester v5 mocking.

### README.md

Sections:
1. Quick start (`docker compose up`)
2. Environment variables table (all vars, required/optional, defaults)
3. Auth modes (PAT vs GitHub App) with example commands
4. Flavors reference (base vs dev)
5. Scaling (`--scale runner=N`)
6. Cache volumes (what is cached where)
7. Windows runner (platform requirements, `--profile windows`)
8. Troubleshooting (token expiry, name conflicts, no-network errors)

**Exit criteria:**
- `./test-all-containers.sh` includes `github-runner` tests and they pass
- bats test file has ≥ 11 test cases (one per row in table above)
- Pester tests pass on `windows-latest`
- README renders correctly on GitHub (no broken links)

**Dependencies:** Block 4 (entrypoint logic under test)

---

## Edge Cases and Mitigations

| Edge Case | Mitigation |
|-----------|-----------|
| Token expired (1h TTL) | Retry with backoff; token is fetched fresh on each container start |
| Runner name collision | `config.sh` exits 3 → entrypoint reruns with `--replace` |
| No network at boot | `curl -sf` fails immediately; error printed to stderr; exit 1 (no retry for DNS failure) |
| Windows without Hyper-V | Default to process isolation; no `--isolation` flag in Dockerfile |
| GitHub API rate limit | Read `Retry-After` header from 429 response; sleep accordingly |
| `RUNNER_TOOL_CACHE` volume not mounted | Warn on stderr; runner still functions; tools re-downloaded each job |
| Docker Hub rate limit for ubuntu base | Base image cached in GHCR via `base_image_cache` in config.yaml |
| `entrypoint.sh` called as root | Blocked by default; `ALLOW_ROOT=true` to override (documented security risk) |
| `APP_PRIVATE_KEY` with literal `\n` | Entrypoint converts `\n` to newlines, writes temp file, passes to openssl |
| SIGKILL (OOM/Docker kill) → orphan runner | GitHub removes offline runners after 14 days; document manual cleanup script |
| Volume UID mismatch | Entrypoint runs `chown` on cache dirs if writable; warns if not |
| Runner as root | Blocked by default; `ALLOW_ROOT=true` to override (documented security risk) |
| Runner auto-update kills container | `RUNNER_DISABLE_AUTO_UPDATE=1` set by default in entrypoint; prevents crash loop |
| Docker socket mounted but runner not in docker group | `runner` user added to `docker` group at build time; socket permissions checked in entrypoint |

---

## Implementation Order and Dependencies

```
Block 1 (scaffold)
    │
    ├── Block 2 (Linux Dockerfile)
    │       │
    │       └── Block 4a (entrypoint.sh)
    │                   │
    │                   ├── Block 5 (compose.yaml)
    │                   ├── Block 6 (CI changes)
    │                   └── Block 7 (tests + README)
    │
    └── Block 3 (Windows Dockerfile)
            │
            └── Block 4b (entrypoint.ps1)
                        │
                        ├── Block 6 (CI changes)
                        └── Block 7 (tests + README)
```

Blocks 2 and 3 are independent and can be implemented in parallel.
Block 7 depends on all prior blocks.

---

## Out of Scope (v1)

- Trivy scanning for Windows images
- SBOM attestation for Windows images
- Multi-arch Windows builds (arm64 Windows containers)
- Kubernetes runner mode (Actions Runner Controller)
- Pre-installed Rust/Node/Python in `dev` flavor (use `setup-*` actions + RUNNER_TOOL_CACHE)
- Runner autoscaling (KEDA / webhook-based)
- Custom CA certificates injection
- Ubuntu 22.04 and Debian Bookworm distros (v2 — add to variants.yaml)
- Docker-in-Docker (DinD) with `--privileged` (security risk — use DooD instead)
- GitHub Enterprise Server (GHES) support — v1 targets github.com only

These are candidates for v2 and can be tracked in TODO.md.
