# ADR-005: Self-Hosted GitHub Actions Runner Container

**Status:** Accepted
**Date:** 2026-03-15

## Context

Teams using GitHub Actions hit two recurring limitations: Docker Hub pull-rate throttling on public runners, and the inability to share build caches (cargo, npm, nuget, RUNNER_TOOL_CACHE) between jobs. A self-hosted runner container solves both, but introduces its own design space: how to support multiple Linux distributions, how to register, how to keep caches warm without sacrificing ephemerality, and how to handle Windows alongside Linux.

## Decision

Ship a `github-runner` container with the following architecture:

### Multi-distro via template + generator (Linux)

Linux runners share a single `Dockerfile.linux` template with `@@MARKER@@` placeholders. `generate-dockerfile.sh` reads `config.yaml` and produces one `Dockerfile.<distro>-<flavor>` per entry. See ADR-006 for the pattern.

Supported distros: `ubuntu-2404`, `debian-trixie`, `windows-ltsc2022`. Flavors: `base` (runner + git/curl/jq) and `dev` (adds build toolchain + Tauri/WebKit deps). Language runtimes (Rust, Node, Python) are **not** pre-installed — they are pulled by `setup-*` actions and cached in `RUNNER_TOOL_CACHE`.

### Windows uses a standalone Dockerfile

Single distro (`ltsc2022`) doesn't justify template complexity. `Dockerfile.windows` uses a `FLAVOR` build-arg for the base/dev split. Built on `windows-latest` GitHub-hosted runners with the same `build-container` composite action as Linux — no separate Windows action.

### Semi-ephemeral model

Each container handles exactly one job (`--ephemeral`), but named Docker volumes persist tool caches across container restarts:

| Volume | Purpose |
|--------|---------|
| `github-runner-tool-cache` | `RUNNER_TOOL_CACHE` — setup-node/setup-python outputs |
| `github-runner-cargo-cache` | `~/.cargo` |
| `github-runner-npm-cache` | `~/.npm` |
| `github-runner-nuget-cache` | `~/.nuget` |
| `github-runner-pnpm-store` | `~/.pnpm-store` |

This keeps security properties of ephemeral runners (clean workspace per job) while avoiding the "re-download every tool every time" tax.

### Authentication: PAT or GitHub App

Both supported via env vars. App auth performs JWT generation in pure bash via `openssl dgst -sha256 -sign` — no external JWT library. `APP_PRIVATE_KEY_FILE` allows Docker Secrets integration.

Scope selection is automatic: `GITHUB_REPOSITORY` → repo-level registration; `GITHUB_ORG` → org-level.

### Docker-outside-of-Docker (DooD), not DinD

Runners join the `docker` group at build time; the host socket is bind-mounted at `docker run` time. DinD with `--privileged` is explicitly **not** supported — the security trade-off isn't worth it for this use case.

### Security defaults

- `ALLOW_ROOT=false` — container refuses to run as root unless explicitly overridden.
- `RUNNER_DISABLE_AUTO_UPDATE=1` — prevents the runner agent's self-update from killing the container mid-job.
- SHA256 checksum verification on the runner binary download.
- `tini` as init process on Linux (zombie reaping + signal forwarding).

## Consequences

- **6 variants built in CI**: 3 OS × 2 flavors. All Linux images are multi-arch (amd64/arm64); Windows is amd64-only.
- **Ephemeral + fast**: clean workspace per job, warm caches for toolchain installs.
- **No GitHub Enterprise Server** support in v1 — github.com only.
- **No Trivy/SBOM** for Windows images in v1 (asymmetry with Linux).
- **Orphan runner risk**: SIGKILL skips the deregistration trap. GitHub auto-removes offline runners after 14 days; document manual cleanup for impatient operators.
- User guide lives in `github-runner/README.md`; this ADR captures only the decisions.
