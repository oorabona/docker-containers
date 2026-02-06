# Build stage
ARG OS_VERSION=latest
FROM ubuntu:${OS_VERSION} as builder

ARG VERSION=latest
ARG UPSTREAM_VERSION=""
ARG PYASN1_VERSION=0.6.2
ARG PARAMIKO_VERSION=4.0.0
ARG CFFI_VERSION=2.0.0
ARG CRYPTOGRAPHY_VERSION=46.0.4
ARG PYCRYPTODOME_VERSION=3.23.0
ARG PYNACL_VERSION=1.6.2
ENV VIRTUAL_ENV=/opt/ansible-venv

# Use UPSTREAM_VERSION for pip install if provided (raw version without suffix), fallback to VERSION
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv build-essential \
        python3-dev libffi-dev rustc cargo libsodium-dev libssl-dev \
    && python3 -m venv $VIRTUAL_ENV \
    && . $VIRTUAL_ENV/bin/activate \
    && pip install --upgrade pip setuptools wheel \
    && SODIUM_INSTALL=system pip install pynacl==${PYNACL_VERSION} \
    && INSTALL_VERSION="${UPSTREAM_VERSION:-$VERSION}" \
    && pip install pyasn1==${PYASN1_VERSION} paramiko==${PARAMIKO_VERSION} cffi==${CFFI_VERSION} cryptography==${CRYPTOGRAPHY_VERSION} pycryptodome==${PYCRYPTODOME_VERSION} ansible==${INSTALL_VERSION}

# Runtime stage
ARG OS_VERSION=latest
FROM ubuntu:${OS_VERSION}

ARG VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    VIRTUAL_ENV=/opt/ansible-venv \
    PATH="/opt/ansible-venv/bin:$PATH"

# Copy virtual environment from builder
COPY --from=builder $VIRTUAL_ENV $VIRTUAL_ENV

# Install only runtime dependencies
RUN apt-get update -y && apt-get -y dist-upgrade \
    && apt-get install -y --no-install-recommends \
        python3 inotify-tools dnsutils sudo curl vim \
        openssh-client openssl boxes libsodium23 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/ansible \
    && echo "localhost ansible_python_interpreter=$VIRTUAL_ENV/bin/python3" > /etc/ansible/hosts

# Create ansible user
RUN useradd -ms /bin/bash -G sudo ansible \
    && echo "ansible ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && chown -R ansible:ansible $VIRTUAL_ENV

COPY *.sh /
RUN chmod +x /*.sh

USER ansible
WORKDIR /home/ansible/playbook

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ansible --version || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["ansible", "--version"]