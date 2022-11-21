# Smallest base image
ARG OS_VERSION=latest
FROM alpine:${OS_VERSION}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

ARG VERSION=latest
ARG NPROC=1

# Testing: pamtester is only available in edge, not for now.
RUN set -ex \
    && apk add --update iptables bash ca-certificates curl linux-pam libselinux openssl nss gnutls gzip \
        google-authenticator libqrencode \
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
        git \
    && cd /tmp && curl -sSL https://github.com/openvpn/openvpn/archive/$VERSION.tar.gz --output openvpn.tgz \
    # Download latest version of OpenSC pkcs11-helper from github
    && PKCS11_HELPER_VERSION=$(git ls-remote --tags --sort="v:refname" https://github.com/opensc/pkcs11-helper.git | tail -n1 | awk '{print $2}' | sed 's/refs\/tags\///') \
    && curl -sSL https://github.com/opensc/pkcs11-helper/archive/$PKCS11_HELPER_VERSION.tar.gz --output pkcs11-helper.tgz \
    && tar zxvf pkcs11-helper.tgz \
    && cd pkcs11-helper-$PKCS11_HELPER_VERSION \
    && autoreconf -ivf \
    && ./configure --enable-strict --enable-pedantic \
    && make distcheck \
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
    # Compile also the plugins
    && find src/plugins/ -type d -exec make -C {} -j${NPROC} \; -exec make -C {} install \; \
    && make install-exec \
    && apk del .build-deps \
    && cd /usr/local/bin \
    && curl -sSL https://raw.githubusercontent.com/oorabona/scripts/master/openvpn/setup.sh --output ovpn \
    && chmod +x ovpn \
    && rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

# Create a volume for the configuration
VOLUME ["/etc/openvpn"]

# Internally uses port 1194/udp, remap using `docker run -p 443:1194/tcp`
EXPOSE 1194/udp 1194/tcp

# Environment variables
# Later versions of EASYRSA seem to break the script
ENV OS=other \
    EASYRSA_VERSION=3.0.8

# Copy the PAM configuration for OTP
COPY openvpn-pam.conf /etc/pam.d/openvpn

# Run OpenVPN setup script
CMD ["ovpn"]
