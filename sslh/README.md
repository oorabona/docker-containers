# SSLH Docker image

This image is based on the work done by [amondit](https://github.com/amondit/sslh).

## What changes ?

- It is now bound to the latest version of ubuntu.
- It is built from sources from [Github](https://github.com/yrutschle/sslh).
- By default, **COMMAND** is set to `-V` (show version)
- There is a `docker-entrypoint.sh` to help handle with command line arguments

Means that if you want to run it, you just need to change **COMMAND** to `-f` as
the **DEFAULT_CMD** is already set to what should be the basic command line for `sslh`.

> `-f` means **keep process in foreground** which is what Docker expects for the main process.
The container will stop when the process exits.

> **DEFAULT_CMD** set to `"-p ${LISTEN_IP}:${LISTEN_PORT} --ssh ${SSH_HOST}:${SSH_PORT} --ssl ${HTTPS_HOST}:${HTTPS_PORT} --openvpn ${OPENVPN_HOST}:${OPENVPN_PORT}"`

So you only need to change above mentionned environment variables to make it work in your environment.

## Examples

### Using plain Docker CLI

```sh
$ docker run -d -e SSH_HOST=192.168.1.2 -e SSH_PORT=1234 -e OPENVPN_HOST=192.168.2.1 -e HTTPS_HOST=192.168.2.1 -p 0.0.0.0:443:443 oorabona/sslh -f
```

### Using docker-compose

```yaml
version: '2'
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
    restart: until-stopped
```

And to launch it:

```sh
$ docker-compose -f your-compose.yml up -d
```

### Using Rancher

Have a look at my own [Rancher Catalog](https://github.com/oorabona/rancher-catalog/tree/master/templates/sslh).

# Licence

MIT

# TODO

Automating test/publish when sslh source gets updated.
Feedback & PR are of course most welcomed!
