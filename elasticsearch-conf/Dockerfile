FROM debian:jessie

ADD https://github.com/kelseyhightower/confd/releases/download/v0.11.0/confd-0.11.0-linux-amd64 /confd

ADD ./conf.d /etc/confd/conf.d
ADD ./templates /etc/confd/templates
ADD ./run.sh /run.sh
ADD ./docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /confd /docker-entrypoint.sh

# Add minimal software
RUN apt-get update && apt-get install -y wget curl

# Add this repository to install Curator packages
RUN wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch | apt-key add - \
  && echo "deb http://packages.elastic.co/curator/4/debian stable main" > /etc/apt/sources.list.d/curator.list \
  && apt-get update \
  && apt-get install -y python-elasticsearch-curator

# Simplified exposed volumes
VOLUME ["/data/confd", "/opt/rancher/bin", "/usr/share/elasticsearch/config"]

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["--backend", "rancher", "--prefix", "/2015-07-25"]
