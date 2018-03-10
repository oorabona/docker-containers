# SSLH Docker image

This image is based on the work done by [amondit](https://github.com/amondit/sslh).

## What changes ?

- It is now bound to [Bitnami Minideb](https://github.com/bitnami/minideb) base image.
- It is built from sources from [Github](https://github.com/yrutschle/sslh).
- By default, container **COMMAND** is set to `-V` (show version)
- There is a `docker-entrypoint.sh` to help handle with command line arguments

## How to run it ?

The **DEFAULT_CMD** variable (see [docker-entrypoint](docker-entrypoint.sh#L2)) is already set to what should be the basic command line for `sslh`.

> `"-p ${LISTEN_IP}:${LISTEN_PORT} --ssh ${SSH_HOST}:${SSH_PORT} --ssl ${HTTPS_HOST}:${HTTPS_PORT} --openvpn ${OPENVPN_HOST}:${OPENVPN_PORT}"`

You just need to change **COMMAND** to `-f` as stated in `sslh` docs:

> `-f` means **keep process in foreground** which is what Docker expects for the main process.
The container will stop when the process exits.

## Examples

To configure endpoints, you may need to change the following environment variables:
- LISTEN_IP (*default*: **0.0.0.0**)
- LISTEN_PORT (*default*: **443**)
- SSH_HOST (*default*: **localhost**)
- SSH_PORT (*default*: **22**)
- OPENVPN_HOST (*default*: **localhost**)
- OPENVPN_PORT (*default*: **1194**)
- HTTPS_HOST (*default*: **localhost**)
- HTTPS_PORT (*default*: **8443**)

### Using plain Docker CLI

```sh
$ docker run -d -e SSH_HOST=192.168.1.2 -e SSH_PORT=1234 -e OPENVPN_HOST=192.168.2.1 -e HTTPS_HOST=192.168.2.1 -p 0.0.0.0:443:443 oorabona/sslh -f
```

### Using docker-compose

In the following example, we keep the default values for

```yaml
version: '3'
services:
  sslh:
    image: oorabona/sslh
    environment:
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

```
$ docker-compose -f your-compose.yml up -d
```

### Using Rancher

Have a look at my own [Rancher Catalog](https://github.com/oorabona/rancher-catalog/tree/master/templates/sslh).

# Licence

MIT

# TODO

Automating test/publish when sslh source gets updated.
Feedback & PR are of course most welcomed!
