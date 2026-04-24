---
layout: post
title: "Self-Hosted GitHub Actions Runners in Docker: Ubuntu, Debian Trixie, and Windows Server 2022"
description: "Multi-distro self-hosted runner family — Ubuntu 24.04, Debian Trixie, Windows ltsc2022, each in base (289 MB) and dev (574+ MB with build tools) flavors."
date: 2026-04-30 10:00:00 +0000
tags: [github-actions, self-hosted-runner, docker, windows-containers, ci-cd]
---

GitHub's hosted runners are great until:

- You need to build for a specific distro or kernel version
- Your workflow needs special hardware (GPU, ARM, FPGA)
- Pricing surprises you on month-end
- Your org requires keeping build artifacts on-prem

Then you run self-hosted runners, and you discover the actual challenge: maintaining the runner image. The official `actions/runner` repo gives you the binary; everything else — OS choice, tool preinstall, ephemeral lifecycle, Docker-in-Docker, credential flow — you build yourself.

The `oorabona/github-runner` image family is a reusable baseline: **three OSs × two flavors** with the glue already wired up.

## The matrix

| Variant | Compressed (amd64) | Use case |
|---|---|---|
| `2.334.0` (ubuntu-2404 base) | **289 MB** | Default — general workflows on Ubuntu LTS |
| `2.334.0-dev` | **574 MB** | Ubuntu + `build-essential`, Rust toolchain, WebKit deps (Tauri), pkg-config |
| `2.334.0-debian-trixie` | **348 MB** | Debian Trixie base (newer packages, shorter EOL cycle) |
| `2.334.0-debian-trixie-dev` | **727 MB** | Debian + full build toolchain |
| `2.334.0-windows-ltsc2022` | — | Windows Server Core — small footprint, no GUI |
| `2.334.0-windows-ltsc2022-dev` | — | **Full Windows Server** — VS Build Tools + SDK (rc.exe needs `USER32.dll` which only full Server provides) |

`base` is for "run a workflow on a known OS." `dev` is for "build native code that needs compilers and system libs."

## Architecture

Every runner image bundles:

- `actions/runner` binary (version matches the tag)
- `runner` user (uid 1001) with sudoers NOPASSWD
- Graceful shutdown handler on SIGTERM
- Pre-installed tool cache mount points (`/home/runner/.cargo`, `/home/runner/.npm`, etc.)
- Three auth modes (see below)

Linux variants are generated from a single `Dockerfile.linux` template via `generate-dockerfile.sh` — distros live in `config.yaml` so adding a new one means adding 15 lines of YAML, not a whole Dockerfile.

Windows is its own file (`Dockerfile.windows`) because the Chocolatey-free install path, SHELL switches, and VS Build Tools setup don't share much with Linux.

## Three auth modes

```bash
# Mode 1: direct runner registration token (1h expiry, one-shot)
docker run -d --name runner \
  -e RUNNER_TOKEN=ABCDEF... \
  -e RUNNER_URL=https://github.com/myorg/myrepo \
  -e RUNNER_NAME=ci-01 \
  --restart unless-stopped \
  ghcr.io/oorabona/github-runner:2.334.0

# Mode 2: Personal Access Token (the runner exchanges it for a registration token)
docker run -d --name runner \
  -e GITHUB_PAT=ghp_xxx \
  -e RUNNER_URL=https://github.com/myorg/myrepo \
  ghcr.io/oorabona/github-runner:2.334.0

# Mode 3: GitHub App (best — no long-lived secret, scoped permissions)
docker run -d --name runner \
  -e GITHUB_APP_ID=3113413 \
  -e GITHUB_APP_INSTALLATION_ID=117019019 \
  -e GITHUB_APP_PRIVATE_KEY_PATH=/secrets/app.pem \
  -v /path/to/app.pem:/secrets/app.pem:ro \
  ghcr.io/oorabona/github-runner:2.334.0
```

The GitHub App mode mints a JWT with RS256, exchanges it for an installation token, then uses that to get a runner registration token — all before the runner process starts. No secret lives on disk longer than necessary.

Works at both **repo scope** and **org scope** — set `RUNNER_URL` to the org URL for org-wide runners.

## Ephemeral + persistent caches

`--ephemeral` is the right default for self-hosted: each workflow run gets a fresh runner that deregisters itself afterwards. Clean state = no leakage between jobs.

But ephemeral + "fresh every time" = you re-download every `cargo` dep on every build. Compromise: persistent **tool caches** mounted from the host:

```yaml
# compose.yml
services:
  runner:
    image: ghcr.io/oorabona/github-runner:2.334.0-dev
    environment:
      RUNNER_TOKEN_FILE: /secrets/token
      RUNNER_URL: https://github.com/myorg/myrepo
      RUNNER_EPHEMERAL: "true"
      RUNNER_TOOL_CACHE: /opt/hostedtoolcache  # preserved across runs
    volumes:
      - /secrets/token:/secrets/token:ro
      - tool-cache:/opt/hostedtoolcache
      - cargo-cache:/home/runner/.cargo
      - npm-cache:/home/runner/.npm
      - pnpm-cache:/home/runner/.local/share/pnpm
      - /var/run/docker.sock:/var/run/docker.sock  # docker-in-docker
    restart: unless-stopped

volumes:
  tool-cache:
  cargo-cache:
  npm-cache:
  pnpm-cache:
```

Runner state (ephemeral) + tool downloads (persistent) = fast subsequent builds without dirty cross-run artifacts.

## Windows: yes, real Windows

The `windows-ltsc2022` variants are real Windows containers (not WSL). The `base` flavor uses Server Core (smaller, no GUI). The `dev` flavor uses the **full** Server image — necessary because `rc.exe` (Resource Compiler) loads `USER32.dll`, which requires window-station APIs that Server Core doesn't ship.

Install flow: no Chocolatey. Everything is direct-download from GitHub releases:

- **PowerShell 7** via MSI from PowerShell/PowerShell
- **Git for Windows** via the official Git-X.Y.Z(.N)-64-bit.exe installer
- **jq** from jqlang/jq releases (single `.exe`)

Chocolatey's `community.chocolatey.org` API returns 503 often enough that we just cut it out of the path — the install succeeds the first try, every time.

On the host (Docker Desktop for Windows), the workflow is:

```powershell
docker run -d `
  --name runner-win `
  --isolation process `
  -e RUNNER_TOKEN="$env:RUNNER_TOKEN" `
  -e RUNNER_URL="https://github.com/myorg/myrepo" `
  --restart unless-stopped `
  ghcr.io/oorabona/github-runner:2.334.0-windows-ltsc2022
```

## Scaling beyond one runner

Three patterns, in order of operational weight:

1. **Several compose projects on one host** — fine for up to ~10 runners. Each runs as `--ephemeral`, so concurrency is natural.
2. **Docker Swarm / Kubernetes with [actions-runner-controller](https://github.com/actions/actions-runner-controller)** — ARC auto-scales runner pods based on job queue depth. This image works as the pod image.
3. **Kubernetes with [Runner Scale Sets](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller)** — the newer ARC model. Same image, different controller.

For a typical org (5–100 runners), Swarm + a simple scale-up script on queue depth handles most of it without pulling in Kubernetes.

## Gotchas

- **Docker socket mount** gives the runner root-equivalent access to the host. Use rootless Docker or sysbox if that matters.
- **Windows** can't bind-mount individual files (only directories). Plan your secrets layout accordingly.
- **`ContainerAdmin` is the default user in Windows containers** — some GitHub Actions assume UNIX-style users; set `USER runner` after tool install if it matters.
- **Don't forget `docker system prune`** in the dev images during build — the VS Build Tools installer leaves hundreds of MBs of cache that shouldn't ship.
- **Token rotation** — runner registration tokens expire after 1 hour. Use GitHub App mode for anything long-lived.

## What's tracked automatically

Daily upstream monitor picks up:

- **`actions/runner`** releases (PR opens when a new version ships)
- **PowerShell/PowerShell** for Windows
- **git-for-windows/git** for the Windows Git installer
- **jqlang/jq** for jq
- Base image tags (ubuntu:24.04, debian:trixie, Windows Server Core/Server)

Minor/patch auto-merges; majors wait for review. If a new `runner` version breaks something in your workflows, pin the tag — every version stays in GHCR and Docker Hub with retention = 3.

## TL;DR

```bash
# Ubuntu, general use
docker pull ghcr.io/oorabona/github-runner:2.334.0                 # 289 MB

# Ubuntu + build tools
docker pull ghcr.io/oorabona/github-runner:2.334.0-dev             # 574 MB

# Debian Trixie variant
docker pull ghcr.io/oorabona/github-runner:2.334.0-debian-trixie   # 348 MB

# Windows
docker pull ghcr.io/oorabona/github-runner:2.334.0-windows-ltsc2022
```

All variants and auth examples: [container dashboard](/docker-containers/container/github-runner/).

If you're running this in anger, [⭐ the repo](https://github.com/oorabona/docker-containers) — we use the star count to decide when to invest in more niche features like GPU or ARM Windows.
