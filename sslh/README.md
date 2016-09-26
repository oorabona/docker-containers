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

So you only need to change mentionned environment variables to make it work in your environment.
