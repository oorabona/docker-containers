# Build TimescaleDB extension for PostgreSQL
# https://github.com/timescale/timescaledb
#
# License: Apache-2.0 (core) + TSL (advanced features)
#
# Usage:
#   docker build -f timescaledb.Dockerfile \
#     --build-arg PG_MAJOR=17 \
#     --build-arg EXT_VERSION=2.24.0 \
#     -t timescaledb-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

ARG EXT_VERSION=2.24.0
ARG EXT_REPO=timescale/timescaledb

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    cmake \
    git \
    openssl-dev \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download TimescaleDB source
WORKDIR /build

RUN git clone --branch ${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git timescaledb

WORKDIR /build/timescaledb

# Bootstrap the build system
RUN ./bootstrap \
    -DCMAKE_BUILD_TYPE=Release \
    -DREGRESS_CHECKS=OFF \
    -DWARNINGS_AS_ERRORS=OFF \
    -DAPACHE_ONLY=OFF

# Build
WORKDIR /build/timescaledb/build
RUN make -j$(nproc)

# Install to staging directory
RUN make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/timescaledb* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/timescaledb*.so /output/lib/

# Add metadata
RUN echo "extension=timescaledb" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "pg_major=${PG_MAJOR}" >> /output/metadata.txt && \
    echo "license=Apache-2.0+TSL" >> /output/metadata.txt && \
    echo "shared_preload=true" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
