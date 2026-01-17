# Build pg_partman extension for PostgreSQL
# https://github.com/pgpartman/pg_partman
#
# pg_partman provides automatic partition management for time-series
# and serial-based table partitioning

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

ARG EXT_VERSION=5.2.4
ARG EXT_REPO=pgpartman/pg_partman

# Install build dependencies
# Note: clang19 and llvm19-dev required for LLVM JIT bitcode compilation
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build pg_partman
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pg_partman

WORKDIR /build/pg_partman

# Build
RUN make PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/pg_partman* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/pg_partman_bgw.so /output/lib/ 2>/dev/null || true

# Add metadata
RUN echo "extension=pg_partman" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "pg_major=${PG_MAJOR}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
