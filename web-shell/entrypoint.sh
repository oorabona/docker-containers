#!/bin/bash
set -e

SHELL_USER="${SHELL_USER:-debian}"
TTYD_PORT="${TTYD_PORT:-7681}"
ENABLE_SSH="${ENABLE_SSH:-false}"

# Update password if provided via environment
if [[ -n "${SHELL_PASSWORD:-}" ]]; then
    echo "${SHELL_USER}:${SHELL_PASSWORD}" | chpasswd
fi

# Import SSH public key if provided
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    mkdir -p "/home/${SHELL_USER}/.ssh"
    echo "$SSH_PUBLIC_KEY" > "/home/${SHELL_USER}/.ssh/authorized_keys"
    chmod 700 "/home/${SHELL_USER}/.ssh"
    chmod 600 "/home/${SHELL_USER}/.ssh/authorized_keys"
    chown -R "${SHELL_USER}:${SHELL_USER}" "/home/${SHELL_USER}/.ssh"
fi

# Start SSH daemon if enabled
if [[ "$ENABLE_SSH" == "true" ]]; then
    /usr/sbin/sshd
    echo "SSH server started on port 2222"
fi

# Build ttyd options
TTYD_OPTS=""

# Basic auth if credentials provided (format: user:password)
if [[ -n "${TTYD_CREDENTIAL:-}" ]]; then
    TTYD_OPTS="$TTYD_OPTS -c ${TTYD_CREDENTIAL}"
fi

# TLS if cert/key provided
if [[ -f "${TTYD_SSL_CERT:-}" && -f "${TTYD_SSL_KEY:-}" ]]; then
    TTYD_OPTS="$TTYD_OPTS --ssl --ssl-cert ${TTYD_SSL_CERT} --ssl-key ${TTYD_SSL_KEY}"
fi

# Auth header for reverse proxy integration
if [[ -n "${TTYD_AUTH_HEADER:-}" ]]; then
    TTYD_OPTS="$TTYD_OPTS -H ${TTYD_AUTH_HEADER}"
fi

# Execute ttyd as the shell user's login shell
# shellcheck disable=SC2086
exec ttyd \
    --port "$TTYD_PORT" \
    --writable \
    $TTYD_OPTS \
    su - "$SHELL_USER"
