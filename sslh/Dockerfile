ARG OS_VERSION=buster
FROM bitnami/minideb:${OS_VERSION}

ARG VERSION=latest
LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

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
COPY autoinstall /usr/local/bin

WORKDIR /

# Add dependencies to compile sslh from sources
RUN apt-get update && apt-get -y dist-upgrade \
  && apt-get install -y ca-certificates wget libconfig9 \
  && autoinstall make gcc libc6-dev libpcre3-dev libwrap0-dev libconfig-dev \
  # && wget https://github.com/yrutschle/conf2struct/archive/master.tar.gz \
  # && tar zxvf master.tar.gz && cd /conf2struct* && make && make install \
  && cd / && wget https://github.com/yrutschle/sslh/archive/$VERSION.tar.gz \
  && tar zxvf $VERSION.tar.gz && cd /sslh* && make && make install \
  && rm -rf /sslh* \
  && apt-get remove --purge --auto-remove -y  \
  && rm -rf /var/lib/apt/lists/* /tmp/* /usr/share/doc/* /usr/share/man/*   \
  && chmod +x /docker-entrypoint.sh

EXPOSE 443

ENTRYPOINT ["/docker-entrypoint.sh"]

# By default we return sslh version.
CMD ["-V"]
