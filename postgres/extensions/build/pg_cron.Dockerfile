# Build pg_cron extension for PostgreSQL
# https://github.com/citusdata/pg_cron
#
# pg_cron provides cron-based job scheduling inside PostgreSQL
# Requires shared_preload_libraries for the background worker
#
# Usage:
#   docker build -f pg_cron.Dockerfile \
#     --build-arg MAJOR_VERSION=17 \
#     --build-arg EXT_VERSION=1.6.7 \
#     -t pg_cron-builder .
#
# Output: /output/ contains files to extract via docker cp

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG EXT_VERSION=1.6.7
ARG EXT_REPO=citusdata/pg_cron

# Install build dependencies
# Note: clang19 and llvm19-dev required for LLVM JIT bitcode compilation
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build pg_cron
WORKDIR /build

RUN git clone --branch v${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pg_cron

WORKDIR /build/pg_cron

# Build
RUN make PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/pg_cron* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/pg_cron.so /output/lib/

# Add metadata
RUN echo "extension=pg_cron" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
