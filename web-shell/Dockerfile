# Web Shell - Secure browser-based terminal
# Built on our Debian base image (locales, user, sudo pre-configured)
# ttyd for web terminal + common DevOps/hosting tools
# https://github.com/tsl0922/ttyd

ARG VERSION=latest
ARG UPSTREAM_VERSION=""
ARG TTYD_VERSION="1.7.7"
ARG DEBIAN_TAG="trixie"

FROM ghcr.io/oorabona/debian:${DEBIAN_TAG}

USER root

ARG TTYD_VERSION
ARG TARGETARCH

# Install common tools for hosting/DevOps use + download ttyd
RUN apt-get update && apt-get install -y --no-install-recommends \
        # Editors
        vim-tiny nano \
        # File management
        tree file less findutils \
        # Network tools
        curl wget dnsutils iputils-ping net-tools \
        # Process management
        htop procps \
        # Data tools
        jq \
        # Version control
        git \
        # Archive tools
        bzip2 xz-utils unzip zip \
        # SSH server (for traditional SSH access)
        openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    # Install ttyd pre-built binary
    && case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ARCH}" \
    && chmod +x /usr/local/bin/ttyd \
    && ttyd --version

# Configure SSH server
RUN sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && mkdir -p /run/sshd

# Password is set at runtime via SHELL_PASSWORD env var (see entrypoint.sh)
# No default password baked into the image for security
ARG SHELL_USER=debian

# Bash prompt and aliases
COPY bashrc /home/${SHELL_USER}/.bashrc
RUN chown ${SHELL_USER}:${SHELL_USER} /home/${SHELL_USER}/.bashrc

# Entrypoint handles ttyd + optional sshd
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ttyd web terminal
EXPOSE 7681
# SSH (non-standard port to avoid conflicts)
EXPOSE 2222

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost:7681/token

ENTRYPOINT ["entrypoint.sh"]
