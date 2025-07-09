# Testing Guide

This guide explains how to test GitHub Actions workflows locally before pushing changes.

## Quick Start

```bash
# Test everything
./test-github-actions.sh

# Test specific components
./test-github-actions.sh syntax
./test-github-actions.sh upstream -c sslh
./test-github-actions.sh validate --verbose
```

## Prerequisites

### Install GitHub CLI

First, install the GitHub CLI:

```bash
# Ubuntu/Debian
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh

# macOS with Homebrew
brew install gh

# Windows with Chocolatey
choco install gh

# Windows with winget
winget install --id GitHub.cli
```

### Install act as a GitHub CLI Extension

Once GitHub CLI is installed, install act as an extension:

```bash
# Install the act extension
gh extension install https://github.com/nektos/gh-act

# Verify installation
gh act --version

# Alternative: Install from the GitHub CLI extension marketplace
gh extension install nektos/gh-act
```

**Note:** Using `gh act` instead of standalone `act` provides better integration with GitHub CLI authentication and configuration.

### Ensure Docker is Running

```bash
# Start Docker (Linux)
sudo systemctl start docker

# Check Docker status
docker info
```

## Test Commands

### Test Syntax Only
```bash
./test-github-actions.sh syntax
```
Validates YAML syntax of all workflow files without executing them.

### Test Upstream Monitoring
```bash
./test-github-actions.sh upstream
./test-github-actions.sh upstream -c wordpress --verbose
```
Tests the upstream version monitoring workflow with a specific container.

### Test Auto-Build
```bash
./test-github-actions.sh build
./test-github-actions.sh build -c nginx-rancher-rp
```
Tests the container auto-build workflow (dry-run only, no actual building).

### Test Version Validation
```bash
./test-github-actions.sh validate
./test-github-actions.sh validate --verbose
```
Tests the version script validation workflow.

### Test Individual Actions
```bash
./test-github-actions.sh actions
./test-github-actions.sh actions -c terraform
```
Tests individual GitHub Actions in isolation.

### Run Complete Test Suite
```bash
./test-github-actions.sh all
./test-github-actions.sh  # same as 'all'
```
Runs all tests in sequence.

## Advanced Testing

### Full Integration Testing
```bash
FULL_TEST=true ./test-github-actions.sh
```
Enables real API calls and network operations (use with caution).

### Dry Run Mode
```bash
./test-github-actions.sh --dry-run
```
Shows what tests would run without actually executing them.

### Verbose Output
```bash
./test-github-actions.sh --verbose
./test-github-actions.sh upstream -v
```
Enables detailed logging and command output.

### Test Specific Container
```bash
./test-github-actions.sh upstream -c sslh
./test-github-actions.sh build -c elasticsearch-conf
```
Tests workflows with a specific container instead of the default (wordpress).

## Common Issues and Solutions

### act Extension Not Found
```bash
# Install act as GitHub CLI extension
gh extension install nektos/gh-act

# Verify installation
gh act --version

# List installed extensions
gh extension list

# Update act extension
gh extension upgrade nektos/gh-act
```

### Docker Not Running
```bash
# Linux
sudo systemctl start docker
sudo usermod -aG docker $USER  # Add user to docker group

# Verify
docker info
```

### Workflow Syntax Errors
```bash
# Check syntax with gh act
gh act -n -l

# Validate specific workflow
gh act -W .github/workflows/upstream-monitor.yaml -n
```

### Action Path Issues
Ensure action references use correct paths:
```yaml
uses: ./.github/actions/check-upstream-versions  # Correct
uses: .github/actions/check-upstream-versions    # Wrong
```

### Network/API Issues
Some tests may fail due to:
- Missing authentication tokens
- Network connectivity issues  
- Rate limiting

These are expected in local testing and don't indicate problems with the workflow logic.

## Workflow Triggers

### Manual Triggers (GitHub CLI)
```bash
# Trigger upstream monitoring
gh workflow run upstream-monitor.yaml --field container=wordpress --field debug=true

# Trigger auto-build
gh workflow run auto-build.yaml --field container=sslh

# Trigger validation
gh workflow run validate-version-scripts.yaml --field container=all
```

### Local Triggers (gh act)
```bash
# Trigger with specific inputs
gh act workflow_dispatch -W .github/workflows/upstream-monitor.yaml \
  --input container=wordpress \
  --input debug=true \
  --input create_pr=false

# Test push event
gh act push -W .github/workflows/auto-build.yaml

# Test pull request event  
gh act pull_request -W .github/workflows/validate-version-scripts.yaml
```

## Test Development

### Adding New Tests

1. Add test function to `test-github-actions.sh`:
```bash
test_my_feature() {
    log_step "Testing My Feature"
    # Test implementation
}
```

2. Add to main function:
```bash
case "$COMMAND" in
    my-feature)
        test_my_feature || ((failed_tests++))
        ;;
esac
```

3. Update usage documentation.

### Debugging Tests

```bash
# Enable verbose mode
./test-github-actions.sh --verbose

# Check gh act version and platform
gh act --version
gh act -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest --list

# Test minimal workflow
gh act -W - << 'EOF'
name: Test
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Hello World"
EOF

# Debug specific workflow with verbose output
gh act workflow_dispatch -W .github/workflows/upstream-monitor.yaml --verbose

# List available events and jobs
gh act -l
```

## Best Practices

1. **Always test locally** before pushing workflow changes
2. **Use dry-run mode** when developing new tests
3. **Test with different containers** to ensure workflows are generic
4. **Check prerequisites** before running tests
5. **Use verbose mode** when debugging issues
6. **Keep tests fast** by using dry-run and skip flags where possible

## Further Reading

- [gh-act Extension](https://github.com/nektos/gh-act) - GitHub CLI extension for act
- [act Documentation](https://github.com/nektos/act) - Original act project
- [GitHub CLI Extensions](https://cli.github.com/manual/gh_extension) - Managing CLI extensions
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Local Development Guide](LOCAL_DEVELOPMENT.md)
- [GitHub Actions Guide](GITHUB_ACTIONS.md)
