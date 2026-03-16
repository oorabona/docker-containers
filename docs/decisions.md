# Architecture Decisions

## GITHUB-RUNNER — Self-hosted GitHub Actions runner container (2026-03-15)

- Lean+cache approach: no pre-installed runtimes (Rust, Node, Python) — setup-* actions + RUNNER_TOOL_CACHE persistent volume
- Multi-distro via web-shell pattern: config.yaml + variants.yaml + Dockerfile template with @@MARKERS@@ + generate-dockerfile.sh
- Windows uses standalone Dockerfile (not template) — only 1 distro (ltsc2022) doesn't justify template complexity
- Semi-ephemeral model: --ephemeral flag ensures 1 job per container, persistent Docker volumes for tool caches
- Auth: PAT + GitHub App both supported via env vars; APP_PRIVATE_KEY_FILE for Docker secrets pattern
- Runner scope: repo-level + org-level, selectable via GITHUB_REPOSITORY or GITHUB_ORG
- CI: separate build-container-windows composite action (pwsh-based), skip Trivy/SBOM for Windows v1
- DooD (Docker-outside-of-Docker) included: runner user in docker group, socket opt-in via bind mount. DinD (--privileged) excluded for security.
- MVP scope: 3 OS (ubuntu-2404, debian-trixie, windows-ltsc2022) × 2 flavors (base, dev) = 6 variants. Defer ubuntu-2204 + debian-bookworm.
- Security defaults: ALLOW_ROOT=false, RUNNER_DISABLE_AUTO_UPDATE=1, SHA256 checksum on runner download
- tini as init process for Linux images (zombie prevention + proper signal forwarding)
- GHES excluded from v1 — github.com only
- build_flavor field added to variants.yaml to separate distro reference from build flavor (base/dev)
