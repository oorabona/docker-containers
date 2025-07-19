---
layout: page
title: Documentation
permalink: /docs/
---

# 📚 Documentation

Complete guides and references for the Docker Containers automation system.

## 🚀 Quick Start

### Building Containers Locally
```bash
# Build a specific container
./make build postgres

# Build with specific version
./make build postgres 17.5-alpine

# Check container version
./make version postgres --bare
```

### Available Commands
- `./make build <container> [version]` - Build container
- `./make push <container> [version]` - Push to registries  
- `./make run <container> [version]` - Run container locally
- `./make version <container> [--bare]` - Get version information

## 📋 Container Reference

### Available Containers
{% for container in site.data.containers %}
- **{{ container.name }}**: {{ container.description }}
{% endfor %}

## 🔄 Automation Workflows

### Upstream Monitor
- **Schedule**: Twice daily (6 AM/6 PM UTC)
- **Purpose**: Detect upstream version changes
- **Output**: Creates PRs for updates

### Auto Build & Push
- **Triggers**: Code changes, version updates, manual dispatch
- **Features**: Multi-platform builds, security scanning, retry logic
- **Registries**: GitHub Container Registry + Docker Hub

### Dashboard Updates
- **Purpose**: Maintain live documentation
- **Integration**: GitHub Pages deployment
- **Content**: Container status, versions, build statistics

## 🛡️ Security & Quality

### Version Scripts
All containers include `version.sh` scripts that:
- Detect upstream versions automatically
- Support both `current` and `latest` modes
- Include proper error handling and timeouts
- Use standardized helper functions

### Build Process
- **Multi-platform**: amd64 + arm64 support
- **Security scanning**: Trivy vulnerability detection
- **Registry verification**: Prevents duplicate builds
- **Retry logic**: Handles transient failures

### Branch Protection
- All changes flow through pull requests
- Auto-merge for minor updates (with validation)
- Manual review required for major updates
- Complete audit trail for compliance

## 📊 Monitoring & Analytics

The [Dashboard](/dashboard/) provides real-time information about:
- Container build status and versions
- Registry statistics and download counts
- Workflow execution history
- Version comparison (upstream vs published)

## 🔧 Development

### Adding New Containers
1. Create directory with `Dockerfile`
2. Add `version.sh` script for version detection
3. Optional: Add `docker-compose.yml` for local testing
4. Test with `./make build <container>`

### Version Script Patterns
```bash
#!/bin/bash
source "$(dirname "$0")/../helpers/docker-registry"

get_latest_upstream() {
    # Your upstream detection logic
    latest-docker-tag library/postgres "^[0-9]+\.[0-9]+"
}

handle_version_request "$1" "yourname/container" "^[0-9]+\.[0-9]+" "get_latest_upstream"
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Add your container with proper version detection
4. Test locally with the make script
5. Submit a pull request

## 📝 Additional Resources

- [GitHub Actions Workflows]({{ site.github.repository_url }}/tree/master/.github/workflows)
- [Helper Functions]({{ site.github.repository_url }}/tree/master/helpers)
- [Testing Guide]({{ site.github.repository_url }}/blob/master/docs/TESTING_GUIDE.md)
- [Container Examples]({{ site.github.repository_url }}/tree/master)

---

*Last updated: {{ site.time | date: "%Y-%m-%d %H:%M:%S UTC" }}*
