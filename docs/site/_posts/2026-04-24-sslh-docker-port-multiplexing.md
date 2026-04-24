---
layout: post
title: "Running SSH, HTTPS, and OpenVPN on the Same Port with SSLH in Docker"
description: "A practical guide to protocol multiplexing with sslh — how to serve SSH, HTTPS, and OpenVPN on port 443 using a 2 MB scratch container."
date: 2026-04-24 10:00:00 +0000
tags: [sslh, docker, networking, ssh, security]
---

You're on a hotel Wi-Fi that blocks everything except ports 80 and 443. Your SSH server listens on 22. Your OpenVPN server on 1194. You can't reach either. Sound familiar?

**SSLH** ([yrutschle/sslh](https://github.com/yrutschle/sslh)) is a protocol multiplexer that sits on a single port, inspects the first bytes of each incoming connection, and forwards it to the right backend. SSH, HTTPS, OpenVPN, XMPP, and a dozen other protocols can share port 443 — transparent to the client.

This post walks through running sslh in a minimal `FROM scratch` Docker container: **~2 MB image, no OS, no shell, no attack surface**.

## Why you'd want this

- **Firewall evasion** (legitimate use): hotels, corporate proxies, restrictive ISPs
- **Reduce public port exposure** — one port, three protocols
- **Plausible deniability** — a scanner sees only "HTTPS on 443"
- **Simpler NAT/reverse proxy setup** — one rule instead of three

## The container in 30 seconds

```bash
docker run -d --name sslh \
  -p 443:443 \
  ghcr.io/oorabona/sslh \
  -f \
  -p 0.0.0.0:443 \
  --ssh ssh-backend:22 \
  --tls web-backend:8443 \
  --openvpn vpn-backend:1194
```

That's it. Connections to `:443` are routed by protocol signature:

- `SSH-2.0-...` → `ssh-backend:22`
- TLS ClientHello → `web-backend:8443`
- OpenVPN opcode → `vpn-backend:1194`

## Why *this* image specifically

There are several sslh Docker images on Docker Hub. Here's what's different:

| | Most images | `oorabona/sslh` |
|--|--|--|
| Base | `debian-slim` or `alpine` | `FROM scratch` |
| Size | 30–80 MB | **~2 MB** |
| Shell | bash/sh | none |
| Shared libs | dozens | none (static) |
| Multi-arch | amd64 only | amd64, arm64, arm/v7 |
| CVE surface | whole distro | sslh itself |
| SBOM | — | SPDX + Sigstore attestation |

The binary is statically linked against musl-libc during a multi-stage build, then copied into an empty image. No OS means nothing to patch, nothing to exploit, nothing to maintain.

## Hardened deployment

Run it with the full seccomp/caps lockdown:

```yaml
# docker-compose.yml
services:
  sslh:
    image: ghcr.io/oorabona/sslh:latest
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]  # only if binding <1024
    security_opt:
      - no-new-privileges:true
    ports:
      - "443:443"
    command:
      - -f
      - -p
      - "0.0.0.0:443"
      - --ssh
      - "ssh:22"
      - --tls
      - "web:8443"
    restart: unless-stopped
```

The image ships with three sslh flavors you can pick from:

- **`sslh-ev`** (default) — libev-based, best throughput, recommended
- **`sslh-select`** — classic `select()`, good for few connections
- **`sslh-fork`** — one process per connection, simpler debugging

Switch flavor via `--entrypoint /usr/local/bin/sslh-fork` or `sslh-select`.

## Advanced: config file mode

For complex setups (TLS ALPN sniffing, regex matching, per-protocol log levels), command-line flags get unwieldy. Use a config file:

```ini
# /etc/sslh.cfg
foreground: true;
listen: ( { host: "0.0.0.0"; port: "443"; } );

protocols:
(
  { name: "ssh"; service: "ssh"; host: "ssh-backend"; port: "22"; fork: true; },
  { name: "openvpn"; host: "vpn-backend"; port: "1194"; },
  { name: "tls"; host: "web-backend"; port: "8443"; alpn_protocols: ["h2", "http/1.1"]; },
  { name: "anyprot"; host: "web-backend"; port: "8443"; }
);
```

Mount it read-only:

```bash
docker run -d --name sslh \
  -v /path/to/sslh.cfg:/etc/sslh.cfg:ro \
  -p 443:443 \
  ghcr.io/oorabona/sslh -f -F /etc/sslh.cfg
```

The final `anyprot` entry is a catch-all — anything unrecognized is routed to the web backend, so random port-scanners see a normal HTTPS response.

## Gotchas

- **No environment variables.** `FROM scratch` means no shell to interpolate them. Everything is command-line args or config file.
- **UDP protocols (QUIC, some VPNs)** require the config file — `sslh-fork` doesn't support UDP at all.
- **Transparent proxy mode** needs host networking + extra kernel setup. See [tproxy docs](https://github.com/yrutschle/sslh/blob/master/doc/tproxy.md).
- **Client IP visibility.** Without transparent mode, backends see the sslh container IP. Set up PROXY protocol forwarding or tproxy if you need the real client address.

## Automated updates

This image is rebuilt whenever [yrutschle/sslh](https://github.com/yrutschle/sslh) publishes a new release. No manual `docker pull` schedule needed — just use `:latest` or pin to the version you tested.

The CI pipeline:

1. Daily check on `yrutschle/sslh` GitHub releases
2. Version change detected → auto PR with updated `variants.yaml`
3. Minor/patch auto-merges; major waits for review
4. Build produces multi-arch images + SPDX SBOM + Sigstore attestation
5. Push to both GHCR and Docker Hub

The full build graph, pull counts, and dependency freshness for every flavor live on the [container dashboard](/docker-containers/container/sslh/).

## TL;DR

```bash
docker pull ghcr.io/oorabona/sslh        # 2 MB, multi-arch, static
docker pull oorabona/sslh                # same, on Docker Hub
```

If this saved you some time, [drop a ⭐ on the repo](https://github.com/oorabona/docker-containers) — it's the only way we hear about the 80 000+ monthly Docker Hub pulls.
