---
layout: post
title: "A Hardened OpenVPN Server in Docker: 15 MB Alpine Image, PKCS11-Ready, Zero-Privilege"
description: "Run OpenVPN in a minimal Alpine container with Easy-RSA, PKCS11 hardware token support, and dropped capabilities except NET_ADMIN. 15 MB compressed."
date: 2026-05-04 10:00:00 +0000
tags: [openvpn, docker, security, alpine, networking, pkcs11]
---

The [sslh post](/docker-containers/2026/04/24/sslh-docker-port-multiplexing.html) showed how to multiplex OpenVPN on port 443 alongside SSH and HTTPS. This post is the companion: the OpenVPN server itself, in a 15 MB hardened container.

Running OpenVPN in Docker is [famously easy to get wrong](https://github.com/kylemanna/docker-openvpn/issues). The default answer is `--privileged` because the daemon needs to create a `tun` device. The better answer is: `cap_drop: ALL` + `cap_add: NET_ADMIN` and let the kernel mediate exactly what OpenVPN can do.

## What's in the image

```bash
docker pull ghcr.io/oorabona/openvpn:v2.7.2-alpine
# 15 MB compressed, multi-arch (amd64 + arm64)
```

- **OpenVPN 2.7.x** (tracked from [yrutschle's OpenVPN fork is unrelated; we follow OpenVPN/openvpn])
- **Easy-RSA 3.2.x** for certificate generation
- **pkcs11-helper** for hardware-token-backed keys (YubiKey, OpenSC, etc.)
- **Alpine base** — static-linking where possible, no shell in the final image layer
- **Non-root** where OpenVPN design permits (see below)

## Why capabilities matter

`--privileged` gives the container effectively all the root privileges of the host: it can mount filesystems, load kernel modules, access any device. OpenVPN needs **exactly one** of those: `CAP_NET_ADMIN`, to open a `tun` device and configure routes.

```yaml
# compose.yml
services:
  openvpn:
    image: ghcr.io/oorabona/openvpn:v2.7.2-alpine
    cap_drop: [ALL]
    cap_add:
      - NET_ADMIN          # create tun0, manipulate routes
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "1194:1194/udp"
    volumes:
      - openvpn-data:/etc/openvpn
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped

volumes:
  openvpn-data:
```

This runs with fewer privileges than `--privileged` by a wide margin. A container compromise doesn't grant the attacker arbitrary kernel actions — just the TUN/network bits OpenVPN itself already has.

## Initial setup

Create a CA and the first client cert:

```bash
# Initialise the server (first run)
docker compose run --rm openvpn ovpn_genconfig -u udp://vpn.example.com
docker compose run --rm openvpn ovpn_initpki

# Start the server
docker compose up -d

# Issue a client cert
docker compose run --rm openvpn easyrsa build-client-full alice nopass

# Export the client .ovpn file
docker compose run --rm openvpn ovpn_getclient alice > alice.ovpn
```

The `.ovpn` bundle embeds the CA, client cert, and key. Hand it to the client, they import it into their OpenVPN client, and they're connected.

## PKCS11: hardware tokens

If you want the client's private key on a YubiKey or PIV card instead of a file, the image ships `pkcs11-helper` and the OpenVPN build is compiled with PKCS11 support:

```ini
# server.conf snippet for PKCS11 server key
pkcs11-providers /usr/lib/pkcs11/opensc-pkcs11.so
pkcs11-id 'your-cert-id-here'
```

For a client using a YubiKey, the `.ovpn` config becomes:

```ini
client
dev tun
proto udp
remote vpn.example.com 1194
pkcs11-providers /usr/lib/pkcs11/opensc-pkcs11.so
pkcs11-id 'pkcs11:id=%01;type=cert'
```

The key never leaves the token. Great for admin VPNs where credential theft would be catastrophic.

## Why Alpine

Three reasons the image is Alpine:

1. **Size.** 15 MB vs 60+ MB for Debian-based alternatives. Fewer layers to cache.
2. **musl-libc** is a smaller surface than glibc. Historically fewer CVEs to track, and the OpenVPN code doesn't exercise the glibc-specific bits.
3. **APK's dependency model** is explicit — no "deb suggests" bloat.

The tradeoff: musl can be slower than glibc on some syscall paths. For OpenVPN (network-IO bound, not CPU-bound), the difference is unmeasurable.

## Health check

```bash
docker inspect openvpn --format='{{.State.Health.Status}}'
```

The image ships a `HEALTHCHECK` that verifies the OpenVPN daemon is running AND the `tun0` interface is up. Simple but catches most failure modes.

## Monitoring

OpenVPN's management interface lets external tools poll connection state:

```ini
# server.conf
management 127.0.0.1 7505
```

Expose nothing to the outside; query from sidecar containers or host scripts:

```bash
# Get connected clients
echo -e "status\nquit" | nc 127.0.0.1 7505
```

Pipe to Prometheus via an exporter, alert on drops. The Vector container ([post](/docker-containers/2026/05/06/vendor-free-observability-vector-postgres.html)) handles this use case well.

## Gotchas

- **`/dev/net/tun` must exist on the host.** On hardened hosts (podman in some configs), you may need `modprobe tun` or a sysctl.
- **UFW / firewalld** on the host can block the VPN's forwarded traffic even though the container is up. Check `iptables-save` if clients connect but can't reach anything.
- **IPv6** — enabling requires `sysctl net.ipv6.conf.all.disable_ipv6=0` on the host and `tun-ipv6` in server.conf. More trouble than it's worth for most deployments.
- **Client cert revocation** — run `easyrsa revoke` and `easyrsa gen-crl`, then `docker compose restart openvpn` so the daemon reloads the CRL.
- **NAT-ed behind a router** — port-forward UDP 1194 and make sure the router doesn't "optimize" UDP flows (some consumer routers break long-lived UDP).

## Comparison

| Image | Size (amd64) | Shell | CAP_ADMIN required |
|---|---|---|---|
| `kylemanna/openvpn` | ~50 MB | yes | yes |
| `linuxserver/openvpn-as` | ~300 MB | yes | yes (it's the full Access Server) |
| `oorabona/openvpn` | **15 MB** | minimal | NET_ADMIN only (not full ADMIN) |

Kylemanna's image is the gold standard of reference material — our image follows the same setup scripts (`ovpn_genconfig`, `ovpn_initpki`, `ovpn_getclient`). The differences are the Alpine base, smaller footprint, PKCS11 support compiled in, and the capability model.

## TL;DR

```bash
# compose up
curl -O https://raw.githubusercontent.com/oorabona/docker-containers/master/openvpn/docker-compose.yml
# edit vpn.example.com, then:
docker compose run --rm openvpn ovpn_genconfig -u udp://vpn.example.com
docker compose run --rm openvpn ovpn_initpki
docker compose up -d
```

Full config reference and client examples at the [container dashboard](/docker-containers/container/openvpn/).

Paired with [sslh](/docker-containers/2026/04/24/sslh-docker-port-multiplexing.html), you get OpenVPN on port 443 alongside SSH and HTTPS on the same IP. Works through almost every hotel Wi-Fi.

[⭐ Star on GitHub](https://github.com/oorabona/docker-containers) if the hardening recipe helped.
