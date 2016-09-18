FROM logstash:2.3.3
MAINTAINER Olivier ORABONA (olivier.orabona@gmail.com)

ENV CONFD_SUBDIRS *

COPY docker-entrypoint.sh /

WORKDIR /etc/logstash/conf.d/

# Ok by default now lets just test config files
CMD ["-t"]
