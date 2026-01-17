# Build Citus extension for PostgreSQL
# https://github.com/citusdata/citus
#
# License: AGPL-3.0
#
# Usage:
#   docker build -f citus.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=13.2.0 \
#     -t citus-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG EXT_VERSION=13.2.0
ARG EXT_REPO=citusdata/citus

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    curl-dev \
    lz4-dev \
    zstd-dev \
    icu-dev \
    libxml2-dev \
    openssl-dev \
    krb5-dev \
    autoconf \
    automake \
    libtool \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build Citus
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git citus

WORKDIR /build/citus

# Configure and build
RUN ./configure PG_CONFIG=/usr/local/bin/pg_config \
    --with-lz4 \
    --with-zstd \
    --without-libcurl

# Build with parallelism
RUN make -j$(nproc)

# Install to staging directory
RUN make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/citus* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/citus.so /output/lib/ && \
    cp -v /install/usr/local/lib/postgresql/citus_*.so /output/lib/ 2>/dev/null || true

# Also copy any additional shared libraries Citus provides
RUN find /install -name "*.so" -exec cp -v {} /output/lib/ \; 2>/dev/null || true

# Add metadata
RUN echo "extension=citus" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "license=AGPL-3.0" >> /output/metadata.txt && \
    echo "shared_preload=true" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
