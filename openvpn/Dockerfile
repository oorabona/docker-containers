# Smallest base image
ARG OS_VERSION=latest
FROM alpine:${OS_VERSION}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

ARG VERSION=latest
ARG NPROC=1

# Testing: pamtester
# RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories && \
#     apk add --update openvpn iptables bash easy-rsa openvpn-auth-pam google-authenticator pamtester libqrencode && \
#     ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin && \
#     rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

RUN set -ex \
    && apk add --update iptables bash ca-certificates curl linux-pam libselinux openssl nss gnutls gzip \
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
    # Do not try to install documentation
    && echo "Building OpenVPN using ${NPROC} cores..." \
    && make -j${NPROC} && make install-exec \
    && apk del .build-deps \
    && cd /usr/local/bin \
    && curl -sSL https://raw.githubusercontent.com/oorabona/scripts/master/openvpn/setup.sh --output ovpn \
    && chmod +x ovpn \
    && rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

# Create a volume for the configuration
VOLUME ["/etc/openvpn"]

# Internally uses port 1194/udp, remap using `docker run -p 443:1194/tcp`
EXPOSE 1194/udp

CMD ["ovpn"]

# ADD ./bin /usr/local/bin
# RUN chmod a+x /usr/local/bin/*

# Add support for OTP authentication using a PAM module
# ADD ./otp/openvpn /etc/pam.d/