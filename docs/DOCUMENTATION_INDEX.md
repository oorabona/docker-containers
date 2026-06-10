# Documentation Index

## Guides

| Document | Purpose |
|----------|---------|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Contributor guide — extensions, variants, build system |
| [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md) | Run builds and tests locally |
| [TESTING_GUIDE.md](TESTING_GUIDE.md) | Test harness, `act` usage, CI parity |
| [GITHUB_ACTIONS.md](GITHUB_ACTIONS.md) | CI/CD workflows reference |
| [WORKFLOW_ARCHITECTURE.md](WORKFLOW_ARCHITECTURE.md) | End-to-end automation flow |
| [CONTAINER_CONFIG.md](CONTAINER_CONFIG.md) | `config.yaml` schema and build args |
| [CONTAINER_SIZE_OPTIMIZATION.md](CONTAINER_SIZE_OPTIMIZATION.md) | Image size best practices |

## Architecture Decision Records

| ADR | Title |
|-----|-------|
| [ADR-001](adr/ADR-001-multi-platform-native-runners.md) | Multi-platform native runners |
| [ADR-002](adr/ADR-002-smart-rebuild-detection.md) | Smart rebuild detection |
| [ADR-003](adr/ADR-003-variant-system.md) | Declarative variant system |
| [ADR-004](adr/ADR-004-build-lineage-tracking.md) | Build lineage tracking |
| [ADR-005](adr/ADR-005-github-runner-container.md) | GitHub Actions runner container |
| [ADR-006](adr/ADR-006-multi-distro-template-pattern.md) | Multi-distro template pattern |
| [ADR-007](adr/ADR-007-phase-c-redesign.md) | Dashboard Phase C redesign |
| [ADR-008](adr/ADR-008-trivy-severity-policy.md) | Trivy severity policy |
| [ADR-009](adr/ADR-009-dockerhub-pullthrough-mirror.md) | Docker Hub pull-through mirror |
| [ADR-010](adr/ADR-010-chained-on-own-and-digest-drift.md) | Chained-on-own marker + digest drift detection |
| [ADR-011](adr/ADR-011-cascade-aware-drift-detection.md) | Cascade-aware drift detection |
| [ADR-012](adr/ADR-012-version-drift-guard.md) | Version drift guard |
| [ADR-013](adr/ADR-013-dependency-ordered-builds.md) | Dependency-ordered container builds (bake engine) |
| [ADR-014](adr/ADR-014-postbuild-supply-chain-convergence.md) | Post-build supply-chain convergence |
| [ADR-015](adr/ADR-015-postgres-final-build-to-bake.md) | postgres final build → bake (extension-container framework) |

## Container Documentation

Each container directory contains a `README.md` with usage, environment variables, and examples. See the repository root `README.md` for the full list of containers.

## Backlog

- [TODO.md](../TODO.md) — active backlog and ideas
