# Debian Base Container

A minimal Debian container with customizable version support. This container provides a clean Debian base image with version flexibility for various use cases.

## Features

- **Version Flexibility**: Supports multiple Debian versions via build args
- **Minimal Footprint**: Uses Debian's slim variants for reduced image size
- **Automated Builds**: Integrated with upstream monitoring for version updates
- **Clean Base**: Perfect starting point for custom applications

## Usage

### With Docker Compose

```yaml
version: '3.8'
services:
  debian-app:
    build:
      context: .
      args:
        VERSION: bookworm-slim
    volumes:
      - ./app:/app
    working_dir: /app
    command: bash
```

### Direct Docker Run

```bash
# Use default version
docker run -it --rm debian-base bash

# Specify version
docker build --build-arg VERSION=bullseye-slim -t debian-base .
docker run -it --rm debian-base bash
```

## Build Arguments

- `VERSION` - Debian version tag (default: defined in version.sh)
  - `bookworm-slim` - Debian 12 (current stable)
  - `bullseye-slim` - Debian 11 (oldstable)
  - `bookworm` - Full Debian 12 image
  - `bullseye` - Full Debian 11 image

## Common Use Cases

1. **Application Base**: Starting point for custom applications
2. **Development Environment**: Clean environment for testing
3. **CI/CD Base**: Consistent build environment
4. **Package Testing**: Testing packages across Debian versions

## Building

```bash
cd debian
docker-compose build

# Or with specific version
docker build --build-arg VERSION=bookworm-slim -t debian-base .
```

## Version Management

This container uses automated version detection for the latest Debian releases:

```bash
./version.sh          # Current version
./version.sh latest    # Latest available version
```

The version script automatically detects the latest stable Debian release and updates accordingly.

## Security

### Base Security
- Uses official Debian base images
- Minimal attack surface with slim variants
- Regular security updates through automated rebuilds
- No additional packages installed by default

### User Security
- **No hardcoded passwords**: User created without password (login via `docker exec` or SSH keys)
- **Non-root by default**: Container runs as `debian` user
- **Sudo access**: Passwordless sudo for container operations

### Runtime Hardening (Recommended)

```bash
# Secure runtime configuration
docker run -it --rm \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  debian-base bash
```

### Docker Compose Security Template

```yaml
services:
  debian:
    image: ghcr.io/oorabona/debian:latest
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
```

## Advanced Migration Tool - export.sh

The `export.sh` script is a powerful migration utility for creating custom Debian containers that replicate your host system's configuration. This is particularly useful for:

### Use Cases

1. **System Migration**: Create a containerized version of your current Debian/Ubuntu system
2. **Development Environment Replication**: Share exact development environments with team members
3. **Legacy System Containerization**: Convert bare-metal installations to containers
4. **Custom Base Images**: Create specialized base images with your exact package set

### Features

- **Package Migration**: Copy installed packages from host to container
- **Configuration Migration**: Transfer /etc and /home directories
- **Flexible Options**: Granular control over what gets migrated
- **Multiple Package Managers**: Support for apt, apt-get, and aptitude
- **Selective Exclusions**: Exclude specific directories or packages

### Usage

```bash
# Basic usage - create container with same packages
./export.sh --packages=install --version=bookworm

# Advanced usage - full system migration
./export.sh \
  --version=bookworm-slim \
  --locales="en_US fr_FR" \
  --packages=install \
  --package-manager=apt \
  --copy-etc \
  --copy-etc-exclude="secrets,private" \
  --copy-home \
  --copy-home-exclude=".cache,.tmp" \
  --omit-linux-kernel

# Help and options
./export.sh --help
```

### Options

- `--version=<version>` - Target Debian version (e.g., bookworm, bullseye)
- `--locales=<locales>` - Locales to install (e.g., "en_US fr_FR")
- `--packages=[none|copy|install]` - Package management strategy
  - `none` - Don't manage packages
  - `copy` - Copy package list only
  - `install` - Copy and install packages
- `--package-manager=[apt|apt-get|aptitude]` - Choose package manager
- `--copy-etc` - Copy /etc directory configuration
- `--copy-etc-exclude=<dirs>` - Exclude directories from /etc (comma-separated)
- `--copy-home` - Copy /home directory
- `--copy-home-exclude=<dirs>` - Exclude directories from /home
- `--omit-linux-kernel` - Skip Linux kernel packages

### Output

The script creates a `debian-<version>.tar` file containing your migrated system that can be imported as a Docker image:

```bash
# Import the exported container
docker import debian-bookworm.tar my-custom-debian:latest

# Run your migrated system
docker run -it my-custom-debian:latest bash
```

### Security Considerations

- Review what gets copied before running
- Exclude sensitive directories with `--copy-etc-exclude` and `--copy-home-exclude`
- Consider using package-only migration for production environments
- Test exported containers in isolated environments first
