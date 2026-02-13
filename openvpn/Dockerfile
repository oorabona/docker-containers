# Smallest base image
ARG OS_VERSION=latest
ARG BASE_IMAGE=alpine
FROM ${BASE_IMAGE}:${OS_VERSION}

ARG VERSION=latest
ARG UPSTREAM_VERSION=""
ARG PKCS11_HELPER_VERSION
ARG EASYRSA_VERSION=3.2.5
ARG NPROC=1

# Testing: pamtester is only available in edge, not for now.
# Use UPSTREAM_VERSION for downloads if provided, otherwise fall back to VERSION
RUN set -ex \
    && DOWNLOAD_VERSION="${UPSTREAM_VERSION:-$VERSION}" \
    && apk add --update iptables bash ca-certificates curl linux-pam libselinux openssl nss gnutls gzip \
        google-authenticator libqrencode libcap-ng \
    && apk add --no-cache --virtual .build-deps \
        gcc \
        pkgconfig \
        build-base \
        coreutils \
        libconfig-dev \
        linux-headers \
        autoconf \
        libtool \
        openssl-dev \
        linux-pam-dev \
        libselinux-dev \
        nss-dev \
        gnutls-dev \
        automake \
        make \
        libcap-ng-dev \
        libcap-dev \
    && cd /tmp && curl -sSL https://github.com/openvpn/openvpn/archive/$DOWNLOAD_VERSION.tar.gz --output openvpn.tgz \
    # Download pinned version of OpenSC pkcs11-helper
    && curl -sSL https://github.com/opensc/pkcs11-helper/archive/pkcs11-helper-${PKCS11_HELPER_VERSION}.tar.gz --output pkcs11-helper.tgz \
    && tar zxvf pkcs11-helper.tgz \
    && cd pkcs11-helper-pkcs11-helper-${PKCS11_HELPER_VERSION} \
    && autoreconf -ivf \
    # Note: --enable-pedantic removed - modern NSS headers use C++ comments incompatible with strict C90
    && ./configure --enable-strict \
    && make -j$NPROC \
    && make install \
    && cd /tmp \
    && tar zxvf openvpn.tgz && cd openvpn* \
    # Opinionated but lzo and lz4 are not required for OpenVPN to work
    # and subject to security issues.
    && autoreconf -ivf \
    && ./configure --disable-lzo --disable-lz4 --enable-pkcs11 --enable-iproute2 --enable-async-push --enable-selinux \
        --enable-plugin-auth-pam --enable-plugin-down-root --disable-debug --disable-systemd --enable-comp-stub \
    # Do not try to install documentation
    && echo "Building OpenVPN using ${NPROC} cores..." \
    && make -j${NPROC} \
    # Compile and install plugins (only in directories that have Makefiles)
    && make -C src/plugins -j${NPROC} \
    && make -C src/plugins install \
    && make install-exec \
    && apk del .build-deps \
    && cd /usr/local/bin \
    && curl -sSL https://raw.githubusercontent.com/oorabona/scripts/main/openvpn/setup.sh --output ovpn \
    && chmod +x ovpn \
    && rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

# Create a volume for the configuration
VOLUME ["/etc/openvpn"]

# Internally uses port 1194/udp, remap using `docker run -p 443:1194/tcp`
EXPOSE 1194/udp 1194/tcp

# Add healthcheck to verify OpenVPN is accessible
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD openvpn --version || exit 1

# Environment variables
ENV OS=other \
    EASYRSA_VERSION=${EASYRSA_VERSION}

# Copy the PAM configuration for OTP
COPY openvpn-pam.conf /etc/pam.d/openvpn

# Run OpenVPN setup script
CMD ["ovpn"]
