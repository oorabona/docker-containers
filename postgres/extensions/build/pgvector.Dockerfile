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

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG EXT_VERSION=0.8.0
ARG EXT_REPO=pgvector/pgvector

# Install build dependencies
# Note: llvm19-dev and clang19 for LLVM JIT support
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build pgvector
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pgvector

WORKDIR /build/pgvector

# Build with optimizations
# pgvector supports SIMD optimizations on modern CPUs
RUN make clean && \
    make OPTFLAGS="-march=x86-64-v2 -O3" PG_CONFIG=/usr/local/bin/pg_config && \
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
