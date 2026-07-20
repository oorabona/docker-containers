---
layout: post
title: "A Hardened OpenVPN Server in Docker: 15 MB Alpine Image, PKCS11-Ready, Least-Privilege"
description: "Run OpenVPN in a minimal Alpine container with Easy-RSA and PKCS11 hardware-token support, under cap_drop: ALL with NET_ADMIN + SETUID/SETGID; the server worker drops to nobody. 15 MB compressed."
date: 2026-05-04 10:00:00 +0000
updated: 2026-07-20
tags: [openvpn, docker, security, alpine, networking, pkcs11]
---

The [sslh post]({{ '/blog/sslh-docker-port-multiplexing/' | relative_url }}) showed how to multiplex OpenVPN on port 443 alongside SSH and HTTPS. This post is the companion: the OpenVPN server itself, in a 15 MB hardened container.

Running OpenVPN in Docker is [famously easy to get wrong](https://github.com/kylemanna/docker-openvpn/issues). The default answer is `--privileged` because the daemon needs to create a `tun` device. The better answer is: `cap_drop: ALL` and add back only the capabilities it truly needs — and let the kernel mediate exactly what OpenVPN can do.

> **Correction (2026-07-17).** An earlier version of this post recommended
> `cap_drop: ALL` with **`NET_ADMIN` only** and claimed OpenVPN needs "exactly
> one" capability. That is wrong: this image's server drops to the unprivileged
> `nobody`/`nogroup` user, and under `cap_drop: ALL` that drop needs `CAP_SETUID`
> and `CAP_SETGID` too — without them OpenVPN aborts at startup
> (`setgid('nogroup') failed: Operation not permitted`). The correct minimal set
> is **`NET_ADMIN` + `SETUID` + `SETGID`**, and the capability blocks below have
> been fixed. Separately, the `ovpn_genconfig` / `ovpn_initpki` / `ovpn_getclient`
> / `easyrsa` commands in the setup steps are from kylemanna's image and are **not
> present here** — this image uses its own `ovpn` installer driven by
> `AUTO_INSTALL` / `AUTO_START`. For a working, maintained walkthrough use the
> [container README](https://github.com/oorabona/docker-containers/tree/master/openvpn).

## What's in the image

```bash
docker pull ghcr.io/oorabona/openvpn:v2.7.5-alpine
# 15 MB compressed, multi-arch (amd64 + arm64)
```

- **OpenVPN 2.7.x** (tracked from [OpenVPN/openvpn](https://github.com/OpenVPN/openvpn))
- **Easy-RSA 3.2.x** for certificate generation
- **pkcs11-helper** for hardware-token-backed keys (YubiKey, OpenSC, etc.)
- **Alpine base** — static-linking where possible, no shell in the final image layer
- **Non-root** where OpenVPN design permits (see below)

## Why capabilities matter

`--privileged` gives the container effectively all the root privileges of the host: it can mount filesystems, load kernel modules, access any device. OpenVPN needs only a **handful** of those: `CAP_NET_ADMIN` to open a `tun` device and configure routes, plus `CAP_SETUID` and `CAP_SETGID` so it can drop the running server to the unprivileged `nobody`/`nogroup` user after setup (a root euid does not bypass that check under `cap_drop: ALL`).

```yaml
# compose.yml
services:
  openvpn:
    image: ghcr.io/oorabona/openvpn:v2.7.5-alpine
    cap_drop: [ALL]
    cap_add:
      - NET_ADMIN          # create tun0, manipulate routes
      - SETUID             # drop the running server to nobody
      - SETGID             # drop the running server to nogroup
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "1194:1194/udp"
    volumes:
      - openvpn-data:/etc/openvpn
    environment:
      # This sample sets START_EXISTING=y and AUTO_START=y (AUTO_INSTALL stays n);
      # the image itself defaults all three to n, so these values live in the
      # compose file, not the container image. Set AUTO_INSTALL=y (and ENDPOINT)
      # on the first boot to bootstrap; later `docker compose up -d` brings the
      # existing server back up non-interactively.
      - START_EXISTING=${START_EXISTING:-y}
      - AUTO_INSTALL=${AUTO_INSTALL:-n}
      - AUTO_START=${AUTO_START:-y}
      - ENDPOINT=${ENDPOINT:-}
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped

volumes:
  openvpn-data:
```

This runs with fewer privileges than `--privileged` by a wide margin. A container compromise doesn't grant the attacker arbitrary kernel actions — just the TUN/network bits OpenVPN itself already has.

## Initial setup

This image does not use kylemanna's `ovpn_genconfig`/`ovpn_getclient` helpers. It runs a single
`ovpn` installer (from [`oorabona/scripts`](https://github.com/oorabona/scripts/tree/main/openvpn),
baked at a pinned commit — see [`openvpn/Dockerfile`](https://github.com/oorabona/docker-containers/blob/master/openvpn/Dockerfile)
for the exact revision) driven by environment variables.

**Bootstrap the server** on an empty volume — the installer generates the CA and `server.conf`
and starts OpenVPN:

```bash
# AUTO_INSTALL=y generates the PKI + server.conf; AUTO_START=y launches the server;
# START_EXISTING=y makes later restarts bring the existing server back up non-interactively,
# so `restart: unless-stopped` is safe. Set ENDPOINT to your public host so the installer
# does not probe for it.
AUTO_INSTALL=y ENDPOINT=vpn.example.com docker compose up -d
```

**Add a client** through the installer's management menu — a one-shot interactive container
against the same config volume, with `START_EXISTING`/`AUTO_INSTALL` cleared (either would start
the server instead of opening the menu):

```bash
docker compose run --rm -e START_EXISTING= -e AUTO_INSTALL= openvpn
# → choose "1) Add a new user", then enter the client name (e.g. alice)
```

The installer writes the client bundle to `/etc/openvpn/clients/<name>.ovpn` (mode 600,
root-owned) on the persistent `/etc/openvpn` volume, so it survives the one-shot menu container.
Retrieve it from the running server:

```bash
docker compose cp openvpn:/etc/openvpn/clients/alice.ovpn .
```

This `/etc/openvpn/clients` location is the current behavior; images built earlier wrote client
configs to the ephemeral `/root` instead, so pull a current image if `docker compose cp` from
`/etc/openvpn/clients` finds nothing.

The `.ovpn` embeds the CA, client cert, key, and tls-crypt/tls-auth key — but no 2FA material. If
you enabled Google Authenticator at install, the client's OTP enrolment is a separate per-user
artifact under `/etc/openvpn/otp/` (the QR/secret to load into an authenticator app); provision it
to the client out of band. Hand the `.ovpn` to the client, who imports it and connects. Revoke a
client the same way, via the menu's "2) Revoke existing user" option, then restart the server
(`docker compose restart openvpn`) so it reloads the regenerated CRL — revocation only takes
effect after the reload.

The maintained [container README](https://github.com/oorabona/docker-containers/tree/master/openvpn)
carries the current, tested commands.

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

Pipe to Prometheus via an exporter, alert on drops. The Vector container ([post]({{ '/blog/vendor-free-observability-vector-postgres/' | relative_url }})) handles this use case well.

## Gotchas

- **`/dev/net/tun` must exist on the host.** On hardened hosts (podman in some configs), you may need `modprobe tun` or a sysctl.
- **UFW / firewalld** on the host can block the VPN's forwarded traffic even though the container is up. Check `iptables-save` if clients connect but can't reach anything.
- **IPv6** — enabling requires `sysctl net.ipv6.conf.all.disable_ipv6=0` on the host and `tun-ipv6` in server.conf. More trouble than it's worth for most deployments.
- **Client cert revocation** — done through the `ovpn` installer's management menu (re-run the container with a config already present), not a bare `easyrsa` command — `easyrsa` is not on `PATH` in this image. The menu revokes the client and regenerates the CRL; restart the container so the daemon reloads it.
- **NAT-ed behind a router** — port-forward UDP 1194 and make sure the router doesn't "optimize" UDP flows (some consumer routers break long-lived UDP).

## Comparison

| Image | Size (amd64) | Shell | CAP_ADMIN required |
|---|---|---|---|
| `kylemanna/openvpn` | ~50 MB | yes | yes |
| `linuxserver/openvpn-as` | ~300 MB | yes | yes (it's the full Access Server) |
| `oorabona/openvpn` | **15 MB** | minimal | NET_ADMIN + SETUID/SETGID (not full ADMIN) |

Kylemanna's image is the gold standard of reference material, but our image does **not** ship its `ovpn_genconfig` / `ovpn_initpki` / `ovpn_getclient` scripts — it uses its own env-driven `ovpn` installer (`AUTO_INSTALL` / `AUTO_START`). The other differences are the Alpine base, smaller footprint, PKCS11 support compiled in, and the capability model.

## TL;DR

```bash
# grab the reference compose (already uses cap_drop: ALL + NET_ADMIN/SETUID/SETGID)
curl -O https://raw.githubusercontent.com/oorabona/docker-containers/master/openvpn/docker-compose.yml
# first run: AUTO_INSTALL=y generates the PKI + server.conf, AUTO_START=y starts it
AUTO_INSTALL=y docker compose up -d
```

Full config reference and client examples at the [container dashboard](/docker-containers/container/openvpn/).

Paired with [sslh]({{ '/blog/sslh-docker-port-multiplexing/' | relative_url }}), you get OpenVPN on port 443 alongside SSH and HTTPS on the same IP. Works through almost every hotel Wi-Fi.

[⭐ Star on GitHub](https://github.com/oorabona/docker-containers) if the hardening recipe helped.
