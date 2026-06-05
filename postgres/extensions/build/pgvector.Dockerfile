# Build pgvector extension for PostgreSQL
# https://github.com/pgvector/pgvector
#
# Usage:
#   docker build -f pgvector.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=0.8.0 \
#     -t pgvector-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG REMOTE_CR=ghcr.io/oorabona
ARG MAJOR_VERSION
FROM ${REMOTE_CR}/library/postgres:${MAJOR_VERSION}-alpine AS builder

ARG REMOTE_CR
ARG EXT_VERSION
ARG EXT_REPO
ARG MAJOR_VERSION
# Provided automatically by buildx (amd64 / arm64); selects the OPTFLAGS baseline below.
ARG TARGETARCH

# Validate required build args
RUN : "${EXT_VERSION:?required}" "${EXT_REPO:?required}"

# Install build dependencies
# Note: llvm19-dev and clang19 for LLVM JIT support
RUN apk add --no-cache \
    build-base \
    clang19 \
    git \
    icu-dev \
    llvm19-dev \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build pgvector
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pgvector

WORKDIR /build/pgvector

# Build with optimizations. pgvector uses SIMD, so pick a portable per-arch
# baseline: -march=x86-64-v2 is an x86-64-only microarchitecture level that gcc
# rejects on arm64, so select armv8-a (the arm64 baseline, includes NEON) there
# and fall back to plain -O3 for any other target.
RUN case "${TARGETARCH}" in \
        amd64) OPTFLAGS="-march=x86-64-v2 -O3" ;; \
        arm64) OPTFLAGS="-march=armv8-a -O3" ;; \
        *)     OPTFLAGS="-O3" ;; \
    esac && \
    make clean && \
    make OPTFLAGS="$OPTFLAGS" PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
# Extension files are installed to:
#   /usr/local/share/postgresql/extension/ - control and SQL files
#   /usr/local/lib/postgresql/ - shared library (.so)
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/vector* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/vector.so /output/lib/

# Add metadata
RUN echo "extension=pgvector" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/

# Final stage: only the compiled extension files
FROM scratch
COPY --from=builder /output/ /output/
