# ADR-006: Multi-Distro Variants via Template + Generator Pattern

**Status:** Accepted
**Date:** 2026-02-26

## Context

Two containers need to support multiple Linux distributions:

- `web-shell` — users want to pick their familiar package manager (Debian, Alpine, Ubuntu, Rocky).
- `github-runner` — Linux distros differ in available CI tooling and base image policies (ubuntu-2404, debian-trixie).

Naïvely, N distros means N Dockerfiles, with near-identical structure but distro-specific package manager calls, user creation syntax, and repository setup (e.g., Rocky needs EPEL for `jq`). Duplication leads to drift.

## Decision

Use a **template + generator** pattern driven by declarative `config.yaml`:

```
<container>/
├── Dockerfile.template        # Single Dockerfile with @@MARKER@@ placeholders
├── generate-dockerfile.sh     # Reads config.yaml, expands template per distro
└── config.yaml                # distros: section with per-distro configuration
```

The generic expansion engine lives in `helpers/template-utils.sh` (`expand_template()`) and is shared by all containers using the pattern.

### Per-distro configuration

Each distro entry in `config.yaml` declares:

| Field | Purpose |
|-------|---------|
| `base_image` | FROM reference (may use Docker ARG syntax like `${DEBIAN_TAG}`) |
| `pkg_manager` | `apt` / `apk` / `dnf` |
| `install_cmd` / `cleanup_cmd` | Package manager syntax |
| `pre_install` | Optional setup (e.g., Rocky `dnf install -y epel-release`) |
| `shell_user` + `user_exists` | User creation behavior (skip if the base image already has the target user) |
| `packages` | Meta-groups (editors, network, monitoring, etc.) flattened at generation |

### Template markers

Markers must be on their own line — the engine replaces entire lines. Generator scripts emit complete Dockerfile instructions for each marker.

| Marker | Replaced with |
|--------|---------------|
| `@@BASE_IMAGE@@` | `FROM <base_image>` |
| `@@INSTALL_PACKAGES@@` | `RUN <pre_install> && <install_cmd> <packages> && <cleanup>` |
| `@@USER_SETUP@@` | User creation + sudo config (skipped if `user_exists: true`) |
| `@@SSH_SETUP@@` / etc. | Per-container extensions |

### Build digest stability

`compute_build_digest()` hashes `Dockerfile.template` + `config.yaml` — the stable inputs — not the transient generated Dockerfile. This keeps rebuild detection correct when only the generator output changes due to template expansion.

## Consequences

- **One Dockerfile per container**, regardless of distro count.
- **Adding a distro = YAML edit** (declare in `config.yaml distros:` + add variant in `variants.yaml`).
- **Generator invoked automatically** by `scripts/build-container.sh` when `generate_dockerfile: true` is set in `config.yaml`.
- **Per-distro quirks stay localised** in `config.yaml` (EPEL, BusyBox `adduser`, `wheel` vs `sudo` group) rather than being scattered across Dockerfiles.
- **Constraint**: all distros must fit the same high-level Dockerfile structure. A distro requiring a fundamentally different build flow (e.g., musl-specific linking) warrants a standalone Dockerfile — see `github-runner/Dockerfile.windows` for the escape hatch.
- **Current users**: `web-shell` (4 distros), `github-runner` (2 Linux distros).
