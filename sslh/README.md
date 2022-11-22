# SSLH Docker image

![Docker Image Version (latest semver)](https://img.shields.io/docker/v/oorabona/sslh?sort=semver)
![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/sslh)
![Docker Stars](https://img.shields.io/docker/stars/oorabona/sslh)

## Platforms

- `amd64`

![Docker Image Size AMD64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/sslh?arch=amd64&sort=semver)

- `arm64`

![Docker Image Size ARM64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/sslh?arch=arm64&sort=semver)

- `arm/v7`

![Docker Image Size ARM/v7 (latest semver)](https://img.shields.io/docker/image-size/oorabona/sslh?arch=arm&sort=semver)

## About

This is a simple `Alpine` based container with [SSLH](https://github.com/yrutschle/sslh) built from sources.

## Features

- It uses [Alpine](https://hub.docker.com/_/alpine) base image.

> For its lightweight size and security.

- It is built from sources from [Github](https://github.com/yrutschle/sslh).

> For its latest features and security fixes it is not restricted in version number.

- You can use a different flavor of `SSLH` by setting the `USE_SSLH_FLAVOR` environment variable.

> As of v2.0+ the `SSLH` project has been split into multiple flavors:
>
> - `sslh-fork`: the original `SSLH` project
> - `sslh-select`: the original `SSLH` project with `select` instead of `epoll`
> - `sslh-ev`: the original `SSLH` project with `libev`

- All binaries are stripped.

> For its smaller size, less memory usage and security.

- It runs as `nobody` user.

> For its security, it is not needed to have root privileges inside the container since publishing ports is done by the host.

- By default, container **COMMAND** is set to `-V` (show version)

> But if you want to specify your own command, you can do it too (see below).

- There is a `docker-entrypoint.sh` to help handle command line arguments

##  How to run it ?

The **DEFAULT_CMD** variable (see [docker-entrypoint](docker-entrypoint.sh#L2)) is already set to what should be the basic command line for `sslh`.

```bash
-p ${LISTEN_IP}:${LISTEN_PORT} --ssh ${SSH_HOST}:${SSH_PORT} --ssl ${HTTPS_HOST}:${HTTPS_PORT} --openvpn ${OPENVPN_HOST}:${OPENVPN_PORT}"`
```

It takes the following environment variables:

- `LISTEN_IP`: the IP address to listen on (default: `0.0.0.0`)
- `LISTEN_PORT`: the port to listen on (default: `443`)
- `SSH_HOST`: the SSH host to forward to (default: `localhost`)
- `SSH_PORT`: the SSH port to forward to (default: `22`)
- `HTTPS_HOST`: the HTTPS host to forward to (default: `localhost`)
- `HTTPS_PORT`: the HTTPS port to forward to (default: `8443`)
- `OPENVPN_HOST`: the OpenVPN host to forward to (default: `localhost`)
- `OPENVPN_PORT`: the OpenVPN port to forward to (default: `1194`)

You can also set the `USE_SSLH_FLAVOR` environment variable to use a different flavor of `SSLH` (see [Features](#features)).

> Note that by default **COMMAND** is set to `-V` (show version). It is done to prevent errors and misbehave (since this software usually runs on your network edges or close). You need to change **COMMAND** to `-f` as stated in `sslh` docs:
>
> `-f` means **keep process in foreground** which is what Docker expects for the main process.
The container will stop when the process exits.
>
> Being foreground means that `sslh` will log to `stdout` and `stderr` which is what Docker expects. And if the process exits (for any reason) the container will stop.

With these environment variables, you can run the container like this:

```bash
docker run -d \
  --name sslh \
  -p 443:443 \
  -e LISTEN_IP=1.2.3.4 \
  -e LISTEN_PORT=443 \
  -e SSH_HOST=ssh.example.com \
  -e SSH_PORT=22 \
  -e HTTPS_HOST=backend.example.com \
  -e HTTPS_PORT=8443 \
  -e OPENVPN_HOST=vpn.example.com \
  -e OPENVPN_PORT=1194 \
  oorabona/sslh -f
```

This will run the `sslh-ev` version by default (version 2.0+ onwards) and will listen on `1.2.3.4:443` and forward `SSH`, `HTTPS` and `OpenVPN` traffic to their respective hosts and ports.

### Using docker-compose

In the following example, we keep the default values for

```yaml
version: '3'
services:
  sslh:
    image: oorabona/sslh
    environment:
      LISTEN_IP: 0.0.0.0
      LISTEN_PORT: 8443
      SSH_HOST: 192.168.1.2
      SSH_PORT: 1234
      OPENVPN_HOST: 192.168.2.1
      HTTPS_HOST: 192.168.2.1
    ports:
      - 0.0.0.0:443:443
    command:
      - -f
    restart: unless-stopped
```

And to launch it:

```sh
docker-compose -f your-compose.yml up -d
```

### Using a configuration file

You can also use a configuration file instead of environment variables.

In this case, you need to mount the configuration file in the container and set the `SSLH_CONFIG_FILE` environment variable to the path of the configuration file.

```bash
docker run -d \
  --name sslh \
  -p 443:443 \
  -v /path/to/sslh.cfg:/etc/sslh.cfg \
  oorabona/sslh -f -F /etc/sslh.cfg
```

## SSLH examples

For more examples and general documentation about `SSLH`, please refer to the [SSLH project](https://www.rutschle.net/tech/sslh/README.html) and [configuration](https://www.rutschle.net/tech/sslh/doc/config).

### Configuration file

Here is an example of a configuration file:

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

### A note about UDP

The previous configuration example is for `TCP` traffic only. If you want to use `UDP` traffic, you need to proceed as follows:

- Do not use the command line arguments, instead use the `sslh.cfg` file (see [SSLH examples](#sslh-examples) for more details)
- You cannot use `sslh-fork` flavor since it does not support `UDP` (see [this note](https://www.rutschle.net/tech/sslh/doc/config#udp))

### A note about transparent proxy

Transparent proxying is not supported by `SSLH` (see [this note](https://www.rutschle.net/tech/sslh/doc/config#transparent-proxy)) but requires some effort to implement it.

However to achieve this, you must do some network black magic to make it work. A good reference is [this article](https://github.com/yrutschle/sslh/blob/master/doc/tproxy.md).

## Licence

MIT
