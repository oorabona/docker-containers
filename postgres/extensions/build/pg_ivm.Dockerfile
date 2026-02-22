# Build pg_ivm extension for PostgreSQL
# https://github.com/sraoss/pg_ivm
#
# pg_ivm provides Incremental View Maintenance for materialized views
# Automatically updates materialized views when base tables change
#
# Usage:
#   docker build -f pg_ivm.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=1.13 \
#     -t pg_ivm-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG EXT_VERSION=1.13
ARG EXT_REPO=sraoss/pg_ivm

# Install build dependencies
# Note: clang19 and llvm19-dev required for LLVM JIT bitcode compilation
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build pg_ivm
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pg_ivm

WORKDIR /build/pg_ivm

# Build
RUN make PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/pg_ivm* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/pg_ivm.so /output/lib/

# Add metadata
RUN echo "extension=pg_ivm" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
