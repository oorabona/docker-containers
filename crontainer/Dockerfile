FROM debian:jessie
MAINTAINER Olivier ORABONA olivier.orabona@gmail.com

RUN apt-get update \
 && apt-get install -y cron \
 && touch /var/log/cron.log

VOLUME ["/etc/cron.d", "/var/spool/cron/crontabs/"]

# Run the command on container startup
CMD cron && tail -f /var/log/cron.log
