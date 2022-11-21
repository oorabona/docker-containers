# 🔐 OpenVPN Docker Container built from sources with advanced security features

![Docker Image Version (latest semver)](https://img.shields.io/docker/v/oorabona/openvpn?sort=semver)
![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/openvpn)
![Docker Stars](https://img.shields.io/docker/stars/oorabona/openvpn)

This is a simple `Alpine` based container with `OpenVPN` built from sources.

## Platforms

- `amd64`

![Docker Image Size AMD64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/openvpn?arch=amd64&sort=semver)

- `arm64`

![Docker Image Size ARM64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/openvpn?arch=arm64&sort=semver)

- `arm/v7`

![Docker Image Size ARM/v7 (latest semver)](https://img.shields.io/docker/image-size/oorabona/openvpn?arch=arm&sort=semver)

## Features

- 🔐 Built from sources
- Dependant library `pkcs11-helper` built from sources
- Embed `Google Authenticator` support

## Usage

### Docker

```bash
docker run -d --name openvpn \
    -p 1194:1194/udp \
    -v /path/to/config:/etc/openvpn \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --device=/dev/net/tun \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.forwarding=1 \
    -e AUTO_INSTALL=y \
    -e AUTO_START=y \
    oorabona/openvpn
```

### Docker Compose

```yaml
version: '3.7'

services:
  openvpn:
    image: oorabona/openvpn
    container_name: openvpn
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
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
      - /path/to/config:/etc/openvpn
```

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

### Google Authenticator

The container is configured to use the `google-authenticator` library to generate the OTP code.
This library is based on the `pkcs11-helper` library which is built from sources.
The generated QR code is stored in the container on a per user basis under the `/etc/openvpn/otp` directory.
The QR code can be retrieved using the following command:

```bash
docker exec -it openvpn cat /etc/openvpn/otp/username.png
```

More information can be found on the [wiki](https://github.com/oorabona/scripts/wiki/OpenVPN-OTP).

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

The container is configured to run with the following capabilities:

- `NET_ADMIN`
- `NET_RAW`

### Privileges

The container is configured to run as `root` user.
No effort has been (yet) made to run the container as a non-root user.

### Security options

The container is configured to run with the following security options:

- `no-new-privileges`
- `seccomp=unconfined`
- `apparmor=unconfined`

### Security labels

The container is configured to run with the following security labels:

- `label=disable`
- `label=type:spc_t`

## References

- [OpenVPN](https://openvpn.net/)
- [pkcs11-helper](https://github.com/OpenSC/pkcs11-helper)

## License

[MIT](LICENSE)

## Other projects

- [Dockovpn](https://github.com/dockovpn/dockovpn)
- [Kyle Manna](https://github.com/kylemanna/docker-openvpn)
