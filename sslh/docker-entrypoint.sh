#!/bin/sh
DEFAULT_CMD="-p ${LISTEN_IP}:${LISTEN_PORT} --ssh ${SSH_HOST}:${SSH_PORT} --tls ${HTTPS_HOST}:${HTTPS_PORT} --openvpn ${OPENVPN_HOST}:${OPENVPN_PORT}"

set -e

# Add sslh as command if needed
if [ "${1:0:1}" = '-' ]; then
	set -- ${USE_SSLH_FLAVOR} ${DEFAULT_CMD} "$@"
fi

echo "Running $@" 1>&2

exec "$@"
