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
# identical. Rather than accept that as a proxy for "healthy", authenticate
# for real: entrypoint.sh's own TTYD_CREDENTIAL/TTYD_AUTH_HEADER are
# available here too, so pass them through and require an actual 200.
# --noproxy '*' stops an http_proxy/ALL_PROXY env var from routing the
# probe through a proxy that never reaches ttyd at all. Port and TLS mode
# follow the same TTYD_PORT/TTYD_SSL_CERT/TTYD_SSL_KEY entrypoint.sh reads,
# so a non-default deployment doesn't probe the wrong port or scheme; -k
# skips cert validation since ttyd's own TLS setup is typically
# self-signed and this is a liveness check, not a trust check.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD port="${TTYD_PORT:-7681}"; proto=http; [ -f "${TTYD_SSL_CERT:-}" ] && [ -f "${TTYD_SSL_KEY:-}" ] && proto=https; set --; [ -n "${TTYD_CREDENTIAL:-}" ] && set -- -u "$TTYD_CREDENTIAL"; [ -n "${TTYD_AUTH_HEADER:-}" ] && set -- -H "${TTYD_AUTH_HEADER}:healthcheck"; curl -fsk --noproxy '*' "$@" -o /dev/null "$proto://localhost:$port/token"

ENTRYPOINT ["entrypoint.sh"]
