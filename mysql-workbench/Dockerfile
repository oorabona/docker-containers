ARG OS_VERSION=latest

FROM ubuntu:${OS_VERSION}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

ENV DEBIAN_FRONTEND=noninteractive

RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        lsb-release \
        gnupg \
        wget \
    && apt-key adv --keyserver pgp.mit.edu --recv-keys 467B942D3A79BD29 \
    && wget -q https://dev.mysql.com/get/mysql-apt-config_0.8.10-1_all.deb -O /tmp/mysql-apt-config.deb \
    && dpkg -i /tmp/mysql-apt-config.deb \
    && apt-get update && apt-get dist-upgrade -y && apt-get install -y mysql-workbench-community

CMD ["mysql-workbench"]
