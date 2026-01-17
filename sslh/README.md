# SSLH Container

A minimal `FROM scratch` SSLH container for protocol multiplexing, allowing multiple services (SSH, HTTPS, OpenVPN) to share a single port. Built with static linking for maximum security and minimal attack surface.

![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/sslh)
![Docker Image Size](https://img.shields.io/docker/image-size/oorabona/sslh)

## Platforms
- **amd64** - x86_64 systems
- **arm64** - ARM 64-bit systems
- **arm/v7** - ARM 32-bit systems

## Features

- **FROM scratch** - Absolute minimal attack surface (no OS, no shell)
- **Static binaries** - Self-contained, no runtime dependencies
- **Multiple flavors** - sslh-fork, sslh-select, sslh-ev included
- **Non-root execution** - Runs as nobody user (uid 65534)
- **Stripped binaries** - Minimal size (~2-3MB total image)

Available SSLH flavors (v2.0+):
- `sslh-fork` - Original SSLH project
- `sslh-select` - Uses select instead of epoll
- `sslh-ev` - Uses libev (default, best performance)

## How to run it?

> **IMPORTANT**: This is a `FROM scratch` image with no shell. Environment variables are NOT supported for configuration. You must provide full command line arguments.

### Basic Usage

```bash
# Check version
docker run --rm oorabona/sslh

# Run with full command line
docker run -d \
  --name sslh \
  -p 443:443 \
  oorabona/sslh \
  -f \
  -p 0.0.0.0:443 \
  --ssh ssh.example.com:22 \
  --tls backend.example.com:8443 \
  --openvpn vpn.example.com:1194
```

**Key arguments:**
- `-f` - **Required**: Keep process in foreground (Docker expects this)
- `-p <ip>:<port>` - Listen address and port
- `--ssh <host>:<port>` - SSH backend
- `--tls <host>:<port>` - TLS/HTTPS backend
- `--openvpn <host>:<port>` - OpenVPN backend

### Using Different Flavors

By default, `sslh-ev` is used. To use a different flavor, override the entrypoint:

```bash
# Use sslh-fork
docker run -d --entrypoint /usr/local/bin/sslh-fork oorabona/sslh -f -p 0.0.0.0:443 ...

# Use sslh-select
docker run -d --entrypoint /usr/local/bin/sslh-select oorabona/sslh -f -p 0.0.0.0:443 ...
```

### Using docker-compose

```yaml
services:
  sslh:
    image: oorabona/sslh
    ports:
      - "443:443"
    command:
      - -f
      - -p
      - "0.0.0.0:443"
      - --ssh
      - "192.168.1.2:22"
      - --tls
      - "192.168.2.1:8443"
      - --openvpn
      - "192.168.2.1:1194"
    restart: unless-stopped
```

### Using a configuration file

For complex configurations, use a config file:

```bash
docker run -d \
  --name sslh \
  -p 443:443 \
  -v /path/to/sslh.cfg:/etc/sslh.cfg:ro \
  oorabona/sslh -f -F /etc/sslh.cfg
```

## Security

### Base Security
- **FROM scratch**: No operating system, no shell, no package manager
- **Static linking**: No shared library vulnerabilities
- **Minimal attack surface**: Only sslh binary and CA certificates
- **Non-root**: Runs as nobody user (uid 65534)

### Runtime Hardening (Recommended)

```bash
# Maximum security runtime configuration
docker run -d \
  --name sslh \
  --read-only \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  -p 443:443 \
  oorabona/sslh -f -p 0.0.0.0:443 --ssh backend:22 --tls backend:8443
```

### Docker Compose Security Template

```yaml
services:
  sslh:
    image: ghcr.io/oorabona/sslh:latest
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
    ports:
      - "443:443"
    command:
      - -f
      - -p
      - "0.0.0.0:443"
      - --ssh
      - "backend:22"
      - --tls
      - "backend:8443"
    restart: unless-stopped
```

## SSLH Configuration Examples

### Configuration file format

```ini
foreground: true;
listen:
(
  { host: "0.0.0.0"; port: "443"; }
);

protocols:
(
  { name: "ssh"; service: "ssh"; host: "localhost"; port: "22"; fork: true; },
  { name: "openvpn"; host: "localhost"; port: "1194"; },
  { name: "xmpp"; host: "localhost"; port: "5222"; },
  { name: "http"; host: "localhost"; port: "80"; },
  { name: "tls"; host: "localhost"; port: "443"; log_level: 0; },
  { name: "anyprot"; host: "localhost"; port: "443"; }
);
```

### Notes

- **UDP**: Use config file (not command line). `sslh-fork` doesn't support UDP.
- **Transparent proxy**: Requires host network configuration. See [SSLH documentation](https://github.com/yrutschle/sslh/blob/master/doc/tproxy.md).

For more examples, see the [SSLH project](https://www.rutschle.net/tech/sslh/README.html).

## Building

```bash
./make build sslh
```

## Licence

MIT
