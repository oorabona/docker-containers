# 🔐 OpenVPN Docker Container built from sources with advanced security features

![Docker Image Version (latest semver)](https://img.shields.io/docker/v/oorabona/openvpn?sort=semver)
![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/openvpn)
![Docker Stars](https://img.shields.io/docker/stars/oorabona/openvpn)
[![GHCR](https://img.shields.io/badge/GHCR-oorabona%2Fopenvpn-blue)](https://ghcr.io/oorabona/openvpn)

This is a simple `Alpine` based container with `OpenVPN` built from sources.

## Platforms

- `amd64` ![Docker Image Size AMD64](https://img.shields.io/docker/image-size/oorabona/openvpn/latest?arch=amd64)
- `arm64` ![Docker Image Size ARM64](https://img.shields.io/docker/image-size/oorabona/openvpn/latest?arch=arm64)

## Features

- 🔐 Built from sources
- Dependant library `pkcs11-helper` built from sources
- Embed `Google Authenticator` support

## Verify this image

Every build ships a Sigstore-signed SBOM and a full Trivy scan — verify them yourself, no login required:

```bash
gh attestation verify oci://ghcr.io/oorabona/openvpn:latest --owner oorabona
```

Full walkthrough (SBOM payload, Trivy findings, multi-arch manifest inspection, upstream dependency tracking) → <https://oorabona.github.io/docker-containers/verify-images/>

## Usage

### Docker

```bash
docker run -d --name openvpn \
    -p 1194:1194/udp \
    -v openvpn-data:/etc/openvpn \
    --cap-drop=ALL \
    --cap-add=NET_ADMIN \
    --cap-add=SETUID \
    --cap-add=SETGID \
    --security-opt no-new-privileges \
    --device=/dev/net/tun \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.forwarding=1 \
    -e AUTO_INSTALL=y \
    -e AUTO_START=y \
    oorabona/openvpn
```

> **First-run storage under `cap_drop: ALL`.** The example uses a named volume
> (`openvpn-data`) because `AUTO_INSTALL` generates the PKI and `server.conf`
> into `/etc/openvpn` on first start, and `cap_drop: ALL` removes the
> `DAC_OVERRIDE`/`FOWNER`/`CHOWN` capabilities that let root bypass filesystem
> permissions. A named volume is created root-owned by the daemon, so that
> generation always succeeds. If you bind-mount a host directory instead, make
> sure it is writable by the container's root (uid 0) — otherwise first-run
> generation fails.

### Docker Compose

```yaml
version: '3.7'

services:
  openvpn:
    image: oorabona/openvpn
    container_name: openvpn
    # Bootstrap-and-run (see "Lifecycle" below): AUTO_INSTALL=y generates the PKI
    # + server.conf into the empty named volume, AUTO_START=y launches the
    # server. Do NOT combine AUTO_INSTALL=y with restart: unless-stopped — the
    # installer re-runs setup on every restart. See #912.
    environment:
      - AUTO_INSTALL=y
      - AUTO_START=y
    cap_add:
      - NET_ADMIN
      - SETUID
      - SETGID
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    devices:
        - /dev/net/tun
    sysctls:
        - net.ipv6.conf.all.disable_ipv6=0
        - net.ipv6.conf.all.forwarding=1
        - net.ipv4.ip_forward=1
        - net.ipv4.conf.all.forwarding=1
    ports:
      - 1194:1194/udp
    volumes:
      - openvpn_config:/etc/openvpn

volumes:
  openvpn_config:
```

### Lifecycle (important)

This image's entrypoint (the `ovpn` installer) is **bootstrap-and-run**, not an
unattended daemon. On an empty volume, `AUTO_INSTALL=y` + `AUTO_START=y`
generates the config and starts the server. But once a config exists it has no
clean restart path: `AUTO_INSTALL=y` **re-runs setup** (can overwrite your
PKI/config), while leaving it unset opens an **interactive management menu**
instead of starting. So do not run a `restart: unless-stopped` service with a
persisted `AUTO_INSTALL=y`, and do not expect a plain `docker compose up -d`
after bootstrap to start the server. Bootstrap once, then manage/run the server
via the installer's documented commands (see below). This limitation is tracked
in [#912](https://github.com/oorabona/docker-containers/issues/912).

## Configuration

### OpenVPN

The container is configured to use the `server.conf` file located in `/etc/openvpn` as default configuration file.
This file is generated from the script `setup.sh` located in `/usr/local/bin` and is based on the following environment variables:

- APPROVE_INSTALL
- IPV4_SUPPORT
- IPV6_SUPPORT
- PORT_CHOICE
- PROTOCOL_CHOICE
- DNS
- COMPRESSION_ENABLED
- CUSTOMIZE_ENC
- CLIENT
- PASS
- CONTINUE
- CLIENT_TO_CLIENT
- BLOCK_OUTSIDE_DNS
- OTP
- EASYRSA_CRL_DAYS
- SUBNET_IPv4
- SUBNET_IPv6
- SUBNET_MASKv4
- SUBNET_MASKv6
- ENDPOIN

For details about the meaning of each variable, please refer to the [documentation](https://github.com/oorabona/scripts/tree/main/openvpn).

Two variables control the container's first-run lifecycle:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_INSTALL` | `n` | `y` runs a **non-interactive** install (generates the PKI + `server.conf`) when no config exists. Left unset with a config already present, the entrypoint opens an interactive management menu instead of starting the server. |
| `AUTO_START` | `n` | `y` starts the OpenVPN server after install (required for the server to actually run on this Alpine image). |

### Google Authenticator

The container is configured to use the `google-authenticator` library to generate the OTP code.
This library is based on the `pkcs11-helper` library which is built from sources.
The generated QR code is stored in the container on a per user basis under the `/etc/openvpn/otp` directory.
The QR code can be retrieved using the following command:

```bash
docker exec -it openvpn cat /etc/openvpn/otp/username.png
```

More information can be found on the [wiki](https://github.com/oorabona/scripts/wiki/OpenVPN-OTP).

## Build Arguments

The following build arguments can be passed to customize the container build:

| Argument | Default | Description |
|----------|---------|-------------|
| `VERSION` | `latest` | OpenVPN version to build |
| `UPSTREAM_VERSION` | (empty) | Fallback upstream version if `VERSION` is not specified |
| `OS_VERSION` | `latest` | Alpine Linux version tag |
| `PKCS11_HELPER_VERSION` | `1.31.0` | pkcs11-helper library version |
| `EASYRSA_VERSION` | `3.2.2` | EasyRSA version for certificate management |
| `NPROC` | `1` | Number of parallel processes for compilation |

## Build options

OpenVPN is built from sources using the following options:

- `--enable-iproute2` option to use the `ip` command instead of `ifconfig`
- `--enable-pkcs11` option to enable the `pkcs11-helper` library and support of PKCS#11 tokens (e.g. Yubikey)
- `--enable-plugin-auth-pam` option to enable the `pam` authentication plugin (e.g. Google Authenticator uses this)
- `--enable-async-push` option to allow asynchronous push of configuration options to the client (and not wait for a remote authentification request to be completed)
- `--enable-plugin-down-root` option to allow the `down-root` plugin to be used (e.g. to drop privileges after the connection is established). Although this option is enabled, the `down-root` plugin is not used by default.
- `--enable-selinux` option to enable the `selinux` support
- `--disable-systemd` option to disable the `systemd` support
- `--disable-debug` option to make the binary smaller
- `--disable-lzo` and `--disable-lz4` options to disable the `lzo` and `lz4` compression support (prone to side-channel attacks)
- `--enable-comp-stub` option to disable all compression altogether (still allow limited interoperability with compression-enabled peers)

## Security

### SELinux

The container is configured to run with the `spc_t` SELinux context.
This context is configured to allow the container to access the following resources:

- `/etc/openvpn` directory
- `/etc/openvpn/otp` directory
- `/etc/openvpn/otp/*` files

### Capabilities

Run with `cap_drop: ALL` and only these capabilities added back:

- `NET_ADMIN` — create the tun device and configure routes/firewall rules
- `SETUID` / `SETGID` — let openvpn drop to `nobody`/`nogroup` after setup

`NET_RAW` is **not** needed — openvpn's UDP transport uses ordinary sockets,
not raw ones. These caps cover the default port (1194). If you configure
openvpn to bind an **internal** port below 1024, add `NET_BIND_SERVICE` as well
(the initial bind happens as root before the drop, and `cap_drop: ALL` removes
the privileged-port capability). Mapping a privileged **host** port to 1194
(`-p 443:1194/udp`) needs nothing extra.

### Privileges

openvpn **starts** as root — creating the tun device, routes, and firewall
rules genuinely requires it — then drops to the unprivileged `nobody`
user/`nogroup` for the lifetime of the tunnel, **provided the running
`server.conf` specifies `user nobody` / `group nogroup`** (with `persist-tun`
/ `persist-key` so the already-open tun survives the drop). The image's own
`AUTO_INSTALL` generates such a config; if you mount your own `server.conf`,
add those directives yourself — without them openvpn keeps running as root.

The `SETUID`/`SETGID` capabilities are what let that drop complete under
`cap_drop: ALL`. They aren't optional for a `user`/`group` config: openvpn
treats a failed privilege drop as **fatal**, so without these caps the
container fails to start rather than silently running as root.

This drops the OpenVPN **server worker** to `nobody`; it does not make the whole
container rootless. The entrypoint wrapper that adds and removes the iptables
NAT rules around the tunnel stays alive as root for the server's lifetime, and
OTP/PAM authentication (when enabled) uses a root helper. So the profile removes
`NET_RAW` and all other capabilities, runs under `no-new-privileges`, and drops
the server worker to `nobody` — a meaningful reduction, not a fully rootless
container.

The setuid/setgid capability requirement was verified directly under
`cap_drop: ALL` (`setuid` to `nobody` fails with only `NET_ADMIN` and succeeds
once `SETUID`/`SETGID` are added back). Exercising openvpn's full end-to-end
drop needs a live tunnel with a real tun device, which the image's current CI
e2e does not stand up — that coverage is tracked in
[#910](https://github.com/oorabona/docker-containers/issues/910). Treat the
reduced-capability profile as verified at the capability level, not yet
exercised end-to-end by CI.

### Security options

The default hardened profile (the `run`/Compose examples above) sets only
`no-new-privileges`.

On an **SELinux-enforcing host** the container additionally needs host-policy-
specific run options — relaxing seccomp/AppArmor and setting the container's
SELinux label so it can manage the tun device and iptables under the `spc_t`
context described above. Those settings depend on your host's policy, are **not**
part of the image's default profile, and are not general hardening
recommendations — consult your platform's SELinux + container documentation for
the exact values.

## Dependencies

The following third-party dependencies are pinned and monitored for updates:

| Dependency | Version | Source | Monitoring |
|-----------|---------|--------|-----------|
| pkcs11-helper | 1.31.0 | GitHub Release (opensc/pkcs11-helper) | Enabled |
| EasyRSA | 3.2.2 | GitHub Release (OpenVPN/easy-rsa) | Enabled |

## References

- [OpenVPN](https://openvpn.net/)
- [pkcs11-helper](https://github.com/OpenSC/pkcs11-helper)

## License

[MIT](LICENSE)

## Other projects

- [Dockovpn](https://github.com/dockovpn/dockovpn)
- [Kyle Manna](https://github.com/kylemanna/docker-openvpn)
