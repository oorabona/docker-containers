---
name: project-experience
description: |
  Project-specific patterns, conventions, and learnings for docker-containers.
  Triggers: "project patterns", "how does this project", "project conventions",
  "local setup", "build order", "test setup", "project-specific".
  Auto-loaded when working in this repository.
version: 1.0.0
---

# Project Experience: docker-containers

_This file captures project-specific patterns and conventions._
_Updated by `/skills update` when learnings are captured._

---

## Stack Components

| Component | Technology | Notes |
|-----------|------------|-------|
| Language | Bash | Shell scripts for automation |
| Container | Docker + BuildKit | Multi-arch builds |
| CI/CD | GitHub Actions | 4 workflows |
| Docs | Jekyll | GitHub Pages |
| Testing | Custom shell | test-all-containers.sh |

---

## Key Patterns

### Version Discovery Pattern

Each container has a `version.sh` script that:
1. Queries upstream source (GitHub API, package repos, etc.)
2. Outputs JSON with version info
3. Handles network failures gracefully

```bash
# Example: postgres/version.sh
curl -s https://api.github.com/repos/postgres/postgres/tags | jq -r '.[0].name'
```

### Build Script Pattern

The `./make` script is the main entry point:
- Discovers targets from Dockerfile locations
- Delegates to scripts in `scripts/` directory
- Uses helpers from `helpers/` directory

### Logging Pattern

All scripts use `helpers/logging.sh`:
```bash
source "$(dirname "$0")/helpers/logging.sh"
log_info "Message"
log_error "Error message"
log_help "command" "description"
```

---

## Workflow Patterns

### GitHub Actions

1. **upstream-monitor.yaml** - Scheduled checks for new versions
2. **auto-build.yaml** - Triggered builds when updates found
3. **update-dashboard.yaml** - Regenerates index.md status page
4. **validate-version-scripts.yaml** - PR validation

### Local Testing with `act`

```bash
# Run workflow locally
act -j <job-name> --secret-file .env
```

See `.actrc` for default configuration.

---

## Test Setup

### Prerequisites
- Docker daemon running
- Network access for image pulls

### Running Tests
```bash
./test-all-containers.sh        # Full test suite
./test-github-actions.sh        # Test workflow logic
./validate-version-scripts.sh   # Validate version.sh files
```

---

## Debugging Tips

- Check `build.log` for recent build output
- Use `./make version <container>` to debug version detection
- Dashboard stats in `.dashboard-stats`
- Test logs in `test-logs/` directory

---

## Related Files

- See `GOTCHAS.md` for project-specific gotchas and workarounds
