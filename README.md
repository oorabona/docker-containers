# Docker Containers Repository 🐳

Automated Docker container management with intelligent upstream monitoring and CI/CD workflows.

## 🌟 Overview

This repository maintains 12 production-ready Docker containers with automated version monitoring, smart builds, and deployment pipelines. Each container includes version detection, health checks, and standardized build processes.

## 🏗️ Architecture

```
docker-containers/
├── .github/
│   ├── workflows/              # GitHub Actions workflows
│   │   ├── upstream-monitor.yaml    # Upstream version monitoring
│   │   ├── auto-build.yaml         # Automated container builds
│   │   └── validate-version-scripts.yaml
│   └── actions/               # Reusable GitHub Actions
├── make                       # Universal build script
├── CHANGELOG.md              # Build history timeline
├── audit-containers.sh       # Container audit tool
├── test-all-containers.sh    # Comprehensive testing
├── fix-version-scripts.sh    # Version script maintenance
└── [containers]/             # Production containers
    ├── ansible/              # Configuration management
    ├── debian/               # Base Debian images
    ├── elasticsearch-conf/   # Elasticsearch configuration
    ├── openvpn/             # VPN server
    ├── sslh/                # SSL/SSH multiplexer
    ├── terraform/           # Infrastructure as code
    ├── wordpress/           # CMS platform
    └── [container-name]/    # Standard structure
        ├── Dockerfile       # Container definition
        ├── version.sh       # Version management script
        ├── docker-compose.yml # Optional compose config
        └── README.md        # Container documentation
```

## 🚀 Key Features

- **Automated Monitoring**: Twice-daily upstream version checks with intelligent PR creation
- **Smart Build System**: Universal make script with multi-architecture support
- **Version Management**: Standardized version.sh scripts with multiple source strategies
- **CI/CD Integration**: GitHub Actions workflows for building, testing, and deployment
- **Security**: Health checks, non-root users, and automated security updates

## 📦 Available Containers

### Infrastructure & DevOps
- **[ansible/](ansible/)** - Configuration management and automation platform
- **[terraform/](terraform/)** - Infrastructure as code with Terraform CLI
- **[openvpn/](openvpn/)** - OpenVPN server for secure networking

### Web Applications & Services  
- **[wordpress/](wordpress/)** - WordPress CMS with PHP optimization
- **[sslh/](sslh/)** - SSL/SSH multiplexer for port sharing

### Database & Storage
- **[postgres/](postgres/)** - PostgreSQL database with optimization
- **[elasticsearch-conf/](elasticsearch-conf/)** - Elasticsearch configuration management

### Development & Utilities
- **[debian/](debian/)** - Minimal Debian base images with version flexibility
- **[php/](php/)** - PHP development environment with Composer
- **[logstash/](logstash/)** - Log processing and forwarding
- **[openresty/](openresty/)** - High-performance web platform (Nginx + Lua)
- **[es-kopf/](es-kopf/)** - Elasticsearch management web interface

## 🚀 Quick Start

### Building Containers

```bash
# Build specific container
./make build wordpress

# Build all containers
./make build

# List available containers
./make targets
```

### Running Containers

```bash
# Run container directly
./make run wordpress

# Using docker-compose
cd wordpress && docker-compose up -d
```

### Version Management

```bash
# Check current version
./make version wordpress

# Get latest upstream version
cd wordpress && ./version.sh latest
```

## 🔧 Automation Workflows

### Upstream Monitor (`upstream-monitor.yaml`)
- **Schedule**: 6 AM/6 PM UTC daily
- **Purpose**: Detects upstream version updates and creates PRs
- **Manual**: `gh workflow run upstream-monitor.yaml --field container=wordpress`

### Auto Build (`auto-build.yaml`)  
- **Triggers**: Push to main, PRs, schedule, manual dispatch
- **Purpose**: Builds and pushes containers when changes detected
- **Features**: Multi-arch builds, registry push, smart detection

### Version Validation (`validate-version-scripts.yaml`)
- **Triggers**: Changes to version.sh files
- **Purpose**: Ensures all version scripts are functional
- **Testing**: `./validate-version-scripts.sh`

## 🛠️ Development

### Prerequisites
- Docker Engine 20.10+
- Docker Compose v2+
- Bash 4.0+

> NB: Also works with Podman.

### Creating New Containers

1. **Create directory structure**:
   ```bash
   mkdir my-app && cd my-app
   ```

2. **Create Dockerfile**: Follow existing patterns with health checks and non-root users

3. **Create version.sh script**:
   ```bash
   #!/bin/bash
   case "${1:-current}" in
       latest) echo "$(get_latest_from_upstream)" ;;
       current|*) echo "1.0.0" ;;
   esac
   ```

4. **Test locally**:
   ```bash
   chmod +x version.sh
   cd .. && ./make build my-app
   ```

### Testing

```bash
# Test all version scripts
./validate-version-scripts.sh

# Test GitHub Actions locally
./test-github-actions.sh

# Build and test specific container
./make build wordpress && ./make run wordpress
```

## � Documentation

- [GitHub Actions Guide](docs/GITHUB_ACTIONS.md) - Workflow and action references
- [Local Development](docs/LOCAL_DEVELOPMENT.md) - Development setup and workflows  
- [Testing Guide](docs/TESTING_GUIDE.md) - Local testing with GitHub Actions
- [Security Policy](SECURITY.md) - Security guidelines and reporting
- [Dashboard](DASHBOARD.md) - Auto-generated container status (updated automatically)

## 🤝 Contributing

1. Fork and create feature branch
2. Follow existing patterns for new containers
3. Test locally with `./test-github-actions.sh`
4. Submit PR with clear description

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/oorabona/docker-containers/issues)
- **Security**: See [SECURITY.md](SECURITY.md)

## 📜 License

MIT License - see [LICENSE](LICENSE) file for details.
