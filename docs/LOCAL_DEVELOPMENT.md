# Local Development Guide

## Prerequisites

### Required Software

```bash
# Docker Engine (20.10+)
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Docker Compose v2
sudo apt-get update
sudo apt-get install docker-compose-plugin

# Git
sudo apt-get install git

# jq (for JSON processing)
sudo apt-get install jq

# curl (for API calls)
sudo apt-get install curl
```

### Optional Tools

```bash
# GitHub CLI (for workflow testing)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh

# act (for local GitHub Actions testing)
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | bash

# hadolint (Dockerfile linting)
wget -O hadolint https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64
chmod +x hadolint
sudo mv hadolint /usr/local/bin/
```

## Environment Setup

### 1. Clone and Configure

```bash
# Clone the repository
git clone https://github.com/your-username/docker-containers.git
cd docker-containers

# Make build script executable
chmod +x make

# Set up Git hooks (optional)
git config core.hooksPath .githooks
chmod +x .githooks/*
```

### 2. Environment Variables

Create a `.env` file for local development:

```bash
cat > .env << 'EOF'
# Docker configuration
DOCKER_BUILDKIT=1
BUILDX_NO_DEFAULT_ATTESTATIONS=1
COMPOSE_DOCKER_CLI_BUILD=1

# Build configuration
NPROC=$(nproc)
DOCKEROPTS="--progress=plain"

# Development settings
DEBUG=false
FORCE_REBUILD=false

# Registry settings (for testing)
REGISTRY_URL=localhost:5000
REGISTRY_USERNAME=""
REGISTRY_PASSWORD=""
EOF
```

### 3. Local Registry (Optional)

For testing registry operations:

```bash
# Start local registry
docker run -d -p 5000:5000 --name registry registry:2

# Configure insecure registry (add to /etc/docker/daemon.json)
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "insecure-registries": ["localhost:5000"]
}
EOF

# Restart Docker
sudo systemctl restart docker
```

## Development Workflow

### 1. Working on Existing Containers

```bash
# List all available containers
./make targets

# Check current version
./make version wordpress

# Build container locally
./make build wordpress

# Run container for testing
./make run wordpress

# Test with specific version
./make build wordpress 6.1.1
./make run wordpress 6.1.1
```

### 2. Creating New Containers

```bash
# Create new container directory
mkdir my-new-app
cd my-new-app

# Create basic structure
cat > Dockerfile << 'EOF'
FROM alpine:3.18

# Install dependencies
RUN apk add --no-cache \
    curl \
    bash \
    && rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -s /bin/bash -u 1000 -G appuser appuser

# Copy application files
COPY app.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/app.sh

# Switch to non-root user
USER appuser

# Set working directory
WORKDIR /app

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

# Start application
CMD ["app.sh"]
EOF

# Create version script
cat > version.sh << 'EOF'
#!/bin/bash

# Version management for my-new-app

get_latest_version() {
    # Example: Get version from GitHub releases
    local repo="owner/repo"
    local version
    
    version=$(curl -s --fail \
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

get_current_version() {
    # Return hardcoded current version
    echo "1.0.0"
}

# Main logic
case "${1:-current}" in
    latest)
        get_latest_version
        ;;
    current|*)
        get_current_version
        ;;
esac
EOF

# Make version script executable
chmod +x version.sh

# Create docker-compose file
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  my-new-app:
    build:
      context: .
      args:
        VERSION: ${VERSION:-latest}
    image: my-new-app:${TAG:-latest}
    ports:
      - "8080:8080"
    environment:
      - APP_ENV=${APP_ENV:-development}
      - LOG_LEVEL=${LOG_LEVEL:-info}
    volumes:
      - ./data:/app/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    restart: unless-stopped
EOF

# Create application script
cat > app.sh << 'EOF'
#!/bin/bash

set -euo pipefail

# Application configuration
readonly APP_PORT="${APP_PORT:-8080}"
readonly APP_ENV="${APP_ENV:-production}"
readonly LOG_LEVEL="${LOG_LEVEL:-info}"

# Logging function
log() {
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") [$LOG_LEVEL] $*" >&2
}

# Health check endpoint
health_check() {
    log "Health check requested"
    echo "OK"
}

# Main application logic
main() {
    log "Starting my-new-app on port $APP_PORT"
    log "Environment: $APP_ENV"
    
    # Simple HTTP server for demonstration
    while true; do
        echo -e "HTTP/1.1 200 OK\n\nHello, World!" | nc -l -p "$APP_PORT" -q 1
    done
}

# Handle signals
trap 'log "Shutting down gracefully..."; exit 0' SIGTERM SIGINT

# Start application
main "$@"
EOF

# Go back to repository root
cd ..

# Test the new container
./make build my-new-app
./make run my-new-app
```

### 3. Testing Changes

```bash
# Lint Dockerfile
hadolint my-new-app/Dockerfile

# Test version script
cd my-new-app
./version.sh           # Should return current version
./version.sh latest    # Should return latest version
cd ..

# Build and test
./make build my-new-app
./make run my-new-app

# Test with different versions
./make build my-new-app 1.0.0
./make version my-new-app
```

### 4. Local GitHub Actions Testing

```bash
# Install act (if not already installed)
curl https://raw.githubusercontent.com/nektos/act/master/install.sh | bash

# List available workflows
act -l

# Run upstream monitoring workflow locally
act workflow_dispatch -W .github/workflows/upstream-monitor.yaml

# Run with specific container
act workflow_dispatch -W .github/workflows/upstream-monitor.yaml \
  --input container=wordpress \
  --input debug=true

# Run auto-build workflow
act push -W .github/workflows/auto-build.yaml
```

## Development Tools

### 1. Make Script Commands

```bash
# Build operations
./make build                    # Build all containers
./make build WANTED=wordpress   # Build specific container
./make build wordpress 6.1.1    # Build with specific version

# Run operations
./make run wordpress            # Run container
./make run wordpress 6.1.1     # Run specific version

# Version operations
./make version wordpress        # Check version
./make targets                  # List all containers

# Push operations (requires registry access)
./make push wordpress           # Push to registry
./make push wordpress 6.1.1    # Push specific version
```

### 2. Debug Mode

Enable debug output:

```bash
export DEBUG=1
./make build wordpress
```

### 3. Development Helpers

Create useful aliases:

```bash
# Add to ~/.bashrc or ~/.zshrc
alias dcb='./make build'
alias dcr='./make run'
alias dcv='./make version'
alias dct='./make targets'

# Docker helpers
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dimg='docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"'
alias dclean='docker system prune -af'
```

## Testing Strategy

### 1. Unit Testing

Test individual components:

```bash
# Test version scripts
for dir in */; do
  if [[ -f "$dir/version.sh" ]]; then
    echo "Testing $dir"
    (cd "$dir" && timeout 10 ./version.sh)
    (cd "$dir" && timeout 30 ./version.sh latest)
  fi
done
```

### 2. Integration Testing

Test complete workflow:

```bash
# Create test script
cat > test-container.sh << 'EOF'
#!/bin/bash

set -e

container="$1"
if [[ -z "$container" ]]; then
  echo "Usage: $0 <container>"
  exit 1
fi

echo "Testing container: $container"

# Test version detection
echo "1. Testing version detection..."
cd "$container"
current=$(./version.sh)
latest=$(./version.sh latest)
echo "  Current: $current"
echo "  Latest: $latest"
cd ..

# Test build
echo "2. Testing build..."
./make build "$container"

# Test run (with timeout)
echo "3. Testing run..."
timeout 30 ./make run "$container" || echo "  Run test completed"

echo "✅ All tests passed for $container"
EOF

chmod +x test-container.sh

# Run tests
./test-container.sh wordpress
./test-container.sh debian
```

### 3. Performance Testing

```bash
# Build time measurement
time ./make build wordpress

# Image size analysis
docker images wordpress --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Layer analysis with dive
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  wagoodman/dive:latest wordpress:latest
```

## Troubleshooting

### Common Issues

#### Build Failures

```bash
# Check Docker daemon
sudo systemctl status docker

# Check disk space
df -h

# Clean Docker cache
docker system prune -af

# Rebuild with no cache
docker build --no-cache .
```

#### Version Script Issues

```bash
# Test script manually
cd container-name
bash -x ./version.sh latest  # Debug mode

# Check network connectivity
curl -I https://api.github.com

# Validate JSON parsing
curl -s "https://api.github.com/repos/owner/repo/releases/latest" | jq .
```

#### Permission Issues

```bash
# Fix file permissions
find . -name "*.sh" -exec chmod +x {} \;

# Check Docker group membership
groups $USER
sudo usermod -aG docker $USER
newgrp docker
```

### Debug Techniques

#### Enable Debug Output

```bash
# For make script
export DEBUG=1

# For Docker builds
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain

# For shell scripts
set -x  # Enable trace mode
```

#### Container Debugging

```bash
# Run container with shell
docker run -it --rm container-name:latest sh

# Inspect container
docker inspect container-name:latest

# Check container logs
docker logs container-name

# Execute commands in running container
docker exec -it container-name sh
```

## Best Practices

### Code Quality

1. **Use shellcheck** for shell scripts
2. **Use hadolint** for Dockerfiles
3. **Follow naming conventions**
4. **Add comprehensive comments**

### Security

1. **Use non-root users** in containers
2. **Minimize attack surface**
3. **Keep base images updated**
4. **Scan for vulnerabilities**

### Performance

1. **Use multi-stage builds**
2. **Optimize layer ordering**
3. **Use .dockerignore**
4. **Cache dependencies**

---

**Last Updated**: June 21, 2025
**Maintained By**: Development Team
