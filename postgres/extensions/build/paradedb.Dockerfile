# Build ParadeDB pg_search extension for PostgreSQL
# https://github.com/paradedb/paradedb
#
# License: AGPL-3.0
#
# Usage:
#   docker build -f paradedb.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=0.20.7 \
#     -t paradedb-builder .
#
# Output: /output/ contains files to extract via docker cp
#
# Note: This uses a multi-stage build with Debian for compilation
# because pgrx/bindgen requires glibc for dynamic loading of libclang.
# The final output is compatible with Alpine PostgreSQL images.

ARG MAJOR_VERSION=17

# ============================================================================
# Build Stage (Debian-based for glibc/libclang compatibility)
# ============================================================================
FROM postgres:${MAJOR_VERSION}-bookworm AS builder

ARG MAJOR_VERSION
ARG EXT_VERSION=0.20.7
ARG EXT_REPO=paradedb/paradedb

# Install build dependencies
# ParadeDB uses pgrx which requires Rust and clang with libclang
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    llvm-dev \
    libclang-dev \
    git \
    curl \
    ca-certificates \
    libssl-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install Rust via rustup (required for pgrx)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install pgrx - the Rust PostgreSQL extension framework
# Version must match what ParadeDB uses
RUN cargo install --locked cargo-pgrx --version 0.16.1

# Initialize pgrx with our PostgreSQL installation
RUN cargo pgrx init --pg${MAJOR_VERSION}=/usr/bin/pg_config

# Download ParadeDB source
WORKDIR /build
RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git paradedb

WORKDIR /build/paradedb/pg_search

# Build pg_search extension
# Note: This takes a while due to Rust compilation
RUN cargo pgrx package --pg-config /usr/bin/pg_config

# Prepare output structure
# pgrx packages to target/release/pg_search-pg{major}/
RUN mkdir -p /output/extension /output/lib && \
    find target/release -name "pg_search*.control" -exec cp -v {} /output/extension/ \; && \
    find target/release -name "pg_search*.sql" -exec cp -v {} /output/extension/ \; && \
    find target/release -name "pg_search.so" -exec cp -v {} /output/lib/ \;

# Add metadata
RUN echo "extension=paradedb" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "license=AGPL-3.0" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/

# ============================================================================
# Output Stage (minimal image with just the extension files)
# ============================================================================
FROM scratch

COPY --from=builder /output/ /output/
