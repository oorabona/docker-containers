# Web Shell

[![Docker Hub](https://img.shields.io/docker/v/oorabona/web-shell?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/oorabona/web-shell)
[![GHCR](https://img.shields.io/badge/GHCR-web--shell-blue?logo=github)](https://github.com/oorabona/docker-containers/pkgs/container/web-shell)
[![Build](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml/badge.svg)](https://github.com/oorabona/docker-containers/actions/workflows/auto-build.yaml)

Secure browser-based terminal built on our [Debian](../debian/) base image with [ttyd](https://github.com/tsl0922/ttyd) for web terminal access. Includes common DevOps and hosting tools, optional SSH server, and flexible authentication options.

## Quick Start

```bash
# Pull the image
docker pull ghcr.io/oorabona/web-shell:latest

# Run with default settings (web terminal on port 7681)
docker run -d --name web-shell -p 7681:7681 ghcr.io/oorabona/web-shell:latest

# Open in browser
# http://localhost:7681

# Run with password and SSH enabled
docker run -d --name web-shell \
  -p 7681:7681 -p 2222:2222 \
  -e SHELL_PASSWORD=mysecretpass \
  -e ENABLE_SSH=true \
  ghcr.io/oorabona/web-shell:latest
```

## Build

```bash
# Build with latest upstream ttyd version
./make build web-shell

# Build with specific ttyd version
./make build web-shell 1.7.7
```

### Build Args

| Arg | Default | Description |
|-----|---------|-------------|
| `VERSION` | `latest` | Full version tag (set by build system) |
| `TTYD_VERSION` | `1.7.7` | ttyd release version |
| `DEBIAN_TAG` | `trixie` | Debian base image tag |
| `SHELL_USER` | `debian` | Default shell user (build-time) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SHELL_USER` | `debian` | User for terminal sessions |
| `SHELL_PASSWORD` | _(unchanged)_ | Override user password at runtime |
| `TTYD_PORT` | `7681` | Web terminal listen port |
| `ENABLE_SSH` | `false` | Start SSH daemon on port 2222 |
| `SSH_PUBLIC_KEY` | _(none)_ | Import SSH authorized key |
| `TTYD_CREDENTIAL` | _(none)_ | Basic auth in `user:password` format |
| `TTYD_SSL_CERT` | _(none)_ | Path to TLS certificate (enables HTTPS) |
| `TTYD_SSL_KEY` | _(none)_ | Path to TLS private key |
| `TTYD_AUTH_HEADER` | _(none)_ | Auth header for reverse proxy integration |

## Ports

| Port | Service |
|------|---------|
| 7681 | ttyd web terminal (WebSocket-based) |
| 2222 | SSH server (when `ENABLE_SSH=true`) |

## Included Tools

| Category | Tools |
|----------|-------|
| Editors | vim-tiny, nano |
| File management | tree, file, less, findutils |
| Network | curl, wget, dnsutils, iputils-ping, net-tools |
| Process management | htop, procps |
| Data tools | jq |
| Version control | git |
| Archives | bzip2, xz-utils, unzip, zip |
| Remote access | openssh-server |

## Authentication

### No Authentication (default)

Anyone with network access can use the terminal. Suitable for local development or behind a trusted reverse proxy.

### Basic Auth (ttyd built-in)

```bash
docker run -d -p 7681:7681 \
  -e TTYD_CREDENTIAL="admin:secretpass" \
  ghcr.io/oorabona/web-shell:latest
```

### TLS Encryption

```bash
docker run -d -p 7681:7681 \
  -v /path/to/cert.pem:/certs/cert.pem:ro \
  -v /path/to/key.pem:/certs/key.pem:ro \
  -e TTYD_SSL_CERT=/certs/cert.pem \
  -e TTYD_SSL_KEY=/certs/key.pem \
  ghcr.io/oorabona/web-shell:latest
```

### Reverse Proxy Auth Header

For integration with authentication proxies (OAuth2 Proxy, Authelia, etc.):

```bash
docker run -d -p 7681:7681 \
  -e TTYD_AUTH_HEADER="X-Forwarded-User" \
  ghcr.io/oorabona/web-shell:latest
```

### SSH Access

```bash
docker run -d -p 7681:7681 -p 2222:2222 \
  -e ENABLE_SSH=true \
  -e SSH_PUBLIC_KEY="ssh-ed25519 AAAA... user@host" \
  ghcr.io/oorabona/web-shell:latest

# Connect via SSH
ssh -p 2222 debian@localhost
```

## Health Check

Built-in health check via ttyd token endpoint:

```
GET http://localhost:7681/token → {"token": "..."}
```

## Hosting Use Case

Web Shell is designed as a building block for web hosting platforms, providing browser-based terminal access to container environments. Combined with other containers from this project:

```
┌──────────────────────────────────────────────────────────┐
│  Client Browser                                          │
│  ┌───────────┐  ┌────────────┐  ┌──────────────────┐    │
│  │ Web App   │  │ phpMyAdmin │  │ Web Terminal      │    │
│  │ :80/:443  │  │ :8080      │  │ :7681 (ttyd)     │    │
│  └─────┬─────┘  └─────┬──────┘  └──────┬───────────┘    │
└────────┼───────────────┼────────────────┼────────────────┘
         │               │                │
┌────────┼───────────────┼────────────────┼────────────────┐
│  ┌─────▼─────┐  ┌──────▼─────┐  ┌──────▼───────────┐    │
│  │ OpenResty │  │ PHP-FPM    │  │ Web Shell         │    │
│  │ (proxy)   │  │ WordPress  │  │ (tools + shell)   │    │
│  └───────────┘  └────────────┘  └──────────────────┘    │
│  ┌───────────┐  ┌────────────┐                           │
│  │ PostgreSQL│  │ Vector     │                           │
│  │ (database)│  │ (logs)     │                           │
│  └───────────┘  └────────────┘                           │
│  Docker Host                                             │
└──────────────────────────────────────────────────────────┘
```

## Security Considerations

- Runs as root for `chpasswd` and `sshd`, but ttyd spawns shells as the configured `SHELL_USER`
- Default password is `changeme` — always override with `SHELL_PASSWORD`
- SSH listens on port 2222 (non-standard) with root login disabled
- For production: use `TTYD_CREDENTIAL` or place behind an auth reverse proxy
- Mount TLS certificates for encrypted connections
- The `--writable` flag enables terminal input — remove for read-only sessions

## Dependencies

| Component | Version | Source | Monitoring |
|-----------|---------|--------|------------|
| ttyd | 1.7.7 | [GitHub](https://github.com/tsl0922/ttyd) | upstream-monitor |
| Debian (base) | trixie | [ghcr.io/oorabona/debian](../debian/) | upstream |

## Links

- [ttyd GitHub](https://github.com/tsl0922/ttyd)
- [ttyd Wiki](https://github.com/tsl0922/ttyd/wiki)
- [WebSocket Terminal Protocol](https://github.com/nicm/tmux/wiki)
- [Debian Base Image](../debian/)
