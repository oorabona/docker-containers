# Multi-stage build for minimal FROM scratch image
# Stage 1: Build sslh with static linking

ARG OS_IMAGE_BASE="alpine"
ARG OS_IMAGE_TAG="latest"

FROM ${OS_IMAGE_BASE}:${OS_IMAGE_TAG} AS builder

ARG VERSION=latest
ARG NPROC=1

WORKDIR /build

# Install build dependencies - build dynamically then copy shared libs
# Note: VERSION may include suffix like "-alpine" - extract clean version for GitHub URL
RUN set -ex \
    && CLEAN_VERSION=$(echo "$VERSION" | sed 's/-alpine$//' | sed 's/-ubuntu$//') \
    && apk add --no-cache \
        build-base \
        coreutils \
        libconfig-dev \
        libev-dev \
        pcre2-dev \
        make \
        autoconf \
        automake \
        ca-certificates \
        wget \
        linux-headers \
        # Runtime libraries (will be copied to output)
        libconfig \
        libev \
        pcre2 \
        # For healthcheck binary (static)
        busybox-static \
    # Download and extract sslh source
    && wget -q https://github.com/yrutschle/sslh/archive/$CLEAN_VERSION.tar.gz \
    && tar zxf $CLEAN_VERSION.tar.gz \
    && cd /build/sslh-* \
    # Configure for dynamic build (musl shared libs are small)
    && ./configure --enable-libconfig --enable-libev \
    && make -j${NPROC} \
    # Strip binaries for minimal size
    && strip sslh-fork sslh-select sslh-ev \
    # Move binaries to known location
    && mkdir -p /output/bin /output/lib \
    && mv sslh-fork sslh-select sslh-ev /output/bin/ \
    # Copy busybox-static for healthcheck (nc applet)
    && cp /bin/busybox.static /output/bin/busybox \
    # Copy required shared libraries (musl-based, very small)
    && cp /lib/ld-musl-*.so.1 /output/lib/ \
    && cp /usr/lib/libconfig.so* /output/lib/ \
    && cp /usr/lib/libev.so* /output/lib/ \
    && cp /usr/lib/libpcre2-8.so* /output/lib/ \
    # Create minimal passwd/group for nobody user (uid 65534)
    && mkdir -p /output/etc \
    && echo "nobody:x:65534:65534:Nobody:/:/sbin/nologin" > /output/etc/passwd \
    && echo "nobody:x:65534:" > /output/etc/group \
    # Copy CA certificates for TLS verification
    && mkdir -p /output/etc/ssl/certs \
    && cp /etc/ssl/certs/ca-certificates.crt /output/etc/ssl/certs/

# Stage 2: Minimal scratch image
FROM scratch

# Copy user/group files for nobody user
COPY --from=builder /output/etc/passwd /etc/passwd
COPY --from=builder /output/etc/group /etc/group

# Copy CA certificates
COPY --from=builder /output/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy shared libraries (musl-based, very small)
COPY --from=builder /output/lib/ /lib/

# Copy sslh binaries
COPY --from=builder /output/bin/sslh-fork /usr/local/bin/sslh-fork
COPY --from=builder /output/bin/sslh-select /usr/local/bin/sslh-select
COPY --from=builder /output/bin/sslh-ev /usr/local/bin/sslh-ev

# Copy busybox for healthcheck (nc applet)
COPY --from=builder /output/bin/busybox /bin/busybox

# Run as nobody user
USER nobody:nobody

# Expose default port
EXPOSE 443

# Healthcheck - verify sslh is listening (TCP connection test)
# Uses busybox nc (netcat) applet - statically linked
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD ["/bin/busybox", "nc", "-z", "127.0.0.1", "443"]

# Default to sslh-ev (best performance)
# Users must provide full command line arguments
# Example: docker run sslh -f -p 0.0.0.0:443 --ssh localhost:22 --tls localhost:8443
ENTRYPOINT ["/usr/local/bin/sslh-ev"]

# Show version by default
CMD ["-V"]
