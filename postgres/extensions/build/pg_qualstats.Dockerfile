# Build pg_qualstats extension for PostgreSQL
# https://github.com/powa-team/pg_qualstats
#
# pg_qualstats collects statistics about predicates used in WHERE clauses
# Useful for identifying missing indexes

ARG MAJOR_VERSION=17
FROM postgres:${MAJOR_VERSION}-alpine

ARG EXT_VERSION=2.1.1
ARG EXT_REPO=powa-team/pg_qualstats

# Install build dependencies
# Note: clang19 and llvm19-dev required for LLVM JIT bitcode compilation
RUN apk add --no-cache \
    build-base \
    clang19 \
    llvm19-dev \
    git \
    && ln -sf /usr/bin/clang-19 /usr/bin/clang \
    && ln -sf /usr/bin/clang++-19 /usr/bin/clang++

# Download and build pg_qualstats
WORKDIR /build

RUN git clone --branch ${EXT_VERSION} --depth 1 \
    https://github.com/${EXT_REPO}.git pg_qualstats

WORKDIR /build/pg_qualstats

# Build
RUN make PG_CONFIG=/usr/local/bin/pg_config && \
    make install DESTDIR=/install

# Prepare output structure
RUN mkdir -p /output/extension /output/lib && \
    cp -v /install/usr/local/share/postgresql/extension/pg_qualstats* /output/extension/ && \
    cp -v /install/usr/local/lib/postgresql/pg_qualstats.so /output/lib/

# Add metadata
RUN echo "extension=pg_qualstats" > /output/metadata.txt && \
    echo "version=${EXT_VERSION}" >> /output/metadata.txt && \
    echo "major_version=${MAJOR_VERSION}" >> /output/metadata.txt && \
    echo "build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /output/metadata.txt && \
    echo "shared_preload=true" >> /output/metadata.txt

# List output for verification
RUN ls -laR /output/
