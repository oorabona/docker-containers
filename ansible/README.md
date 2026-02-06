# Ansible

Production-ready Ansible automation container built from source with Python virtual environment isolation and automatic dependency monitoring. Runs as non-root user with multi-mode entrypoint support.

[![Docker Hub](https://img.shields.io/docker/v/oorabona/ansible?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/ansible)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fansible-blue)](https://ghcr.io/oorabona/ansible)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

## Quick Start

```bash
# Pull from GitHub Container Registry
docker pull ghcr.io/oorabona/ansible:latest

# Or from Docker Hub
docker pull oorabona/ansible:latest

# Run a playbook
docker run --rm \
  -v ./playbooks:/playbooks:ro \
  -v ./inventory:/inventory:ro \
  -v ~/.ssh:/home/ansible/.ssh:ro \
  ghcr.io/oorabona/ansible playbook /playbooks/site.yml -i /inventory/hosts

# Check version
docker run --rm ghcr.io/oorabona/ansible ansible --version
```

## Features

### Core Capabilities
- **Python venv isolation**: All Python packages installed in `/opt/ansible-venv` for clean separation
- **Multi-stage build**: Build dependencies removed from final image for minimal size
- **Non-root execution**: Runs as `ansible` user for security (with sudo access if needed)
- **Auto-reload**: `inotifywait` monitors `requirements.txt` and `requirements.yml` for changes
- **Multi-mode entrypoint**: Supports playbook execution, vault operations, script running, or direct command execution

### Security Features
- Non-root by default (user `ansible` with UID 1000)
- Build dependencies stripped from runtime image
- Ubuntu-based with regular security updates
- Support for read-only filesystem and capability dropping

### Development Features
- Automatic Galaxy collection/role installation from `requirements.yml`
- Automatic pip package installation from `requirements.txt`
- File watching for hot-reload during development
- Addon script support for custom initialization
- Optional wait-before-exit for interactive debugging

## Entrypoint Modes

The container supports multiple execution modes via the entrypoint:

### 1. Playbook Mode
Run an Ansible playbook:
```bash
docker run --rm \
  -v ./playbooks:/playbooks:ro \
  ghcr.io/oorabona/ansible playbook /playbooks/site.yml -i /inventory/hosts
```

### 2. Vault Mode
Interact with Ansible Vault:
```bash
docker run --rm \
  -v ./secrets:/secrets \
  ghcr.io/oorabona/ansible vault encrypt /secrets/password.yml
```

### 3. Run-Script Mode
Execute a shell script:
```bash
docker run --rm \
  -v ./scripts:/scripts:ro \
  ghcr.io/oorabona/ansible run-script /scripts/setup.sh
```

### 4. Default Mode
Execute any command directly:
```bash
docker run --rm ghcr.io/oorabona/ansible ansible-galaxy collection list
docker run --rm ghcr.io/oorabona/ansible ansible-inventory --list
```

## Build Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `VERSION` | Ansible version to install | `latest` |
| `UPSTREAM_VERSION` | Raw version for pip (without suffix) | Uses `VERSION` if not set |
| `OS_VERSION` | Ubuntu base image version | `latest` |
| `PYASN1_VERSION` | pyasn1 package version | `0.6.2` |
| `PARAMIKO_VERSION` | Paramiko SSH library version | `4.0.0` |
| `CFFI_VERSION` | CFFI package version | `2.0.0` |
| `CRYPTOGRAPHY_VERSION` | Cryptography library version | `46.0.4` |
| `PYCRYPTODOME_VERSION` | PyCryptodome package version | `3.23.0` |
| `PYNACL_VERSION` | PyNaCl package version | `1.6.2` |

Example build with specific versions:
```bash
docker build \
  --build-arg VERSION=2.16.1 \
  --build-arg OS_VERSION=24.04 \
  --build-arg CRYPTOGRAPHY_VERSION=46.0.4 \
  -t ansible:2.16.1 .
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ADDONSCRIPT` | Path to custom initialization script | `/default-addon.sh` |
| `WAIT_BEFORE_EXIT` | Wait for keypress before container exits | (unset) |
| `VIRTUAL_ENV` | Python virtual environment path | `/opt/ansible-venv` |
| `PATH` | Updated to include venv binaries | `/opt/ansible-venv/bin:$PATH` |

### ADDONSCRIPT
The `ADDONSCRIPT` environment variable points to a script that runs before the main command. Use it for custom initialization:

```yaml
services:
  ansible:
    image: ghcr.io/oorabona/ansible:latest
    environment:
      ADDONSCRIPT: /scripts/init-aws-credentials.sh
    volumes:
      - ./scripts:/scripts:ro
```

Set to empty string to skip addon script execution:
```bash
docker run --rm -e ADDONSCRIPT="" ghcr.io/oorabona/ansible ansible --version
```

### WAIT_BEFORE_EXIT
Useful for debugging or interactive sessions. Container will wait for Enter key before exiting:

```bash
docker run --rm -it \
  -e WAIT_BEFORE_EXIT=1 \
  ghcr.io/oorabona/ansible ansible-playbook /playbooks/debug.yml
```

## Volumes

| Path | Purpose | Recommended Mount |
|------|---------|-------------------|
| `/home/ansible/playbook` | Working directory | Read-only for playbooks |
| `/home/ansible/.ansible` | Ansible collections and plugins | Persistent volume |
| `/home/ansible/.ssh` | SSH keys for remote connections | Read-only, mode 600 |
| `/etc/ansible` | Ansible configuration | Read-only override |

### Docker Compose Example

```yaml
services:
  ansible:
    image: ghcr.io/oorabona/ansible:latest
    volumes:
      - ./playbooks:/playbooks:ro
      - ./inventory:/inventory:ro
      - ~/.ssh:/home/ansible/.ssh:ro
      - ansible_collections:/home/ansible/.ansible
    working_dir: /playbooks
    command: playbook site.yml -i /inventory/hosts

volumes:
  ansible_collections:
```

### Hot-Reload with Requirements

The container automatically watches for changes to dependency files:

```yaml
services:
  ansible:
    image: ghcr.io/oorabona/ansible:latest
    volumes:
      - ./playbooks:/playbooks:ro
      - ./requirements.yml:/home/ansible/playbook/requirements.yml:ro
      - ./requirements.txt:/home/ansible/playbook/requirements.txt:ro
      - ansible_collections:/home/ansible/.ansible
    command: playbook /playbooks/site.yml

volumes:
  ansible_collections:
```

When `requirements.yml` or `requirements.txt` changes, the container automatically installs updates.

## Security

### Base Security
- **Non-root by default**: Runs as `ansible` user (UID 1000, GID 1000)
- **Multi-stage build**: Build dependencies removed from final image
- **Ubuntu-based**: Regular security updates from Canonical
- **Virtual environment**: Python packages isolated from system packages

### Runtime Hardening

```yaml
services:
  ansible:
    image: ghcr.io/oorabona/ansible:latest
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./playbooks:/playbooks:ro
      - ./inventory:/inventory:ro
      - ~/.ssh:/home/ansible/.ssh:ro
```

### SSH Key Security
- Mount SSH keys as read-only (`:ro`)
- Ensure proper permissions on host (mode 600 for private keys)
- Use SSH agent forwarding when possible
- Never store SSH private keys in container images

```bash
# Set proper permissions before mounting
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub

# Run with SSH agent forwarding (if supported by Docker setup)
docker run --rm \
  -v $SSH_AUTH_SOCK:/ssh-agent \
  -e SSH_AUTH_SOCK=/ssh-agent \
  -v ./playbooks:/playbooks:ro \
  ghcr.io/oorabona/ansible playbook /playbooks/site.yml
```

### Secrets Management

Never hardcode secrets in playbooks. Use Ansible Vault or external secret management:

```bash
# Encrypt sensitive variables
docker run --rm -it \
  -v ./vars:/vars \
  ghcr.io/oorabona/ansible vault encrypt /vars/secrets.yml

# Run playbook with vault password
docker run --rm \
  -v ./playbooks:/playbooks:ro \
  -v ./vars:/vars:ro \
  -e ANSIBLE_VAULT_PASSWORD_FILE=/vars/.vault_pass \
  ghcr.io/oorabona/ansible playbook /playbooks/site.yml
```

## Dependencies

All Python cryptography and SSH dependencies are pinned and monitored for updates via PyPI:

| Dependency | Version | Type | Purpose |
|------------|---------|------|---------|
| pyasn1 | 0.6.2 | PyPI | ASN.1 types and codecs |
| Paramiko | 4.0.0 | PyPI | SSH protocol implementation |
| cffi | 2.0.0 | PyPI | C Foreign Function Interface |
| cryptography | 46.0.4 | PyPI | Cryptographic recipes and primitives |
| pycryptodome | 3.23.0 | PyPI | Cryptographic library (replaces deprecated pycrypto) |
| PyNaCl | 1.6.2 | PyPI | Python bindings to libsodium |

### Dependency Monitoring

All dependencies are automatically monitored via the upstream monitoring workflow. When new versions are released on PyPI:
1. Automated check detects new version
2. Pull request created with version bump
3. CI validates the build
4. Merge triggers automatic container rebuild

### Cryptography Stack

The container uses modern cryptographic libraries:
- **pycryptodome** replaces the deprecated `pycrypto` package
- **PyNaCl** provides libsodium bindings for modern cryptography
- **cryptography** provides comprehensive cryptographic recipes
- All packages compiled during build stage, only runtime files included in final image

## Architecture

Supported platforms:
- **amd64** (x86_64)
- **arm64** (aarch64)

Built from source due to installation issues with pip on ARM platforms. Multi-stage build ensures minimal final image size.

### Build Process

1. **Builder stage**: Installs build dependencies (gcc, rustc, cargo), compiles Python packages in virtual environment
2. **Runtime stage**: Copies only the virtual environment, installs runtime dependencies (Python, OpenSSH client, inotify-tools)
3. **Cleanup**: Build dependencies and temporary files removed

### Image Layers

```
ubuntu:{OS_VERSION}
├── Runtime packages (python3, openssh-client, inotify-tools, etc.)
├── Python venv (/opt/ansible-venv)
│   ├── ansible=={VERSION}
│   ├── cryptography=={VERSION}
│   ├── paramiko=={VERSION}
│   └── ... (all dependencies)
├── User setup (ansible user + sudo access)
└── Entrypoint scripts
```

## Links

- [Docker Hub](https://hub.docker.com/r/oorabona/ansible)
- [GitHub Container Registry](https://ghcr.io/oorabona/ansible)
- [Source Repository](https://github.com/oorabona/docker-containers/tree/master/ansible)
- [Ansible Documentation](https://docs.ansible.com/)
- [Ansible Galaxy](https://galaxy.ansible.com/)
- [GitHub Actions Workflows](https://github.com/oorabona/docker-containers/actions)
