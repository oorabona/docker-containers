# Local Development Guide

Complete guide for setting up and developing with the Docker containers repository.

## Prerequisites

### Required Software

```bash
# Docker Engine (20.10+)
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Docker Compose v2
sudo apt-get install docker-compose-plugin

# Basic tools
sudo apt-get install git jq curl bash
```

> NB: This also works with Podman, please refer to their installation guide.

### Optional Development Tools

```bash
# GitHub CLI (for workflow testing)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
  sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo apt update && sudo apt install gh

# ShellCheck (shell script linting)
sudo apt install shellcheck
```

## Environment Setup

### 1. Repository Setup

```bash
# Clone and configure
git clone https://github.com/oorabona/docker-containers.git
cd docker-containers

# Make scripts executable
chmod +x make
find . -name "*.sh" -exec chmod +x {} \;

# Verify setup
./make targets
```

### 2. Development Environment

Create `.env` file for local configuration:

```bash
cat > .env << 'EOF'
# Docker configuration
DOCKER_BUILDKIT=1
BUILDX_NO_DEFAULT_ATTESTATIONS=1
COMPOSE_DOCKER_CLI_BUILD=1

# Build settings
NPROC=$(nproc)
DEBUG=false
FORCE_REBUILD=false

# Registry settings (for testing)
REGISTRY_URL=localhost:5000
EOF
```

## Development Workflows

### Working with Existing Containers

```bash
# List all containers
./make targets

# Check versions
./make version wordpress     # Current version
cd wordpress && ./version.sh latest  # Latest upstream

# Build and test
./make build wordpress
./make run wordpress

# Debug build issues
DEBUG=1 ./make build wordpress
```

### Creating New Containers

```bash
# Create container structure
mkdir my-app && cd my-app

# Create Dockerfile
cat > Dockerfile << 'EOF'
FROM alpine:3.18

# Install dependencies
RUN apk add --no-cache curl bash

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -s /bin/bash -u 1000 -G appuser appuser

# Copy application
COPY app.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/app.sh

USER appuser
WORKDIR /app
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

CMD ["app.sh"]
EOF

# Create version script
cat > version.sh << 'EOF'
#!/bin/bash
# Version management for my-app

get_latest_version() {
    # Example: GitHub releases API
    local repo="owner/repo"
    local version
    
    version=$(curl -s --fail --max-time 30 \
        "https://api.github.com/repos/${repo}/releases/latest" | \
        jq -r '.tag_name // empty' | \
        sed 's/^v//')
    
    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
    else
        echo "unknown"
        exit 1
    fi
}

case "${1:-current}" in
    latest) get_latest_version ;;
    current|*)
      # For containers not yet published to registries:
      # Return "no-published-version" and exit with code 1
      # This is handled gracefully by validation and workflows
      source "$(dirname "$0")/../helpers/docker-tags"
      if ! current_version=$(latest-docker-tag owner/repo "^v[0-9]+\.[0-9]+\.[0-9]+$"); then
          echo "no-published-version"
          exit 1
      fi
      echo "$current_version"
      ;;
esac
EOF

chmod +x version.sh

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  my-app:
    build: .
    ports:
      - "8080:8080"
    environment:
      - APP_ENV=${APP_ENV:-development}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

# Test the container
cd .. && ./make build my-app && ./make run my-app
```

## Testing and Validation

### Version Script Testing

```bash
# Test all version scripts
./validate-version-scripts.sh

# Test specific container version script
cd wordpress
./version.sh          # Current version
./version.sh latest    # Latest upstream version

# Debug version script issues
bash -x ./version.sh latest
```

### Local GitHub Actions Testing

```bash
# Install GitHub CLI act extension
gh extension install nektos/gh-act

# Test workflows locally
./test-github-actions.sh

# Test specific workflows
./test-github-actions.sh upstream -c wordpress --verbose
./test-github-actions.sh build -c ansible
./test-github-actions.sh validate
```

### Container Testing

```bash
# Quick container test
./make build wordpress
./make run wordpress

# Test with health checks
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Performance testing
time ./make build wordpress  # Build time
docker images wordpress --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
```

## Development Tools

### Make Script Commands

```bash
# Core operations
./make targets              # List all containers
./make build                # Build all containers  
./make build wordpress      # Build specific container
./make version wordpress    # Check version
./make run wordpress        # Run container

# Advanced operations
DEBUG=1 ./make build wordpress     # Debug build
./make build wordpress 6.1.1       # Build specific version
```

### Quality Tools

```bash
# Dockerfile linting
docker run --rm -i hadolint/hadolint < Dockerfile

# Shell script linting
shellcheck **/*.sh

# Container security scanning (example)
docker scout cves wordpress:latest
```

### Development Helpers

```bash
# Useful aliases for ~/.bashrc
alias dcb='./make build'
alias dcr='./make run' 
alias dcv='./make version'
alias dct='./make targets'

# Docker helpers
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dimg='docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"'
alias dclean='docker system prune -af'
```

## Troubleshooting

### Common Issues

**Build Failures:**
```bash
# Check Docker daemon
systemctl status docker

# Clean Docker cache
docker system prune -af

# Rebuild with no cache
docker build --no-cache .

# Check disk space
df -h
```

**Version Script Issues:**
```bash
# Debug script execution
cd container-name
bash -x ./version.sh latest

# Test network connectivity
curl -I https://api.github.com

# Validate JSON parsing
curl -s "https://api.github.com/repos/owner/repo/releases/latest" | jq .
```

**Permission Issues:**
```bash
# Fix script permissions
find . -name "*.sh" -exec chmod +x {} \;

# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### Debug Techniques

**Enable Debug Output:**
```bash
# Global debug mode
export DEBUG=1

# Docker build debugging
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain

# Shell script debugging
set -x  # Enable trace mode
```

**Container Debugging:**
```bash
# Run container interactively
docker run -it --rm container-name:latest sh

# Inspect container configuration
docker inspect container-name:latest

# Check running container logs
docker logs container-name

# Execute commands in running container
docker exec -it container-name sh
```

## Best Practices

### Code Quality
- Use `shellcheck` for shell scripts
- Use `hadolint` for Dockerfiles  
- Follow consistent naming conventions
- Add comprehensive documentation

### Security
- Use non-root users in containers
- Keep base images updated
- Minimize container attack surface
- Scan for vulnerabilities regularly

### Performance
- Use multi-stage builds
- Optimize layer ordering
- Use `.dockerignore` files
- Cache dependencies effectively

### Version Scripts
- Handle network timeouts gracefully
- Validate version format before returning
- Use semantic versioning when possible
- Document version source clearly

---

**Last Updated**: July 2025
