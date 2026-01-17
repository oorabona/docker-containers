# Build HypoPG extension for PostgreSQL
# https://github.com/HypoPG/hypopg
#
# HypoPG allows creating hypothetical indexes to test query plans
# without actually creating the indexes

ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

ARG EXT_VERSION=1.4.1
ARG EXT_REPO=HypoPG/hypopg

# Install build dependencies
# Note: clang19 and llvm19-dev required for LLVM JIT bitcode compilation
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build hypopg
WORKDIR /build

RUN git clone --branch ${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git hypopg

WORKDIR /build/hypopg

# Build
RUN make PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/hypopg* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/hypopg.so /output/lib/

# Add metadata
RUN echo "extension=hypopg" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "pg_major=${PG_MAJOR}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
