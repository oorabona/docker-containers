# Smallest base image
ARG OS_VERSION=latest
FROM alpine:${OS_VERSION}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

ARG VERSION=latest

# Testing: pamtester
# RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories && \
#     apk add --update openvpn iptables bash easy-rsa openvpn-auth-pam google-authenticator pamtester libqrencode && \
#     ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin && \
#     rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

RUN set -ex \
    && apk add --update iptables bash ca-certificates wget linux-pam openssl \
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
        automake \
        make \
    && cd / && wget https://github.com/openvpn/openvpn/archive/$VERSION.tar.gz \
    && tar zxvf $VERSION.tar.gz && cd /openvpn* \
    # Opinionated but lzo and lz4 are not required for OpenVPN to work
    # and subject to security issues.
    && autoreconf -i -v -f \
    && ./configure --disable-lzo --disable-lz4 \
    # Do not try to install documentation
    && make && make install-exec \
    && rm -rf /openvpn* \
    && apk del .build-deps \
    && wget -qO /usr/local/bin/ovpn https://raw.githubusercontent.com/oorabona/scripts/master/openvpn/setup.sh \
    && chmod +x /usr/local/bin/ovpn \
    && rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

# Needed by scripts
ENV OPENVPN=/etc/openvpn
ENV EASYRSA=/usr/share/easy-rsa \
    EASYRSA_CRL_DAYS=3650 \
    EASYRSA_PKI=$OPENVPN/pki

VOLUME ["/etc/openvpn"]

# Internally uses port 1194/udp, remap using `docker run -p 443:1194/tcp`
EXPOSE 1194/udp

CMD ["ovpn"]

# ADD ./bin /usr/local/bin
# RUN chmod a+x /usr/local/bin/*

# Add support for OTP authentication using a PAM module
# ADD ./otp/openvpn /etc/pam.d/