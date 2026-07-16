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
# port. -f can't be used as-is: ttyd's auth check (Basic credential or proxy
# header, via TTYD_CREDENTIAL/TTYD_AUTH_HEADER) applies to every path
# including /token, so a configured deployment legitimately gets 401/407
# there, and -f would fail the probe on that expected response. Instead,
# read the status explicitly and accept only the codes that mean "ttyd is
# up and behaving correctly" (200 unauthenticated, 401/407 correctly
# enforcing configured auth) — genuine failures (5xx, anything else) still
# fail the check. -o /dev/null keeps the token body itself out of health
# logs regardless of which code comes back. --noproxy '*' stops an
# http_proxy/ALL_PROXY env var from turning a proxy 407 into a false
# "healthy" without ever reaching ttyd. Port and TLS mode follow the same
# TTYD_PORT/TTYD_SSL_CERT/TTYD_SSL_KEY entrypoint.sh already reads, so a
# non-default deployment doesn't probe the wrong port or scheme; -k skips
# cert validation since ttyd's own TLS setup is typically self-signed and
# this is a liveness check, not a trust check.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD port="${TTYD_PORT:-7681}"; proto=http; [ -f "${TTYD_SSL_CERT:-}" ] && [ -f "${TTYD_SSL_KEY:-}" ] && proto=https; code="$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' "$proto://localhost:$port/token")"; case "$code" in 200|401|407) exit 0 ;; *) exit 1 ;; esac

ENTRYPOINT ["entrypoint.sh"]
