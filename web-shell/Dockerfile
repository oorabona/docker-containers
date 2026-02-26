# Web Shell - Secure browser-based terminal
# Multi-distribution support (debian, alpine, ubuntu, rocky)
# ttyd for web terminal + common DevOps/hosting tools
# https://github.com/tsl0922/ttyd
#
# NOTE: This is a template — markers are expanded by generate-dockerfile.sh.
# Package lists are in config.yaml — do not add packages here.

ARG VERSION=latest
ARG UPSTREAM_VERSION=""
ARG TTYD_VERSION="1.7.7"
# @@BASE_IMAGE@@

USER root

ARG TTYD_VERSION
ARG TARGETARCH

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

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost:7681/token

ENTRYPOINT ["entrypoint.sh"]
