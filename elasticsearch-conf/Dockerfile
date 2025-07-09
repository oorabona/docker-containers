FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install elasticsearch-curator via pip (newer approach)
RUN pip3 install --no-cache-dir elasticsearch-curator

# Download confd
ADD https://github.com/kelseyhightower/confd/releases/download/v0.16.0/confd-0.16.0-linux-amd64 /confd

# Copy configuration and scripts
ADD ./conf.d /etc/confd/conf.d
ADD ./templates /etc/confd/templates
ADD ./run.sh /run.sh
ADD ./docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /confd /docker-entrypoint.sh /run.sh

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD /confd -version || exit 1

# Simplified exposed volumes
VOLUME ["/data/confd", "/opt/rancher/bin", "/usr/share/elasticsearch/config"]

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["--backend", "rancher", "--prefix", "/2015-07-25"]
