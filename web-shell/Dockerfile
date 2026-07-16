# Web Shell - Secure browser-based terminal
# Multi-distribution support (debian, alpine, ubuntu, rocky)
# ttyd for web terminal + common DevOps/hosting tools
# https://github.com/tsl0922/ttyd
#
# NOTE: This is a template — markers are expanded by generate-dockerfile.sh.
# Package lists are in config.yaml — do not add packages here.

ARG REMOTE_CR=ghcr.io/oorabona
ARG VERSION
ARG UPSTREAM_VERSION
ARG TTYD_VERSION
# @@BASE_IMAGE@@

USER root

ARG TTYD_VERSION
ARG TARGETARCH

# Validate required build args
RUN : "${TTYD_VERSION:?required}"

# @@INSTALL_PACKAGES@@

# Install ttyd pre-built binary (static binary, works on all distros)
RUN case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ARCH}" \
    && chmod +x /usr/local/bin/ttyd \
    && ttyd --version

# @@SSH_SETUP@@

# Password is set at runtime via SHELL_PASSWORD env var (see entrypoint.sh)
# No default password baked into the image for security
# @@USER_SETUP@@

# Propagate SHELL_USER from build-time ARG to runtime ENV
# (entrypoint.sh reads this to configure password, SSH, and ttyd)
ENV SHELL_USER=${SHELL_USER}

# Entrypoint handles ttyd + optional sshd
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

LABEL org.opencontainers.image.title="Web Shell" \
      org.opencontainers.image.description="Secure browser-based terminal with ttyd and SSH" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT"

# ttyd web terminal
EXPOSE 7681
# SSH (non-standard port to avoid conflicts)
EXPOSE 2222

# /token is the documented readiness endpoint (README, test.sh) — it proves
# ttyd can actually issue a token, not just that something answers on the
# port. ttyd's auth check (Basic credential or proxy header) applies to
# every path including /token, so an unauthenticated probe against a
# configured deployment gets a 401/407 that proves nothing about /token
# itself — a broken token handler behind a *working* auth gate would look
# identical. entrypoint.sh's own TTYD_CREDENTIAL/TTYD_AUTH_HEADER are
# available here too, so this authenticates for real — but TTYD_CREDENTIAL
# goes to curl via -K (a config file on stdin), never as a -u argv value:
# this image's whole purpose is giving a user a shell, and healthcheck
# argv is readable by anyone in the same container via `ps`/`/proc`, so a
# real Basic-auth secret can't go on the command line. TTYD_AUTH_HEADER's
# value here is a fixed, non-secret placeholder (ttyd only checks the
# header's presence, not its content), so it's fine as a normal -H arg.
# --noproxy '*' stops an http_proxy/ALL_PROXY env var from routing the
# probe through a proxy that never reaches ttyd at all. Port and TLS mode
# follow the same TTYD_PORT/TTYD_SSL_CERT/TTYD_SSL_KEY entrypoint.sh
# reads; -k skips cert validation since ttyd's own TLS setup is typically
# self-signed and this is a liveness check, not a trust check. -S prints
# curl's own connection/TLS error text on a genuine transport failure —
# safe, it never includes the credential — so a broken port/TLS/proxy
# config is still diagnosable from `docker inspect`'s health log. A plain
# status check isn't enough either: curl without -f treats any completed
# response as success, so status and body are both checked explicitly —
# exactly 200, and the body actually contains "token" (same content
# test.sh already checks) — with the body itself never printed, only
# matched, so the live credential can't leak into that log via output.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD port="${TTYD_PORT:-7681}"; proto=http; [ -f "${TTYD_SSL_CERT:-}" ] && [ -f "${TTYD_SSL_KEY:-}" ] && proto=https; set --; [ -n "${TTYD_AUTH_HEADER:-}" ] && set -- "$@" -H "${TTYD_AUTH_HEADER}:healthcheck"; curl_cfg=""; [ -n "${TTYD_CREDENTIAL:-}" ] && curl_cfg="user = \"${TTYD_CREDENTIAL}\""; out="$(printf '%s\n' "$curl_cfg" | curl -sSk --noproxy '*' -K - "$@" -w 'HTTPSTATUS:%{http_code}' "$proto://localhost:$port/token")"; case "$out" in *'"token"'*'HTTPSTATUS:200') exit 0 ;; *) exit 1 ;; esac

ENTRYPOINT ["entrypoint.sh"]
