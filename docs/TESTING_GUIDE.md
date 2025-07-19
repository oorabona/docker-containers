# Testing Guide

Validate GitHub Actions workflows and containers locally before deployment.

## Quick Start

```bash
# Test all workflows
./test-github-actions.sh

# Test specific workflow
./test-github-actions.sh upstream -c sslh

# Validate version scripts
./validate-version-scripts.sh
```

## Prerequisites

### GitHub CLI + act Extension
```bash
# Install GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt update && sudo apt install gh

# Install act extension
gh extension install nektos/gh-act
gh act --version
```

### Docker Environment
```bash
# Ensure Docker is running
systemctl status docker
docker info
```

## Testing Workflows

### Syntax Validation
```bash
./test-github-actions.sh syntax
```
Validates YAML syntax without execution.

### Workflow Testing
```bash
# Test upstream monitoring
./test-github-actions.sh upstream -c wordpress --verbose

# Test auto-build workflow
./test-github-actions.sh build -c sslh

# Test version validation
./test-github-actions.sh validate

# Test complete suite
./test-github-actions.sh all
```

### Manual Workflow Triggers
```bash
# Trigger upstream monitoring
gh workflow run upstream-monitor.yaml --field container=wordpress --field debug=true

# Trigger auto-build
gh workflow run auto-build.yaml --field container=sslh

# Trigger version validation
gh workflow run validate-version-scripts.yaml
```

## Container Testing

### Version Script Validation
```bash
# Test all version scripts
./validate-version-scripts.sh

# Test specific container
cd container-name
./version.sh current
./version.sh latest
```

### Build Testing
```bash
# Build specific container
./make build container-name

# Test container locally
./make run container-name

# Check container health
docker ps
docker logs container-name
```

### Integration Testing
```bash
# Test complete workflow
./test-all-containers.sh

# Performance testing
time ./make build wordpress
docker images wordpress --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
```

## Troubleshooting

### Common Issues

**act Extension Issues:**
```bash
# Install/update act extension
gh extension install nektos/gh-act
gh extension upgrade nektos/gh-act
gh extension list
```

**Docker/Podman Issues:**
Please refer to [Docker](https://www.docker.com) or [Podman](https://podman.io).

**Workflow Syntax Errors:**
```bash
# Validate workflow syntax
gh act -n -l
gh act -W .github/workflows/upstream-monitor.yaml -n
```

**Network/API Failures:**
Expected in local testing - indicates rate limits or authentication issues, not workflow problems.

### Debug Techniques

**Verbose Testing:**
```bash
./test-github-actions.sh --verbose
gh act workflow_dispatch -W .github/workflows/upstream-monitor.yaml --verbose
```

**Test Minimal Workflow:**
```bash
gh act -W - << 'EOF'
name: Test
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Hello World"
EOF
```

**Check Available Events:**
```bash
gh act -l
gh act -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest --list
```

## Best Practices

- **Test locally** before pushing workflow changes
- **Use specific containers** for targeted testing
- **Enable verbose mode** when debugging
- **Validate syntax** first, then test execution
- **Check prerequisites** before running tests

---

**Last Updated**: July 2025
