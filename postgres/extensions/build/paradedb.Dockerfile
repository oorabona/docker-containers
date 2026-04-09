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

ARG MAJOR_VERSION
FROM postgres:${MAJOR_VERSION}-alpine AS builder

ARG MAJOR_VERSION
ARG EXT_VERSION
ARG EXT_REPO

# Validate required build args
RUN : "${EXT_VERSION:?required}" "${EXT_REPO:?required}"

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

# Download ParadeDB source (before pgrx install to auto-detect version)
WORKDIR /build
RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git paradedb

# Install pgrx - the Rust PostgreSQL extension framework
# Version is auto-detected from ParadeDB's Cargo.toml to stay in sync
RUN PGRX_VERSION=$(grep -m1 '^pgrx' /build/paradedb/pg_search/Cargo.toml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') \
    && echo "Detected pgrx version: ${PGRX_VERSION}" \
    && cargo install --locked cargo-pgrx --version "${PGRX_VERSION}"

# Initialize pgrx with our PostgreSQL installation
RUN cargo pgrx init --pg${MAJOR_VERSION}=/usr/local/bin/pg_config

WORKDIR /build/paradedb/pg_search

# Build pg_search extension
# Note: This takes a while due to Rust compilation (~15-30 min)
# Cache mounts persist cargo registry + git index across builds to speed up rebuilds
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    cargo pgrx package --pg-config /usr/local/bin/pg_config

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

# Final stage: only the compiled extension files
FROM scratch
COPY --from=builder /output/ /output/
