# Docker Containers Repository 🐳

Automated Docker container management with intelligent upstream monitoring and CI/CD workflows. Built following programming best practices with shared utilities, focused components, and comprehensive testing.

## 🌟 Overview

This repository maintains 10 production-ready Docker containers with automated version monitoring, smart builds, and deployment pipelines. Each container includes version detection, health checks, and standardized build processes using shared utilities and focused scripts following DRY, SOLID, and KISS principles.

## 🏗️ Architecture

```
docker-containers/
├── .github/
│   ├── workflows/              # GitHub Actions workflows
│   │   ├── upstream-monitor.yaml    # Upstream version monitoring
│   │   ├── auto-build.yaml         # Automated container builds
│   │   └── validate-version-scripts.yaml
│   └── actions/               # Reusable GitHub Actions
├── make                       # Universal build coordinator (simplified)
├── scripts/                   # Focused utility scripts (Single Responsibility)
│   ├── build-container.sh     # Container building logic
│   ├── push-container.sh      # Registry push operations  
│   └── check-version.sh       # Version detection utilities
├── helpers/                   # Shared utilities (DRY principle)
│   ├── logging.sh             # Centralized logging functions
│   └── docker-registry        # Registry interaction utilities
├── CHANGELOG.md              # Build history timeline
├── audit-containers.sh       # Container audit tool
├── test-all-containers.sh    # Comprehensive testing
├── validate-version-scripts.sh # Version script validation
└── [containers]/             # Production containers
    ├── ansible/              # Configuration management
    ├── debian/               # Base Debian images
    ├── openresty/            # Web server with Lua
    ├── openvpn/             # VPN server
    ├── php/                 # PHP runtime environment
    ├── postgres/            # Database server
    ├── sslh/                # SSL/SSH multiplexer
    ├── terraform/           # Infrastructure as code
    └── wordpress/           # CMS platform
    └── [container-name]/    # Standard structure
        ├── Dockerfile       # Container definition
        ├── version.sh       # Version management script
        ├── docker-compose.yml # Optional compose config
        └── README.md        # Container documentation
```

## 🎯 Programming Best Practices

This repository follows industry-standard programming principles for maintainable, scalable code:

### **DRY (Don't Repeat Yourself)**
- **Shared Utilities**: `helpers/logging.sh` eliminates ~200 lines of duplicate logging code
- **Centralized Functions**: Single source of truth for common operations
- **Consistent APIs**: Standardized interfaces across all scripts

### **SOLID Principles**
- **Single Responsibility**: Each script in `scripts/` has one focused purpose
- **Decomposed Architecture**: Monolithic make script broken into focused utilities
- **Clear Interfaces**: Well-defined inputs and outputs for all functions

### **KISS (Keep It Simple, Stupid)**
- **Simplified Workflows**: Complex operations broken into understandable steps
- **Minimal Dependencies**: Leveraging shell built-ins and existing tools
- **Clear Documentation**: Straightforward explanations and examples

### **Defensive Programming**
- **Robust Error Handling**: Graceful failure handling with clear error messages
- **Input Validation**: All user inputs validated before processing
- **Comprehensive Testing**: 100% success rate across all validation scripts

## 🚀 Key Features

- **Automated Monitoring**: Twice-daily upstream version checks with intelligent PR creation
- **Smart Build System**: Simplified universal make script with focused utility components
- **Version Management**: Standardized version.sh scripts with multiple source strategies
- **CI/CD Integration**: GitHub Actions workflows for building, testing, and deployment
- **Security**: Health checks, non-root users, and automated security updates
- **Shared Utilities**: DRY principle implementation with centralized logging and helper functions
- **Quality Assurance**: Comprehensive testing with 100% success rate (9/9 containers)

## 📦 Available Containers

### Infrastructure & DevOps
- **[ansible/](ansible/)** - Configuration management and automation platform
- **[terraform/](terraform/)** - Infrastructure as code with Terraform CLI
- **[openvpn/](openvpn/)** - OpenVPN server for secure networking

### Web Applications & Services  
- **[wordpress/](wordpress/)** - WordPress CMS with PHP optimization
- **[sslh/](sslh/)** - SSL/SSH multiplexer for port sharing

### Database & Storage
- **[postgres/](postgres/)** - PostgreSQL database with extensions (variants: base, vector, analytics, timeseries, distributed, full)

### Development & Utilities
- **[debian/](debian/)** - Minimal Debian base images with version flexibility
- **[php/](php/)** - PHP development environment with Composer
- **[jekyll/](jekyll/)** - Jekyll static site generator
- **[openresty/](openresty/)** - High-performance web platform (Nginx + Lua)

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

3. **Create version.sh script** (using centralized pattern):
   ```bash
   #!/bin/bash
   source "$(dirname "$0")/../helpers/docker-registry"
   
   # Function to get latest upstream version
   get_latest_upstream() {
       # Container-specific upstream detection logic
       # Examples:
       # latest-docker-tag library/nginx "^[0-9]+\.[0-9]+\.[0-9]+$"
       # latest-git-tag owner/repo "^v[0-9]+\.[0-9]+\.[0-9]+$"
       # get_pypi_latest_version package-name
   }
   
   # Use standardized version handling
   handle_version_request "$1" "oorabona/my-app" "^[0-9]+\.[0-9]+\.[0-9]+$" "get_latest_upstream"
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
