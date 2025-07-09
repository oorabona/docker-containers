# Docker Containers Repository 🐳

A comprehensive, automated Docker container repository with intelligent upstream monitoring, version management, and CI/CD pipelines.

## 🌟 Overview

This repository provides a streamlined approach to maintaining Docker containers with automated upstream version monitoring, intelligent builds, and seamless deployment workflows. Each container is self-contained with its own versioning strategy and build configuration.

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

### 🔄 Automated Upstream Monitoring
- **Twice-daily checks** for upstream version updates
- **Multi-source support**: Git tags, Docker Hub, PyPI, npm, and more
- **Intelligent version comparison** using semantic versioning
- **Automatic PR creation** for version updates

### 🛠️ Smart Build System
- **Universal make script** for consistent operations
- **Multi-architecture builds** (amd64, arm64)
- **Layer caching optimization** for faster builds
- **Parallel build execution** for improved performance

### 📦 Version Management
- **Standardized version.sh scripts** for each container
- **Flexible version detection** strategies
- **Rollback capabilities** for failed updates
- **Version history tracking**

### 🔐 Security & Quality
- **Automated security scanning** (planned)
- **Dependency vulnerability checks**
- **Code quality gates**
- **Secure secret management**

## 🏗️ Current Containers

### Infrastructure & DevOps
- **[ansible/](ansible/)** - Configuration management and automation platform
- **[terraform/](terraform/)** - Infrastructure as code with Terraform CLI
- **[openvpn/](openvpn/)** - OpenVPN server for secure networking

### Web Applications & Services  
- **[wordpress/](wordpress/)** - WordPress CMS with PHP optimization
- **[sslh/](sslh/)** - SSL/SSH multiplexer for port sharing
- **[nginx-rancher-rp/](nginx-rancher-rp/)** - Nginx reverse proxy for Rancher

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

### Prerequisites
- Docker Engine 20.10+
- Docker Compose v2+
- Bash 4.0+
- Git

### Building Containers

```bash
# Build a specific container
./make build wordpress

# Build with specific version
./make build wordpress 6.1.1

# Build all containers
./make build

# List available targets
./make targets
```

### Running Containers

```bash
# Run a container
./make run wordpress

# Run with specific version
./make run wordpress 6.1.1

# Using docker-compose directly
cd wordpress && docker-compose up
```

### Version Management

```bash
# Check latest version
./make version wordpress

# Get current container version
cd wordpress && ./version.sh

# Get latest upstream version
cd wordpress && ./version.sh latest
```

## 🔧 GitHub Actions Workflows

### 1. Upstream Version Monitor (`upstream-monitor.yaml`)

**Trigger**: Schedule (6 AM/6 PM UTC), Manual dispatch

**Purpose**: Monitors upstream sources for version updates and creates PRs

**Features**:
- Configurable container selection
- Debug mode support
- Automatic PR creation with detailed information
- Integration with existing build workflows

**Usage**:
```yaml
# Manual trigger with specific container
workflow_dispatch:
  inputs:
    container: "wordpress"    # Optional: specific container
    create_pr: true          # Create PR for updates
    debug: false            # Enable debug output
```

### 2. Auto Build & Push (`auto-build.yaml`)

**Trigger**: Push to main, PR, Schedule, Workflow dispatch

**Purpose**: Builds and pushes containers when changes are detected

**Features**:
- Smart change detection
- Multi-architecture builds
- Registry push automation
- Build optimization with caching

### 3. Version Script Validation (`validate-version-scripts.yaml`)

**Trigger**: Push, PR affecting version scripts

**Purpose**: Ensures all version.sh scripts are functional and follow standards

## 🛠️ Local Development

### Setting Up Development Environment

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-username/docker-containers.git
   cd docker-containers
   ```

2. **Make the build script executable**:
   ```bash
   chmod +x make
   ```

3. **Verify setup**:
   ```bash
   ./make targets  # List all available containers
   ```

### Creating a New Container

1. **Create container directory**:
   ```bash
   mkdir my-new-app
   cd my-new-app
   ```

2. **Create Dockerfile**:
   ```dockerfile
   FROM alpine:latest
   
   # Install dependencies
   RUN apk add --no-cache curl
   
   # Add application
   COPY app.sh /usr/local/bin/
   RUN chmod +x /usr/local/bin/app.sh
   
   # Set working directory
   WORKDIR /app
   
   # Expose port
   EXPOSE 8080
   
   # Health check
   HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
     CMD curl -f http://localhost:8080/health || exit 1
   
   # Start application
   CMD ["app.sh"]
   ```

3. **Create version.sh script**:
   ```bash
   #!/bin/bash
   
   # Version management for my-new-app
   
   get_latest_version() {
       # Example: Get from GitHub releases
       curl -s "https://api.github.com/repos/owner/repo/releases/latest" | \
         grep '"tag_name":' | \
         sed -E 's/.*"([^"]+)".*/\1/' | \
         sed 's/^v//'
   }
   
   get_current_version() {
       # Return current version (hardcoded or from file)
       echo "1.0.0"
   }
   
   case "${1:-current}" in
       latest)
           get_latest_version
           ;;
       current|*)
           get_current_version
           ;;
   esac
   ```

4. **Make version.sh executable**:
   ```bash
   chmod +x version.sh
   ```

5. **Create docker-compose.yml** (optional):
   ```yaml
   version: '3.8'
   
   services:
     my-new-app:
       build:
         context: .
         args:
           VERSION: ${VERSION:-latest}
       ports:
         - "8080:8080"
       environment:
         - APP_ENV=development
       volumes:
         - ./data:/app/data
       healthcheck:
         test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
         interval: 30s
         timeout: 10s
         retries: 3
   ```

6. **Test the container**:
   ```bash
   # From repository root
   ./make build my-new-app
   ./make run my-new-app
   ```

### Version Script Best Practices

Your `version.sh` script should:

1. **Support two modes**:
   - `./version.sh` or `./version.sh current` - return current version
   - `./version.sh latest` - return latest upstream version

2. **Handle errors gracefully**:
   ```bash
   get_latest_version() {
       local version
       version=$(curl -s --fail "https://api.example.com/version" | jq -r '.version' 2>/dev/null)
       if [[ -n "$version" && "$version" != "null" ]]; then
           echo "$version"
       else
           echo "unknown"
           exit 1
       fi
   }
   ```

3. **Use semantic versioning** when possible
4. **Include timeout for network requests**
5. **Add comments explaining the version source**

### Testing Changes Locally

1. **Test version script**:
   ```bash
   cd my-container
   ./version.sh          # Should return current version
   ./version.sh latest   # Should return latest upstream version
   ```

2. **Test build process**:
   ```bash
   ./make build my-container
   ```

3. **Test with specific version**:
   ```bash
   ./make build my-container 1.2.3
   ```

4. **Run integration tests**:
   ```bash
   ./make run my-container
   # Verify container functionality
   ```

### Debugging

1. **Enable debug mode**:
   ```bash
   export DEBUG=1
   ./make build my-container
   ```

2. **Check container logs**:
   ```bash
   docker logs $(docker ps -l -q)
   ```

3. **Interactive debugging**:
   ```bash
   docker run -it --rm my-container:latest sh
   ```

## 📊 Monitoring and Metrics

### Build Metrics
- Build success rate
- Build duration
- Image size optimization
- Security vulnerability count

### Version Tracking
- Upstream update frequency
- Version lag metrics
- Update success rate
- Rollback frequency

### Container Health
- Runtime performance
- Resource utilization
- Health check status
- Error rates

## 🔒 Security Considerations

### Container Security
- **Non-root user execution** where possible
- **Minimal base images** (Alpine, distroless)
- **Regular security updates**
- **Vulnerability scanning** integration

### CI/CD Security
- **Secrets management** via GitHub Secrets
- **Signed commits** enforcement
- **Branch protection** rules
- **Security scanning** in workflows

### Access Control
- **Principle of least privilege**
- **Role-based permissions**
- **Audit logging**
- **Regular access reviews**

## 🤝 Contributing

### Development Workflow

1. **Fork and clone** the repository
2. **Create a feature branch**: `git checkout -b feature/my-feature`
3. **Make changes** following the established patterns
4. **Test thoroughly** using the make script
5. **Submit a pull request** with detailed description

### Code Standards

- **Shell scripts**: Follow [ShellCheck](https://www.shellcheck.net/) recommendations
- **Dockerfiles**: Follow [Docker best practices](https://docs.docker.com/develop/dev-best-practices/)
- **YAML**: Use consistent indentation (2 spaces)
- **Documentation**: Update README.md for significant changes

### Review Process

1. **Automated checks** must pass
2. **Peer review** required for all changes
3. **Security review** for new containers
4. **Performance impact** assessment

## 📚 Additional Resources

- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Semantic Versioning](https://semver.org/)
- [Security Guidelines](./docs/SECURITY.md)

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/your-username/docker-containers/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-username/docker-containers/discussions)
- **Security**: See [SECURITY.md](./SECURITY.md)

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

**🎯 Project Goals**: Automated, secure, and maintainable Docker container management with zero-touch operations.

**📈 Current Status**: Production-ready with automated monitoring and CI/CD pipelines.

**🔮 Roadmap**: See [TODO.md](TODO.md) for planned features and improvements.
