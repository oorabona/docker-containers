ARG OS_IMAGE_BASE="alpine"
ARG OS_IMAGE_TAG="latest"

FROM ${OS_IMAGE_BASE}:${OS_IMAGE_TAG}

ARG SSLH_VERSION=latest
LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"
LABEL description="SSLH (https://www.rutschle.net/tech/sslh.shtml) is a protocol multiplexer that allows several services to share the same port."
LABEL version="${SSLH_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
  LISTEN_IP=0.0.0.0 \
  LISTEN_PORT=443 \
  SSH_HOST=localhost \
  SSH_PORT=22 \
  OPENVPN_HOST=localhost \
  OPENVPN_PORT=1194 \
  HTTPS_HOST=localhost \
  HTTPS_PORT=8443

COPY docker-entrypoint.sh /

WORKDIR /

# Add dependencies to compile sslh from sources
RUN set -ex \
    && apk add --no-cache --virtual .build-deps \
        build-base \
        coreutils \
        libconfig-dev \
        pcre2-dev \
        make \
  && apk add --no-cache ca-certificates wget libconfig pcre2 \
  && cd / && wget https://github.com/yrutschle/sslh/archive/$SSLH_VERSION.tar.gz \
  && tar zxvf $SSLH_VERSION.tar.gz && cd /sslh* && make && make install \
  && rm -rf /sslh* \
  && chmod +x /docker-entrypoint.sh \
  && apk del .build-deps

EXPOSE 443

ENTRYPOINT ["/docker-entrypoint.sh"]

# By default we return sslh version.
CMD ["-V"]
