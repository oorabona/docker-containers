# Build ParadeDB pg_search extension for PostgreSQL (Alpine)
# https://github.com/paradedb/paradedb
#
# License: AGPL-3.0
#
# Usage:
#   docker build -f paradedb.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=0.21.8 \
#     -t paradedb-builder .
#
# Output: /output/ contains files to extract via docker cp
#
# Note: This is an EXPERIMENTAL Alpine/musl build.
# Key: RUSTFLAGS="-C target-feature=-crt-static" prevents static linking of
# musl libc, which is required for pgrx dynamic loading on Alpine.
# See: https://github.com/pgcentralfoundation/pgrx/pull/362

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG MAJOR_VERSION
ARG EXT_VERSION=0.21.8
ARG EXT_REPO=paradedb/paradedb

# Critical: disable static CRT linking for musl/pgrx compatibility
ENV RUSTFLAGS="-C target-feature=-crt-static"

# Install build dependencies
# pgrx requires Rust, clang (for bindgen/libclang), and OpenSSL
RUN apk add --no-cache \
    build-base \
    clang19 \
    clang19-libclang \
    llvm19-dev \
    openssl-dev \
    icu-dev \
    git \
    curl \
    pkgconf \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Install Rust via rustup (required for pgrx)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install pgrx - the Rust PostgreSQL extension framework
# Version must match what ParadeDB uses (pinned in their Cargo.toml)
RUN cargo install --locked cargo-pgrx --version 0.16.1

# Initialize pgrx with our PostgreSQL installation
RUN cargo pgrx init --pg${MAJOR_VERSION}=/usr/local/bin/pg_config

# Download ParadeDB source
WORKDIR /build
RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git paradedb

WORKDIR /build/paradedb/pg_search

# Build pg_search extension
# Note: This takes a while due to Rust compilation (~15-30 min)
RUN cargo pgrx package --pg-config /usr/local/bin/pg_config

# Prepare output structure
# pgrx packages to /build/paradedb/target/release/pg_search-pg{major}/usr/local/...
# Note: WORKDIR is pg_search/ but target/ is in parent (paradedb/)
RUN set -eux; \
    PKG_DIR=$(find /build/paradedb/target -type d -name "pg_search-pg*" | head -1); \
    echo "Found pgrx package dir: $PKG_DIR"; \
    mkdir -p /output/extension /output/lib; \
    cp -v "$PKG_DIR"/usr/local/share/postgresql/extension/pg_search.control /output/extension/; \
    cp -v "$PKG_DIR"/usr/local/share/postgresql/extension/pg_search--*.sql /output/extension/; \
    cp -v "$PKG_DIR"/usr/local/lib/postgresql/pg_search.so /output/lib/

# Add metadata
RUN echo "extension=paradedb" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "license=AGPL-3.0" >> /output/metadata.txt && \
    echo "build_target=alpine-musl" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
