# Base image
ARG VERSION=latest
FROM hashicorp/terraform:${VERSION} AS terraform

FROM alpine:latest

# Environment variables
ENV CONFIGFILE=config.json

# Copy terraform
COPY --from=terraform /bin/terraform /bin

# Install prerequisites and run installation script
RUN apk --no-cache add ca-certificates curl grep python3 py-pip bash git && \
    apk --no-cache add --virtual build-dependencies python3-dev build-base wget unzip && \
    pip install j2cli[yaml] && \
    apk del --purge build-dependencies && \
    rm -rf /var/cache/apk/*

# Volumes and workdir configuration
VOLUME ["/data"]
WORKDIR /data

# Entrypoint to enable live customization
COPY docker-entrypoint.sh /docker-entrypoint.sh

# Add healthcheck to verify terraform is working
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD terraform version || exit 1

# Main command
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default flags for the main command
CMD ["-help"]
