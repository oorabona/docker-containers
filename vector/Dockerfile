# Vector - High-performance observability data pipeline
# Downloads pre-built musl binary from GitHub releases
# https://vector.dev

ARG REMOTE_CR=ghcr.io/oorabona
ARG VERSION
ARG UPSTREAM_VERSION
ARG OS_IMAGE_TAG

FROM ${REMOTE_CR}/library/alpine:${OS_IMAGE_TAG}

ARG UPSTREAM_VERSION
ARG TARGETARCH

# Validate required build args
RUN : "${UPSTREAM_VERSION:?required}"

# Download and install pre-built Vector binary
# Uses musl-linked static binary for Alpine compatibility
RUN set -ex \
    && case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && apk add --no-cache ca-certificates tzdata \
    && for attempt in 1 2 3; do \
         wget -qO /tmp/vector.tgz "https://github.com/vectordotdev/vector/releases/download/v${UPSTREAM_VERSION}/vector-${UPSTREAM_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" && break; \
         [ "$attempt" -lt 3 ] && sleep 2 || { echo "vector download failed after retries" >&2; exit 1; }; \
       done \
    && tar xzf /tmp/vector.tgz -C /tmp/ \
    && mv /tmp/vector-${ARCH}-unknown-linux-musl/bin/vector /usr/local/bin/vector \
    && rm -rf /tmp/vector-* /tmp/vector.tgz \
    && vector --version

# Create vector user and data directory
RUN addgroup -g 1000 -S vector \
    && adduser -S -D -H -u 1000 -h /var/lib/vector -s /sbin/nologin -G vector -g vector vector \
    && mkdir -p /etc/vector /var/lib/vector \
    && chown vector:vector /var/lib/vector

# Default config: demo pipeline (generate → console)
# Mount your own config at /etc/vector/vector.yaml for production use
COPY vector.yaml /etc/vector/vector.yaml

LABEL org.opencontainers.image.title="Vector" \
      org.opencontainers.image.description="High-performance observability data pipeline" \
      org.opencontainers.image.source="https://github.com/oorabona/docker-containers" \
      org.opencontainers.image.vendor="oorabona" \
      org.opencontainers.image.licenses="MIT"

USER vector

# Vector API port (for `vector top`, health checks, GraphQL)
EXPOSE 8686

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD ["wget", "-qO-", "http://localhost:8686/health"]

ENTRYPOINT ["vector"]
