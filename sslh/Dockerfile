ARG OS_IMAGE_BASE="alpine"
ARG OS_IMAGE_TAGCOPY docker-entrypoint.sh /

EXPOSE 443

# Add healthcheck to verify SSLH is responding correctly
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD netstat -tuln | grep ':443' || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]

# By default we return sslh version.
CMD ["-V"]

USER nobody
FROM ${OS_IMAGE_BASE}:${OS_IMAGE_TAG}

ARG VERSION=latest
ARG NPROC=1
ARG USELIBCAP=1

ENV USE_CONFIG=/etc/sslh.cfg \
  USE_SSLH_FLAVOR=sslh-ev \
  LISTEN_IP=0.0.0.0 \
  LISTEN_PORT=443 \
  SSH_HOST=localhost \
  SSH_PORT=22 \
  OPENVPN_HOST=localhost \
  OPENVPN_PORT=1194 \
  HTTPS_HOST=localhost \
  HTTPS_PORT=8443

WORKDIR /

# Add dependencies to compile sslh from sources
RUN set -ex \
    && apk add --no-cache --virtual .build-deps \
        build-base \
        coreutils \
        libconfig-dev \
        libev-dev \
        pcre2-dev \
        make \
  && apk add --no-cache ca-certificates wget libconfig pcre2 libev iptables socat \
  && wget https://github.com/yrutschle/sslh/archive/$VERSION.tar.gz \
  && tar zxvf $VERSION.tar.gz && cd /sslh* && make -j${NPROC}\
  && SSLH_BIN="sslh-fork sslh-select sslh-ev" \
  && strip $SSLH_BIN \
  && for bin in $SSLH_BIN; do mv /sslh*/$bin /usr/local/bin/$bin; done \
  && rm -rf /sslh* \
  && apk del .build-deps \
  && rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

COPY docker-entrypoint.sh /

EXPOSE 443

ENTRYPOINT ["/docker-entrypoint.sh"]

# By default we return sslh version.
CMD ["-V"]

USER nobody