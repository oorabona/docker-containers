# Vector - High-performance observability data pipeline
# Downloads pre-built musl binary from GitHub releases
# https://vector.dev

ARG VERSION=latest
ARG UPSTREAM_VERSION=""
ARG OS_IMAGE_BASE="alpine"
ARG OS_IMAGE_TAG="latest"

FROM ${OS_IMAGE_BASE}:${OS_IMAGE_TAG}

ARG UPSTREAM_VERSION
ARG TARGETARCH

# Download and install pre-built Vector binary
# Uses musl-linked static binary for Alpine compatibility
RUN set -ex \
    && case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && apk add --no-cache ca-certificates tzdata \
    && wget -qO- "https://github.com/vectordotdev/vector/releases/download/v${UPSTREAM_VERSION}/vector-${UPSTREAM_VERSION}-${ARCH}-unknown-linux-musl.tar.gz" \
        | tar xzf - -C /tmp/ \
    && mv /tmp/vector-${ARCH}-unknown-linux-musl/bin/vector /usr/local/bin/vector \
    && rm -rf /tmp/vector-* \
    && vector --version

# Create vector user and data directory
RUN addgroup -g 1000 -S vector \
    && adduser -S -D -H -u 1000 -h /var/lib/vector -s /sbin/nologin -G vector -g vector vector \
    && mkdir -p /etc/vector /var/lib/vector \
    && chown vector:vector /var/lib/vector

# Default config: demo pipeline (generate → console)
# Mount your own config at /etc/vector/vector.yaml for production use
COPY vector.yaml /etc/vector/vector.yaml

USER vector

# Vector API port (for `vector top`, health checks, GraphQL)
EXPOSE 8686

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD ["wget", "-qO-", "http://localhost:8686/health"]

ENTRYPOINT ["vector"]
