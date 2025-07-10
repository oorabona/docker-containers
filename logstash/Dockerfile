FROM logstash:2.4

ENV CONFD_SUBDIRS *

COPY docker-entrypoint.sh /

WORKDIR /etc/logstash/conf.d/

# Add healthcheck to verify logstash is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:9600/_node/stats || exit 1

# Ok by default now lets just test config files
CMD ["-t"]
