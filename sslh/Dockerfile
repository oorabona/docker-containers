FROM ubuntu:latest
MAINTAINER Olivier ORABONA <github.com/oorabona>

# Add dependencies to compile sslh from sources
RUN apt-get update \
  && apt-get -y install git libwrap0-dev libconfig8-dev \
  && rm -rf /var/lib/apt/lists/*

# Quick clone/build/install/remove from sslh sources
RUN git clone https://github.com/yrutschle/sslh.git \
  && cd sslh && make install \
  && cd .. && rm -rf sslh

COPY docker-entrypoint.sh /
RUN chmod +x /docker-entrypoint.sh

ENV LISTEN_IP 0.0.0.0
ENV LISTEN_PORT 443
ENV SSH_HOST localhost
ENV SSH_PORT 22
ENV OPENVPN_HOST localhost
ENV OPENVPN_PORT 1194
ENV HTTPS_HOST localhost
ENV HTTPS_PORT 8443

EXPOSE 443

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["-V"]
