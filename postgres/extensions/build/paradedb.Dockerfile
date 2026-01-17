# Build ParadeDB pg_search extension for PostgreSQL
# https://github.com/paradedb/paradedb
#
# License: AGPL-3.0
#
# Usage:
#   docker build -f paradedb.Dockerfile \
#     --build-arg PG_MAJOR=17 \
#     --build-arg EXT_VERSION=0.20.7 \
#     -t paradedb-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

ARG EXT_VERSION=0.20.7
ARG EXT_REPO=paradedb/paradedb

# Install build dependencies
# ParadeDB uses pgrx which requires Rust and clang
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    curl \
    openssl-dev \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Install Rust via rustup (required for pgrx)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install pgrx - the Rust PostgreSQL extension framework
# Version must match what ParadeDB uses
RUN cargo install --locked cargo-pgrx --version 0.16.1

# Initialize pgrx with our PostgreSQL installation
RUN cargo pgrx init --pg${PG_MAJOR}=/usr/local/bin/pg_config

# Download ParadeDB source
WORKDIR /build
RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git paradedb

WORKDIR /build/paradedb/pg_search

# Build pg_search extension
# Note: This takes a while due to Rust compilation
RUN cargo pgrx package --pg-config /usr/local/bin/pg_config

# Prepare output structure
# pgrx packages to target/release/pg_search-pg{major}/
RUN mkdir -p /output/extension /output/lib && \
    cp -v target/release/pg_search-pg${PG_MAJOR}/usr/share/postgresql/*/extension/pg_search* /output/extension/ 2>/dev/null || \
    cp -v target/release/pg_search-pg${PG_MAJOR}/usr/local/share/postgresql/extension/pg_search* /output/extension/ && \
    cp -v target/release/pg_search-pg${PG_MAJOR}/usr/lib/postgresql/*/lib/pg_search.so /output/lib/ 2>/dev/null || \
    cp -v target/release/pg_search-pg${PG_MAJOR}/usr/local/lib/postgresql/pg_search.so /output/lib/

# Add metadata
RUN echo "extension=paradedb" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "pg_major=${PG_MAJOR}" >> /output/metadata.txt && \
    echo "license=AGPL-3.0" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
